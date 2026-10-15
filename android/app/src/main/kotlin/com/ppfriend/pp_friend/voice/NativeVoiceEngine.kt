package com.ppfriend.pp_friend.voice

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sqrt

/**
 * 进程内单例语音引擎。Service 不拥有它 —— Service 只负责让系统不杀进程。
 *
 * 采集和播放各跑一条独立的原生阻塞线程，优先级 URGENT_AUDIO，
 * 完全不依赖 Flutter main isolate 的调度。
 *
 * 所有回调（onMicFrame / onLevels / onEvent）都保证在主线程被调用，
 * 因为 EventChannel 的 sink 只能在主线程用。
 */
@SuppressLint("MissingPermission")
class NativeVoiceEngine private constructor(private val appContext: Context) {

    companion object {
        private const val TAG = "NativeVoiceEngine"

        @Volatile
        private var sInstance: NativeVoiceEngine? = null

        fun get(context: Context): NativeVoiceEngine =
            sInstance ?: synchronized(this) {
                sInstance ?: NativeVoiceEngine(context.applicationContext).also { sInstance = it }
            }

        /** 每个 mic 帧的时长。20ms 是延迟与 EventChannel 开销的折中。 */
        private const val FRAME_MS = 20

        /** main 线程上最多堆积多少个待投递的 mic 帧，超了就丢，避免延迟无限累积。 */
        private const val MAX_PENDING_MIC_POSTS = 24

        private const val TELEMETRY_INTERVAL_MS = 33L

        private const val SILENCE_DB = -120.0

        /**
         * 算作"耳机"的输出设备。蓝牙只收 SCO / BLE —— A2DP 是音乐通道，
         * 通话类音频不会走它，把它当耳机反而会让选路落空。
         *
         * 这些都是编译期常量，所以在 API 29 上引用 TYPE_BLE_HEADSET 也不会炸。
         */
        private val HEADSET_OUTPUT_TYPES = intArrayOf(
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
        )
    }

    // ---------------------------------------------------------------- 对外回调

    /** 由 plugin 注入。引擎负责在主线程上调用。 */
    @Volatile
    var onMicFrame: ((ByteArray) -> Unit)? = null

    @Volatile
    var onLevels: ((Double, Double) -> Unit)? = null

    @Volatile
    var onEvent: ((Map<String, Any>) -> Unit)? = null

    // ---------------------------------------------------------------- 内部状态

    private val mainHandler = Handler(Looper.getMainLooper())
    private val audioManager = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    @Volatile
    var profile: VoiceAudioProfile = VoiceAudioProfile()
        private set

    @Volatile
    private var audioRunning = false

    @Volatile
    private var sampleRate = 16000
    private var framesPerChunk = 320

    private var captureThread: Thread? = null
    private var playbackThread: Thread? = null

    @Volatile
    private var micLevelDb = SILENCE_DB

    @Volatile
    private var playbackLevelDb = SILENCE_DB

    private val pendingMicPosts = AtomicInteger(0)

    @Volatile
    var droppedMicFrames: Long = 0
        private set

    /** 播放队列。全部在 queueLock 上同步。 */
    private val queueLock = Object()
    private val queue = ArrayDeque<PlaybackChunk>()
    private var playbackEpoch = 0L
    private var flushRequested = false
    private var queuedFrames = 0

    /**
     * 已经交给 AudioTrack 的总帧数（上次 flush 之后）。
     *
     * 和播放头相减就是"写进去了但还没响出来"的那一截。少了它，
     * 队列一空就会报告"没在播放"，而最后那一整块其实还在缓冲里响着 ——
     * 打断恰好就会漏在这一段。
     */
    @Volatile
    private var trackFramesWritten = 0L

    /**
     * 正在跑的那条 AudioTrack。
     *
     * 播放头（[playbackHeadMs]）只能从它身上读，所以不能只当局部变量 ——
     * 被打断时 Dart 要问"这条回复到底播到第几毫秒了"。
     */
    @Volatile
    private var playbackTrack: AudioTrack? = null

    private var manualAec: AcousticEchoCanceler? = null
    private var focusHeld = false
    private var savedAudioMode = AudioManager.MODE_NORMAL
    private var savedSpeakerphone = false

    private class PlaybackChunk(val epoch: Long, val data: ShortArray)

    // ---------------------------------------------------------------- 调试配置

    fun applyProfile(newProfile: VoiceAudioProfile) {
        // 采集源/播放属性这类参数改不了正在跑的会话，只影响下一次 startAudio。
        profile = newProfile
        // 这两个可以热切，方便边跑边对比。
        if (audioRunning) {
            runCatching { audioManager.mode = profile.audioManagerModeValue }
            applyRouting()
        }
    }

    /**
     * 音量减键要不要当作"让它闭嘴"。
     *
     * 默认 true —— 跟这个开关出现之前的行为一致。开关活在 Dart 侧的配置里，
     * 由那边推下来；原生侧拿不到配置，所以这里存一份。
     */
    @Volatile
    var volumeKeyClearsQueue: Boolean = true

    // ---------------------------------------------------------------- Service 联动

    var serviceRunning: Boolean = false
        private set

    fun markServiceRunning(running: Boolean) {
        serviceRunning = running
    }

    /** 通知栏「结束」按钮走到这里，转成 Dart 侧事件，由 Dart 决定怎么收尾。 */
    fun onEndRequestedFromNotification() {
        emitEvent(mapOf("type" to "endRequested"))
    }

    /**
     * 手动清空 AI 语音。来源有两处：通知栏的「停止说话」按钮，
     * 以及前台的音量减键。两者都只发事件，真正的清空由 Dart 决定 ——
     * 保持"引擎不持有业务状态"这条线。
     */
    fun onClearPlaybackRequested() {
        emitEvent(mapOf("type" to "clearPlaybackRequested"))
    }

    /**
     * 当前是否正在出声。音量键要不要拦截由它决定 ——
     * 只在播放 AI 语音时吞掉音量键，其余时候放行，不能影响正常调音量。
     */
    fun isPlaying(): Boolean {
        if (!audioRunning) return false
        if (playbackBacklogFrames() > 0) return true
        return System.currentTimeMillis() - lastPlaybackWriteMs < 200
    }

    // ---------------------------------------------------------------- 音频路由

    /**
     * 耳机插拔时重新选路。
     *
     * 用户会在对话中途插上耳机（或蓝牙耳机刚连上）—— 不重选的话，声音还留在
     * 上一次选的那条路上，得结束对话再开一次才能换过来。
     */
    private val audioDeviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
            if (audioRunning) applyRouting()
        }

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
            if (audioRunning) applyRouting()
        }
    }

    /**
     * 决定声音往哪儿走。**有耳机就走耳机，没耳机才轮到外放。**
     *
     * 以前这里是无条件 `isSpeakerphoneOn = profile.speakerphone`（默认 true），
     * 那是给 AEC 实测基线把外放钉死用的 —— 后果是不管插不插耳机，声音一律从
     * 扬声器出来，耳机白插。
     *
     * `profile.speakerphone` 的语义因此收窄成"**没有耳机时**要不要外放"：
     * 开着 = 扬声器，关掉 = 听筒。
     *
     * Android 12(31) 起用 `setCommunicationDevice` 显式挑设备，比
     * `isSpeakerphoneOn` 这种开关式 API 准 —— 后者在蓝牙上要配合 startBluetoothSco
     * 才肯走，而前者由系统负责把 SCO 拉起来。29/30 没有这个 API，退回旧开关，
     * 但同样只在没有耳机时才打开外放。
     */
    private fun applyRouting() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            applyRoutingModern()
        } else {
            @Suppress("DEPRECATION")
            runCatching {
                audioManager.isSpeakerphoneOn = profile.speakerphone && !hasOutputHeadset()
            }
        }
    }

    private fun applyRoutingModern() {
        val available = runCatching { audioManager.availableCommunicationDevices }
            .getOrDefault(emptyList())
        if (available.isEmpty()) return
        fun firstOf(vararg types: Int) = available.firstOrNull { it.type in types }

        // 耳机优先，顺序 = 插线的比无线的优先（同时接着时，用户手上那根更明确）
        val target = firstOf(*HEADSET_OUTPUT_TYPES)
            ?: firstOf(
                if (profile.speakerphone) {
                    AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                } else {
                    AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
                },
            )
            ?: return
        runCatching { audioManager.setCommunicationDevice(target) }
    }

    /** 当前有没有插着"出声的耳机"。外放和听筒本身不算。 */
    private fun hasOutputHeadset(): Boolean {
        val outputs = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        return outputs.any { it.type in HEADSET_OUTPUT_TYPES }
    }

    // ---------------------------------------------------------------- 音频会话

    /**
     * 打开音频链路。幂等：已经在跑就直接返回当前格式。
     *
     * 顺序很关键：先 setMode 并选好输出设备，再建 AudioRecord，
     * 否则音频路由与 AEC 滤波器会建立在错误的路径上。
     */
    fun startAudio(preferredSampleRate: Int): Result<Map<String, Any>> = runCatching {
        if (audioRunning) return@runCatching currentFormatMap()

        val rate = pickSampleRate(preferredSampleRate)
        sampleRate = rate
        framesPerChunk = rate * FRAME_MS / 1000

        savedAudioMode = audioManager.mode
        @Suppress("DEPRECATION")
        savedSpeakerphone = audioManager.isSpeakerphoneOn

        audioManager.mode = profile.audioManagerModeValue
        audioManager.registerAudioDeviceCallback(audioDeviceCallback, mainHandler)
        applyRouting()

        requestAudioFocus()

        synchronized(queueLock) {
            queue.clear()
            queuedFrames = 0
            playbackEpoch = 0
            flushRequested = false
        }

        audioRunning = true
        startCaptureThread()
        startPlaybackThread()
        startTelemetry()

        currentFormatMap()
    }

    /** 关闭音频链路，保留前台服务。幂等。 */
    fun stopAudio() {
        if (!audioRunning) return
        audioRunning = false

        stopTelemetry()
        captureThread?.join(1500)
        playbackThread?.join(1500)
        captureThread = null
        playbackThread = null

        manualAec?.let { runCatching { it.enabled = false }; it.release() }
        manualAec = null

        abandonAudioFocus()

        runCatching { audioManager.unregisterAudioDeviceCallback(audioDeviceCallback) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // 不清掉的话，选中的设备会一直粘着这个 App，别的应用跟着一起改道。
            runCatching { audioManager.clearCommunicationDevice() }
        }

        runCatching { audioManager.mode = savedAudioMode }
        runCatching {
            @Suppress("DEPRECATION")
            audioManager.isSpeakerphoneOn = savedSpeakerphone
        }

        synchronized(queueLock) {
            queue.clear()
            queuedFrames = 0
            queueLock.notifyAll()
        }

        micLevelDb = SILENCE_DB
        playbackLevelDb = SILENCE_DB
        emitLevels()
    }

    val isAudioRunning: Boolean get() = audioRunning

    private fun currentFormatMap(): Map<String, Any> = mapOf(
        "sampleRate" to sampleRate,
        "channels" to 1,
        "framesPerChunk" to framesPerChunk,
    )

    /**
     * 选一个 AudioRecord 和 AudioTrack 都支持的速率。
     *
     * 注意：本期不做重采样 —— 选中的速率会回传给 Dart，Dart 侧必须按它来
     * 生成/理解 PCM。如果将来 STT/TTS 服务端把速率钉死在 16k，而设备只有
     * 48k，就必须在这里补重采样。
     */
    private fun pickSampleRate(preferred: Int): Int {
        val candidates = listOf(preferred, 16000, 48000, 44100, 8000).distinct()
        for (rate in candidates) {
            val rec = AudioRecord.getMinBufferSize(
                rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
            )
            val trk = AudioTrack.getMinBufferSize(
                rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT
            )
            if (rec > 0 && trk > 0) return rate
        }
        return 16000
    }

    // ---------------------------------------------------------------- 采集

    private fun startCaptureThread() {
        val thread = Thread({ captureLoop() }, "voice-capture")
        captureThread = thread
        thread.start()
    }

    private fun captureLoop() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)

        val minBuf = AudioRecord.getMinBufferSize(
            sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        val bufferBytes = max(minBuf, framesPerChunk * 2 * 8)

        val record = try {
            AudioRecord(
                profile.captureSourceValue,
                sampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferBytes,
            )
        } catch (t: Throwable) {
            emitEvent(mapOf("type" to "micSilentlyDead", "reason" to (t.message ?: "AudioRecord 构造失败")))
            return
        }

        if (record.state != AudioRecord.STATE_INITIALIZED) {
            emitEvent(mapOf("type" to "micSilentlyDead", "reason" to "AudioRecord 未初始化"))
            record.release()
            return
        }

        // 手动 AEC。与 VOICE_COMMUNICATION 是两条不同的路径，
        // 能否叠加因机型而异，所以做成开关供实测对比。
        if (profile.manualAec) {
            if (AcousticEchoCanceler.isAvailable()) {
                manualAec = runCatching {
                    AcousticEchoCanceler.create(record.audioSessionId)?.apply { enabled = true }
                }.getOrNull()
                if (manualAec?.enabled != true) {
                    emitEvent(mapOf("type" to "manualAecUnavailable"))
                }
            } else {
                emitEvent(mapOf("type" to "manualAecUnavailable"))
            }
        }

        try {
            record.startRecording()
        } catch (t: Throwable) {
            emitEvent(mapOf("type" to "micSilentlyDead", "reason" to (t.message ?: "startRecording 抛异常")))
            record.release()
            return
        }

        if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            // 这条正是「不报错，只是没声音」的情形，必须显式上报。
            emitEvent(mapOf("type" to "micSilentlyDead", "reason" to "recordingState 非 RECORDING"))
            record.release()
            return
        }

        val shorts = ShortArray(framesPerChunk)
        val bytes = ByteArray(framesPerChunk * 2)
        var healthTicks = 0

        while (audioRunning) {
            val n = try {
                record.read(shorts, 0, shorts.size)
            } catch (t: Throwable) {
                emitEvent(mapOf("type" to "micSilentlyDead", "reason" to (t.message ?: "read 抛异常")))
                break
            }

            if (n < 0) {
                emitEvent(mapOf("type" to "micSilentlyDead", "reason" to "read 返回 $n"))
                break
            }
            if (n == 0) continue

            micLevelDb = rmsToDb(shorts, n)

            // 小端序打包成 PCM16 字节流
            for (i in 0 until n) {
                val s = shorts[i].toInt()
                bytes[i * 2] = (s and 0xFF).toByte()
                bytes[i * 2 + 1] = ((s shr 8) and 0xFF).toByte()
            }
            emitMicFrame(bytes.copyOf(n * 2))

            // 每约 2 秒确认一次麦克风还活着
            if (++healthTicks >= 100) {
                healthTicks = 0
                if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                    emitEvent(mapOf("type" to "micSilentlyDead", "reason" to "运行中 recordingState 变了"))
                    break
                }
            }
        }

        runCatching { record.stop() }
        record.release()
    }

    /**
     * 无订阅 / 主线程积压时直接丢帧。
     *
     * 这是**有意为之**：宁可丢帧也不能让延迟无限累积 —— 语音助手一旦延迟
     * 爬上去就再也降不回来，比丢几帧难受得多。丢弃量通过 droppedMicFrames
     * 暴露给 Dart，便于观测。
     */
    private fun emitMicFrame(frame: ByteArray) {
        if (onMicFrame == null) {
            droppedMicFrames += framesPerChunk
            return
        }
        if (pendingMicPosts.get() >= MAX_PENDING_MIC_POSTS) {
            droppedMicFrames += framesPerChunk
            return
        }
        pendingMicPosts.incrementAndGet()
        mainHandler.post {
            pendingMicPosts.decrementAndGet()
            onMicFrame?.invoke(frame)
        }
    }

    // ---------------------------------------------------------------- 播放

    private fun startPlaybackThread() {
        val thread = Thread({ playbackLoop() }, "voice-playback")
        playbackThread = thread
        thread.start()
    }

    private fun playbackLoop() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)

        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        val bufferBytes = max(minBuf, framesPerChunk * 2 * 8)

        val track = try {
            val builder = AudioTrack.Builder()
                .setAudioAttributes(profile.audioAttributes())
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                .setBufferSizeInBytes(bufferBytes)
                .setTransferMode(AudioTrack.MODE_STREAM)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                builder.setPerformanceMode(profile.performanceModeValue)
            }
            builder.build()
        } catch (t: Throwable) {
            emitEvent(mapOf("type" to "engineFailure", "reason" to (t.message ?: "AudioTrack 构造失败")))
            return
        }

        if (track.state != AudioTrack.STATE_INITIALIZED) {
            emitEvent(mapOf("type" to "engineFailure", "reason" to "AudioTrack 未初始化"))
            track.release()
            return
        }

        try {
            track.play()
        } catch (t: Throwable) {
            emitEvent(mapOf("type" to "engineFailure", "reason" to (t.message ?: "AudioTrack.play 失败")))
            track.release()
            return
        }

        playbackTrack = track

        while (audioRunning) {
            val chunk: PlaybackChunk?
            synchronized(queueLock) {
                while (audioRunning && queue.isEmpty() && !flushRequested) {
                    queueLock.wait(200)
                }
                if (!audioRunning) return
                if (flushRequested) {
                    flushRequested = false
                    // 下面的 track.flush() 会把播放头归零，计数跟着一起归零，
                    // 否则"已写入 - 播放头"会算出一个虚高的待播量。
                    trackFramesWritten = 0
                    chunk = null
                } else {
                    val c = queue.removeFirst()
                    queuedFrames -= c.data.size
                    chunk = c
                }
            }

            if (chunk == null) {
                // 立刻静音：pause + flush + play 才能真正丢掉 AudioTrack
                // 内部已缓冲但还没送出去的样本，光清我们自己的队列不够。
                runCatching { track.pause() }
                runCatching { track.flush() }
                runCatching { track.play() }
                playbackLevelDb = SILENCE_DB
                continue
            }

            if (chunk.epoch < playbackEpoch) continue

            try {
                track.write(chunk.data, 0, chunk.data.size)
            } catch (t: Throwable) {
                emitEvent(mapOf("type" to "engineFailure", "reason" to (t.message ?: "AudioTrack.write 失败")))
                break
            }

            trackFramesWritten += chunk.data.size

            playbackLevelDb = rmsToDb(chunk.data, chunk.data.size)
            lastPlaybackWriteMs = System.currentTimeMillis()
        }

        playbackTrack = null
        runCatching { track.stop() }
        track.release()
    }

    @Volatile
    private var lastPlaybackWriteMs = 0L

    /**
     * 推入一段播放数据。[epoch] 用于让打断在并发下保持确定性：
     * 原生会丢弃所有 epoch 小于当前值的缓冲，所以即便 TTS 流的下一块
     * 迟到了，也不会在被打断之后再冒出来。
     */
    fun pushPlayback(samples: ShortArray, epoch: Long) {
        if (!audioRunning) return
        synchronized(queueLock) {
            if (epoch < playbackEpoch) return
            queue.addLast(PlaybackChunk(epoch, samples))
            queuedFrames += samples.size
            queueLock.notifyAll()
        }
    }

    /**
     * 打断：抬 epoch + 清空队列 + 让播放线程 flush 掉 AudioTrack 内部缓冲。
     * 返回被丢弃的帧数 —— 已经播出去的不算，Dart 可以据此截断对话上下文。
     */
    fun flushPlayback(newEpoch: Long): Long {
        synchronized(queueLock) {
            if (newEpoch > playbackEpoch) playbackEpoch = newEpoch
            val discarded = queuedFrames.toLong()
            queue.clear()
            queuedFrames = 0
            flushRequested = true
            queueLock.notifyAll()
            playbackLevelDb = SILENCE_DB
            return discarded
        }
    }

    /**
     * 还有多少帧没响出来。
     *
     * = 我们队列里的 + AudioTrack 内部缓冲里的。只算前者会在**最后一块**
     * 上失真：队列已经空了，可那 1 秒还在缓冲里响着，报告"没在播放"
     * 会让打断刚好漏掉那一段。
     */
    fun playbackBacklogFrames(): Int =
        synchronized(queueLock) { queuedFrames } + framesInTrackBuffer()

    /** 写进去了但还没响出来的帧数（已写入 − 播放头）。 */
    private fun framesInTrackBuffer(): Int {
        if (playbackTrack == null) return 0
        val pending = trackFramesWritten - playbackHeadFrames()
        return if (pending > 0) pending.toInt() else 0
    }

    private fun playbackHeadFrames(): Long {
        val track = playbackTrack ?: return 0
        return try {
            track.playbackHeadPosition.toLong()
        } catch (_: Throwable) {
            0
        }
    }

    /**
     * 已经播出去的毫秒数。
     *
     * 读的是播放头 —— 它计的是**真正送出去的帧**，不是我们推下去了多少；
     * 两者中间隔着 AudioTrack 的内部缓冲，那个差值就是用户还没听到的部分。
     *
     * flush() 会把播放头归零（STREAM 模式），所以它天然是"从上次清空算起"
     * 的位置；"这条回复里听到了多少"由 Dart 侧减掉开播时的基线得到。
     */
    fun playbackHeadMs(): Long {
        val track = playbackTrack ?: return 0
        val rate = sampleRate
        if (rate <= 0) return 0
        return try {
            track.playbackHeadPosition.toLong() * 1000L / rate
        } catch (_: Throwable) {
            0
        }
    }

    // ---------------------------------------------------------------- 遥测

    private var telemetryStarted = false

    private val telemetryRunnable = object : Runnable {
        override fun run() {
            if (!audioRunning) return
            // 超过 100ms 没写过新数据就认为播放静默，否则电平会僵在最后一个值上
            if (System.currentTimeMillis() - lastPlaybackWriteMs > 100) {
                playbackLevelDb = SILENCE_DB
            }
            emitLevels()
            mainHandler.postDelayed(this, TELEMETRY_INTERVAL_MS)
        }
    }

    private fun startTelemetry() {
        if (telemetryStarted) return
        telemetryStarted = true
        mainHandler.postDelayed(telemetryRunnable, TELEMETRY_INTERVAL_MS)
    }

    private fun stopTelemetry() {
        if (!telemetryStarted) return
        telemetryStarted = false
        mainHandler.removeCallbacks(telemetryRunnable)
    }

    private fun emitLevels() {
        val mic = micLevelDb
        val playback = playbackLevelDb
        postMain { onLevels?.invoke(mic, playback) }
    }

    // ---------------------------------------------------------------- 音频焦点

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        val event: Map<String, Any>? = when (change) {
            AudioManager.AUDIOFOCUS_LOSS ->
                mapOf("type" to "interruptionBegan", "transient" to false, "canDuck" to false)

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT ->
                mapOf("type" to "interruptionBegan", "transient" to true, "canDuck" to false)

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK ->
                mapOf("type" to "interruptionBegan", "transient" to true, "canDuck" to true)

            AudioManager.AUDIOFOCUS_GAIN ->
                mapOf("type" to "interruptionEnded", "shouldResume" to true)

            else -> null
        }
        event?.let { emitEvent(it) }
    }

    @Suppress("DEPRECATION")
    private fun requestAudioFocus() {
        if (focusHeld) return
        val result = audioManager.requestAudioFocus(
            focusListener,
            AudioManager.STREAM_VOICE_CALL,
            AudioManager.AUDIOFOCUS_GAIN,
        )
        focusHeld = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        if (!focusHeld) {
            emitEvent(mapOf("type" to "engineFailure", "reason" to "音频焦点被拒绝"))
        }
    }

    @Suppress("DEPRECATION")
    private fun abandonAudioFocus() {
        if (!focusHeld) return
        audioManager.abandonAudioFocus(focusListener)
        focusHeld = false
    }

    // ---------------------------------------------------------------- 工具

    private fun rmsToDb(samples: ShortArray, n: Int): Double {
        if (n <= 0) return SILENCE_DB
        var sum = 0.0
        for (i in 0 until n) {
            val v = samples[i] / 32768.0
            sum += v * v
        }
        val rms = sqrt(sum / n)
        return if (rms <= 1e-7) SILENCE_DB else 20.0 * log10(rms)
    }

    private fun postMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else mainHandler.post(block)
    }

    private fun emitEvent(event: Map<String, Any>) {
        Log.d(TAG, "event $event")
        postMain { onEvent?.invoke(event) }
    }
}

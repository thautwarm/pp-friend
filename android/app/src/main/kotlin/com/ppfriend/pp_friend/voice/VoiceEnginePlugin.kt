package com.ppfriend.pp_friend.voice

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * 把原生引擎接到 Flutter 上。
 *
 * 通道划分：
 *  - MethodChannel  —— 命令与查询
 *  - mic EventChannel    —— 采集 PCM（二进制，高频）
 *  - levels EventChannel —— 电平遥测（~30Hz，含双讲检测所需的播放参考电平）
 *  - events EventChannel —— 离散事件（打断、麦克风静默失效、通知栏结束）
 *
 * 分成四条而不是一条，是因为它们的频率、载荷类型和背压策略都不一样。
 */
class VoiceEnginePlugin(private val context: Context, messenger: BinaryMessenger) {

    companion object {
        const val METHOD_CHANNEL = "pp_friend/voice_engine"
        const val MIC_CHANNEL = "pp_friend/voice_engine/mic"
        const val LEVELS_CHANNEL = "pp_friend/voice_engine/levels"
        const val EVENTS_CHANNEL = "pp_friend/voice_engine/events"

        fun registerWith(messenger: BinaryMessenger, context: Context) {
            VoiceEnginePlugin(context, messenger)
        }
    }

    private val engine = NativeVoiceEngine.get(context)
    private val mainHandler = Handler(Looper.getMainLooper())

    init {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "applyDebugProfile" -> {
                        @Suppress("UNCHECKED_CAST")
                        val map = call.arguments as? Map<String, Any?>
                        engine.applyProfile(VoiceAudioProfile.fromMap(map))
                        result.success(engine.profile.toMap())
                    }

                    "setVolumeKeyClearsQueue" -> {
                        engine.volumeKeyClearsQueue = call.argument<Boolean>("enabled") ?: true
                        result.success(true)
                    }

                    "startService" -> {
                        VoiceAssistantService.start(context)
                        result.success(true)
                    }

                    "stopService" -> {
                        VoiceAssistantService.stop(context)
                        result.success(true)
                    }

                    "serviceRunning" -> result.success(engine.serviceRunning)

                    "startAudio" -> {
                        val preferred = call.argument<Number>("preferredSampleRate")?.toInt() ?: 16000
                        engine.startAudio(preferred).fold(
                            onSuccess = { result.success(it) },
                            onFailure = { e ->
                                result.error("startAudioFailed", e.message ?: "startAudio 失败", null)
                            },
                        )
                    }

                    "stopAudio" -> {
                        engine.stopAudio()
                        result.success(true)
                    }

                    "pushPlayback" -> {
                        val pcm = call.argument<ByteArray>("pcm")
                        val epoch = call.argument<Number>("epoch")?.toLong()
                        if (pcm == null || epoch == null) {
                            result.error("badArgs", "pushPlayback 需要 pcm 与 epoch", null)
                        } else {
                            engine.pushPlayback(bytesToShorts(pcm), epoch)
                            result.success(true)
                        }
                    }

                    "flushPlayback" -> {
                        val epoch = call.argument<Number>("newEpoch")?.toLong()
                        if (epoch == null) {
                            result.error("badArgs", "flushPlayback 需要 newEpoch", null)
                        } else {
                            result.success(engine.flushPlayback(epoch))
                        }
                    }

                    "decodeAudio" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        if (bytes == null) {
                            result.error("badArgs", "decodeAudio 需要 bytes", null)
                        } else {
                            // 解码是 CPU 密集的，扔到后台线程；MethodChannel 的
                            // result 必须回主线程调，所以解完再 post 回去。
                            Thread({
                                try {
                                    val decoded = AudioDecoder.decode(context, bytes)
                                    mainHandler.post {
                                        result.success(
                                            mapOf(
                                                "pcm" to decoded.pcm16le,
                                                "sampleRate" to decoded.sampleRate,
                                                "channels" to decoded.channels,
                                            )
                                        )
                                    }
                                } catch (t: Throwable) {
                                    mainHandler.post {
                                        result.error("decodeFailed", t.message ?: t.toString(), null)
                                    }
                                }
                            }, "voice-decode").start()
                        }
                    }

                    "opusEncoderAvailable" -> result.success(OpusEncoder.isAvailable())

                    "encodeOpus" -> {
                        val pcm = call.argument<ByteArray>("pcm")
                        val rate = call.argument<Number>("sampleRate")?.toInt()
                        val channels = call.argument<Number>("channels")?.toInt() ?: 1
                        if (pcm == null || rate == null) {
                            result.error("badArgs", "encodeOpus 需要 pcm 与 sampleRate", null)
                        } else {
                            Thread({
                                // 失败返回 null，Dart 侧据此回落发 WAV
                                val encoded = OpusEncoder.encodeToOgg(context, pcm, rate, channels)
                                // 直接回字节。协议只收 Ogg Opus，没有别的格式要区分。
                                mainHandler.post { result.success(encoded) }
                            }, "voice-encode").start()
                        }
                    }

                    "playbackBacklogFrames" -> result.success(engine.playbackBacklogFrames())
                    "playbackHeadMs" -> result.success(engine.playbackHeadMs())
                    "droppedMicFrames" -> result.success(engine.droppedMicFrames)
                    "isAudioRunning" -> result.success(engine.isAudioRunning)

                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                result.error("voiceEngine", t.message ?: t.toString(), null)
            }
        }

        EventChannel(messenger, MIC_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    engine.onMicFrame = { bytes -> sink?.success(bytes) }
                }

                override fun onCancel(args: Any?) {
                    engine.onMicFrame = null
                }
            }
        )

        EventChannel(messenger, LEVELS_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    // [micLevelDb, playbackLevelDb]
                    engine.onLevels = { mic, playback -> sink?.success(listOf(mic, playback)) }
                }

                override fun onCancel(args: Any?) {
                    engine.onLevels = null
                }
            }
        )

        EventChannel(messenger, EVENTS_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    engine.onEvent = { event -> sink?.success(event) }
                }

                override fun onCancel(args: Any?) {
                    engine.onEvent = null
                }
            }
        )
    }

    /** 小端序 PCM16 字节流 → ShortArray */
    private fun bytesToShorts(bytes: ByteArray): ShortArray {
        val count = bytes.size / 2
        val out = ShortArray(count)
        for (i in 0 until count) {
            val lo = bytes[i * 2].toInt() and 0xFF
            val hi = bytes[i * 2 + 1].toInt()
            out[i] = ((hi shl 8) or lo).toShort()
        }
        return out
    }
}

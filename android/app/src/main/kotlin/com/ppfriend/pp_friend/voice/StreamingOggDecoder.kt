package com.ppfriend.pp_friend.voice

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * 流式 Ogg Opus 解码。
 *
 * `/brain-to-human` 现在返回的是**一条连续的 Ogg Opus 流**，不再是一句
 * 一个独立文件。MediaExtractor 只能吃完整文件，所以这里自己做增量解析：
 *
 *  网络字节 → 攒完整 Ogg page → 从 segment table 重组 Opus packet
 *           → 喂 MediaCodec → 有多少 PCM 吐多少
 *
 * 一个 page 里可以有多条 packet（lacing 255 表示续到下一段），
 * 一条 packet 也可以跨 page —— 所以 [partial] 要一直留着，直到某一段的
 * 长度小于 255。
 *
 * 所有方法都必须在同一个线程上调用（插件侧用单线程 executor 串起来）。
 */
class StreamingOggDecoder {
    companion object {
        private const val TAG = "OggStream"
        private const val DEQUEUE_TIMEOUT_US = 10_000L
    }

    private val input = ByteArrayOutputStream()
    private val partial = ByteArrayOutputStream()
    private val pending = ArrayDeque<ByteArray>()

    private var codec: MediaCodec? = null
    private var headerSeen = false
    private var ptsUs = 0L
    private var openError: Throwable? = null

    private var outputSampleRate = 48000
    private var outputChannels = 1
    private var dequeueFails = 0

    private val info = MediaCodec.BufferInfo()

    val isOpen: Boolean get() = codec != null

    /**
     * 喂一块网络字节，返回这次解出来的 PCM16 小端。
     *
     * 可能返回 null（还没攒够一个 page，或者解码器暂时没有输出）。
     * 返回的采样率/声道是**解码器实际输出**的，不是 Ogg 头里声明的。
     */
    fun feed(bytes: ByteArray): DecodedAudio? {
        if (bytes.isNotEmpty()) input.write(bytes)
        parsePages()
        // 解码器没开起来就不要假装在解：把错误抛给 Dart，让它把这条算失败，
        // 而不是让 pending 无限长、用户只看到文字没有声音。
        openError?.let { throw IllegalStateException("Opus 解码器不可用：$it", it) }
        pumpInput()
        return drain(DEQUEUE_TIMEOUT_US)
    }

    /** body 结束：把剩下的数据、输入队列和 EOS 都收干净。 */
    fun finish(): DecodedAudio? {
        val pcm = ByteArrayOutputStream()
        try {
            parsePages()
            openError?.let {
                throw IllegalStateException("Opus 解码器不可用：$it", it)
            }

            // 网络一次可能给一整块（几十上百个包），而解码器的输入槽只有
            // 几个。必须边喂边收，直到 pending 真的空了 —— 否则 EOS 会插到
            // 它们前面，剩下的音频全被丢掉。
            val flushDeadline = System.currentTimeMillis() + 3_000
            var idle = 0
            while (pending.isNotEmpty()) {
                val before = pcm.size()
                pumpInput()
                drainInto(pcm, 0)
                if (pcm.size() == before) {
                    if (++idle >= 100) break
                    Thread.sleep(2)
                } else {
                    idle = 0
                }
                if (System.currentTimeMillis() > flushDeadline) break
            }

            val c = codec
            if (c != null) {
                // 等一个输入槽放 EOS；等不到就只把已有的 PCM 收掉，
                // 不要在 drainUntilEos 里空转。
                var index = -1
                val eosDeadline = System.currentTimeMillis() + 500
                while (System.currentTimeMillis() < eosDeadline) {
                    index = c.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                    if (index >= 0) break
                    drainInto(pcm, 0)
                }
                if (index >= 0) {
                    c.queueInputBuffer(
                        index, 0, 0, ptsUs,
                        MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                    )
                    drainUntilEosInto(pcm)
                }
            }

            if (pcm.size() == 0) return null
            return DecodedAudio(
                pcm.toByteArray(),
                outputSampleRate,
                outputChannels,
            )
        } finally {
            release()
            // 一条流结束，下一条回复要重新从 OpusHead 开始。
            // 不清的话 headerSeen 还挂着，下一条流的 OpusHead 会被当成普通
            // 音频包塞进 pending，解码器永远开不起来。失败路径也必须清。
            clearStreamState()
        }
    }

    /** 打断 / 切换回复：丢掉当前解码状态。 */
    fun reset() {
        release()
        clearStreamState()
    }

    private fun clearStreamState() {
        input.reset()
        partial.reset()
        pending.clear()
        headerSeen = false
        ptsUs = 0
        openError = null
        outputSampleRate = 48000
        outputChannels = 1
        dequeueFails = 0
    }

    // ------------------------------------------------------------ Ogg 解析

    private fun parsePages() {
        var buf = input.toByteArray()
        var pos = 0

        while (true) {
            if (buf.size - pos < 4) break

            if (!isCapture(buf, pos)) {
                val next = findCapture(buf, pos + 1)
                if (next < 0) {
                    // 把可能被网络切断的 "Ogg" 三个字节留着。
                    pos = maxOf(pos, buf.size - 3)
                    break
                }
                pos = next
            }

            if (buf.size - pos < 27) break

            val segments = buf[pos + 26].toInt() and 0xff
            if (buf.size - pos < 27 + segments) break

            var payloadLength = 0
            for (i in 0 until segments) {
                payloadLength += buf[pos + 27 + i].toInt() and 0xff
            }
            if (buf.size - pos < 27 + segments + payloadLength) break

            val payloadOffset = pos + 27 + segments
            var offset = payloadOffset
            for (i in 0 until segments) {
                val length = buf[pos + 27 + i].toInt() and 0xff
                partial.write(buf, offset, length)
                offset += length
                if (length < 255) {
                    onPacket(partial.toByteArray())
                    partial.reset()
                }
            }

            pos += 27 + segments + payloadLength
        }

        if (pos > 0) {
            val rest = buf.copyOfRange(pos, buf.size)
            input.reset()
            input.write(rest)
            buf = rest
        }
    }

    private fun isCapture(buf: ByteArray, at: Int): Boolean =
        buf[at] == 'O'.code.toByte() &&
            buf[at + 1] == 'g'.code.toByte() &&
            buf[at + 2] == 'g'.code.toByte() &&
            buf[at + 3] == 'S'.code.toByte()

    private fun findCapture(buf: ByteArray, from: Int): Int {
        var i = from
        while (i + 3 < buf.size) {
            if (isCapture(buf, i)) return i
            i++
        }
        return -1
    }

    private fun onPacket(data: ByteArray) {
        if (data.isEmpty()) return

        if (!headerSeen) {
            if (startsWith(data, "OpusHead")) {
                headerSeen = true
                // OpusHead: magic(8) version(1) channels(1) pre-skip(2) ...
                val channels = if (data.size > 9) data[9].toInt() and 0xff else 1
                outputChannels = if (channels in 1..2) channels else 1
                openCodec(data)
            }
            // 不是 OpusHead 就丢掉（空评论、坏流都别让它把解码器带歪）。
            return
        }

        if (startsWith(data, "OpusTags")) return
        pending.addLast(data)
    }

    private fun startsWith(data: ByteArray, prefix: String): Boolean {
        if (data.size < prefix.length) return false
        for (i in prefix.indices) {
            if (data[i] != prefix[i].code.toByte()) return false
        }
        return true
    }

    // ------------------------------------------------------------ MediaCodec

    private fun openCodec(head: ByteArray) {
        try {
            val preSkip = if (head.size >= 12) {
                (head[10].toInt() and 0xff) or
                    ((head[11].toInt() and 0xff) shl 8)
            } else {
                312
            }
            // 平台 Opus 解码器（c2.android.opus.decoder）把 CSD 当成**三条
            // 输入**依次读：csd-0 = OpusHead，csd-1 = codec delay，
            // csd-2 = seek pre-roll，后两条是 8 字节、原生字节序的纳秒数。
            //
            // 只给 csd-0 的话，解码器会把前两个音频包当成 csd-1/2：
            // 包长不足 8 字节时直接报 "Input sample size is too small"
            // 并进入错误状态 —— 之后整条流一个 PCM 都不吐。
            val format = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_OPUS,
                48000,
                outputChannels,
            ).apply {
                setInteger(
                    MediaFormat.KEY_PCM_ENCODING,
                    AudioFormat.ENCODING_PCM_16BIT,
                )
                // 有的 OEM 解码器要 OpusHead 才能建立通道映射。
                setByteBuffer("csd-0", ByteBuffer.wrap(head))
                setByteBuffer("csd-1", u64(preSkip.toLong() * 1_000_000_000L / 48000L))
                // seek pre-roll 按 Ogg Opus 规范固定 80ms。
                setByteBuffer("csd-2", u64(80_000_000L))
            }

            codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_OPUS)
            codec!!.configure(format, null, null, 0)
            codec!!.start()
            Log.i(
                TAG,
                "Opus 解码器启动 channels=$outputChannels preSkip=$preSkip",
            )
        } catch (t: Throwable) {
            Log.e(TAG, "Opus 解码器启动失败", t)
            openError = t
            release()
        }
    }

    /** 解码器读 csd-1/2 时是直接 memcpy 成 int64，所以用原生字节序。 */
    private fun u64(value: Long): ByteBuffer =
        ByteBuffer.allocate(8)
            .order(ByteOrder.nativeOrder())
            .putLong(value)
            .apply { rewind() }

    private fun pumpInput() {
        val c = codec ?: return
        while (pending.isNotEmpty()) {
            val index = c.dequeueInputBuffer(0)
            if (index < 0) {
                dequeueFails++
                if (dequeueFails <= 3 || dequeueFails % 500 == 0) {
                    Log.w(
                        TAG,
                        "拿不到输入槽 #$dequeueFails，pending=${pending.size}",
                    )
                }
                return
            }

            val buffer = c.getInputBuffer(index)
            if (buffer == null) {
                // 极少见，但槽位不能泄漏：塞一个空包还回去。
                c.queueInputBuffer(index, 0, 0, ptsUs, 0)
                return
            }
            val packet = pending.removeFirst()
            buffer.clear()
            buffer.put(packet)
            c.queueInputBuffer(index, 0, packet.size, ptsUs, 0)
            // PTS 只需要单调；具体帧长由解码器从 Opus TOC 自己判断。
            ptsUs += 20_000
        }
    }

    private fun drain(timeoutUs: Long): DecodedAudio? {
        val pcm = ByteArrayOutputStream()
        drainInto(pcm, timeoutUs)
        if (pcm.size() == 0) return null
        return DecodedAudio(pcm.toByteArray(), outputSampleRate, outputChannels)
    }

    /** 把当前能拿到的 PCM 追加到 [pcm]；没有输出就立刻返回。 */
    private fun drainInto(pcm: ByteArrayOutputStream, timeoutUs: Long) {
        val c = codec ?: return
        var timeout = timeoutUs

        while (true) {
            val index = c.dequeueOutputBuffer(info, timeout)
            timeout = 0
            if (index == MediaCodec.INFO_TRY_AGAIN_LATER) return
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                val format = c.outputFormat
                outputSampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                outputChannels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                continue
            }
            if (index < 0) continue

            if (info.size > 0) {
                val buffer = c.getOutputBuffer(index)
                if (buffer != null) {
                    buffer.position(info.offset)
                    buffer.limit(info.offset + info.size)
                    val chunk = ByteArray(info.size)
                    buffer.get(chunk)
                    pcm.write(chunk)
                }
            }
            c.releaseOutputBuffer(index, false)
            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
        }
    }

    /**
     * EOS 之后把尾巴收掉。
     *
     * 有期限：EOS 没排进去、或者解码器卡住时不能无限等，
     * 否则 finishOggStream 会把整条轮询循环挂死。
     */
    private fun drainUntilEosInto(pcm: ByteArrayOutputStream) {
        val deadline = System.currentTimeMillis() + 2_000
        var quiet = 0
        while (System.currentTimeMillis() < deadline) {
            val before = pcm.size()
            drainInto(pcm, DEQUEUE_TIMEOUT_US)
            if (pcm.size() == before) {
                if (++quiet >= 20) return
            } else {
                quiet = 0
            }
        }
    }

    private fun release() {
        val c = codec ?: return
        codec = null
        runCatching { c.stop() }
        runCatching { c.release() }
    }
}

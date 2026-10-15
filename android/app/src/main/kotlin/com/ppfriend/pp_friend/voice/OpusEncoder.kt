package com.ppfriend.pp_friend.voice

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import android.util.Log
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * 上行音频编码：PCM16 → Ogg Opus。
 *
 * 为什么要编码：16k 单声道 PCM16 是 256 kbps，3 秒就是 96KB。
 * Opus 能压到 ~6KB（16x）。局域网上这点差别无所谓，但走移动数据时
 * 推裸 PCM 就很难看了，而且服务端反正要压缩，不如在源头压掉。
 *
 * 两个 API 门槛：
 *  - Opus **编码**要 API 29
 *  - `MUXER_OUTPUT_OGG` 也要 API 29
 *
 * 但**不因此升 minSdk** —— [isAvailable] 做运行时探测，不可用就让调用方
 * 回落发 WAV（协议两种都收）。按能力探测而不是按 API 级别判，
 * 因为 OEM 差异是真实存在的。
 */
object OpusEncoder {
    private const val TAG = "OpusEncoder"

    private const val BIT_RATE = 24000
    private const val TIMEOUT_US = 10_000L
    private const val MAX_ITERATIONS = 20_000

    /** 每帧 20ms —— Opus 的常用帧长。 */
    private const val FRAME_MS = 20

    /**
     * 本机有没有 Opus 编码器。
     *
     * 运行时查 MediaCodecList，不按 `Build.VERSION.SDK_INT` 判。
     */
    fun isAvailable(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        return try {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
                info.isEncoder &&
                    info.supportedTypes.any {
                        it.equals(MediaFormat.MIMETYPE_AUDIO_OPUS, ignoreCase = true)
                    }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "探测 Opus 编码器失败：$t")
            false
        }
    }

    /** 编码成功返回 Ogg 字节；任何失败都返回 null，由调用方回落 WAV。 */
    fun encodeToOgg(
        context: Context,
        pcm16le: ByteArray,
        sampleRate: Int,
        channels: Int,
    ): ByteArray? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        if (pcm16le.isEmpty()) return null

        val output = File.createTempFile("ppfriend-opus-", ".ogg", context.cacheDir)
        var codec: MediaCodec? = null
        var muxer: MediaMuxer? = null

        try {
            val format = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_OPUS,
                sampleRate,
                channels,
            ).apply {
                setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
            }

            codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_OPUS)
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()

            muxer = MediaMuxer(output.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_OGG)

            val info = MediaCodec.BufferInfo()
            val frameBytes = (sampleRate / (1000 / FRAME_MS)) * channels * 2
            var offset = 0
            var trackIndex = -1
            var muxerStarted = false
            var inputDone = false
            var outputDone = false
            var iterations = 0

            while (!outputDone) {
                if (++iterations > MAX_ITERATIONS) {
                    Log.w(TAG, "编码超过 $MAX_ITERATIONS 轮")
                    return null
                }

                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (inIndex >= 0) {
                        val buffer = codec.getInputBuffer(inIndex)!!
                        buffer.clear()

                        val remaining = pcm16le.size - offset
                        if (remaining <= 0) {
                            codec.queueInputBuffer(
                                inIndex, 0, 0,
                                offset.toLong() * 1_000_000L / (sampleRate * channels * 2),
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputDone = true
                        } else {
                            val count = minOf(remaining, frameBytes, buffer.capacity())
                            buffer.put(pcm16le, offset, count)
                            codec.queueInputBuffer(
                                inIndex, 0, count,
                                offset.toLong() * 1_000_000L / (sampleRate * channels * 2),
                                0,
                            )
                            offset += count
                        }
                    }
                }

                when (val outIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)) {
                    MediaCodec.INFO_TRY_AGAIN_LATER -> Unit

                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        if (!muxerStarted) {
                            trackIndex = muxer.addTrack(codec.outputFormat)
                            muxer.start()
                            muxerStarted = true
                        }
                    }

                    else -> {
                        if (outIndex >= 0) {
                            val buffer = codec.getOutputBuffer(outIndex)!!
                            val isConfig =
                                info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0

                            if (!isConfig && info.size > 0 && muxerStarted) {
                                buffer.position(info.offset)
                                buffer.limit(info.offset + info.size)
                                muxer.writeSampleData(trackIndex, buffer, info)
                            }
                            codec.releaseOutputBuffer(outIndex, false)

                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                                outputDone = true
                            }
                        }
                    }
                }
            }

            if (!muxerStarted) {
                Log.w(TAG, "编码器从未产出格式，放弃")
                return null
            }

            muxer.stop()
            muxer.release()
            muxer = null

            val bytes = output.readBytes()
            if (bytes.size < 100) {
                Log.w(TAG, "编码结果太小（${bytes.size}B），放弃")
                return null
            }
            Log.d(TAG, "Opus 编码 ${pcm16le.size}B → ${bytes.size}B " +
                    "(${sampleRate}Hz/${channels}ch)")
            return bytes
        } catch (t: Throwable) {
            Log.w(TAG, "Opus 编码失败，调用方应回落 WAV：$t")
            return null
        } finally {
            runCatching { muxer?.stop() }
            runCatching { muxer?.release() }
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
            output.delete()
        }
    }
}

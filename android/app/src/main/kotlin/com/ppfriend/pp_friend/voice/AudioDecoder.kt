package com.ppfriend.pp_friend.voice

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.File

/** 解码结果：原始 PCM16 小端，外加它自己的采样率和声道数。 */
class DecodedAudio(
    val pcm16le: ByteArray,
    val sampleRate: Int,
    val channels: Int,
)

/**
 * 把压缩音频解成 PCM16。
 *
 * brain 的 `/brain-to-human` 返回的是 OGG（Opus），而 Dart 侧没有可用的 Opus 解码器，
 * 所以这一步必须在原生做。
 *
 * 用 MediaExtractor + MediaCodec 而不是硬编码 Ogg/Opus 解析：这套能顺带
 * 吃下 WAV / MP3 / M4A。哪天 brain 换了输出格式，这里不用改。
 */
object AudioDecoder {
    private const val TAG = "AudioDecoder"

    /** 解码超时。畸形输入可能让 MediaCodec 一直吐不出 EOS，必须有兜底。 */
    private const val TIMEOUT_US = 10_000L
    private const val MAX_ITERATIONS = 20_000

    fun decode(context: Context, bytes: ByteArray): DecodedAudio {
        if (bytes.isEmpty()) throw IllegalArgumentException("音频为空")

        // MediaExtractor 只认路径或 fd，所以先落一个临时文件。
        // 放 cacheDir 并在 finally 里删掉，不落用户可见存储。
        val temp = File.createTempFile("ppfriend-audio-", ".bin", context.cacheDir)
        try {
            temp.writeBytes(bytes)
            return decodeFile(temp)
        } finally {
            temp.delete()
        }
    }

    private fun decodeFile(file: File): DecodedAudio {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(file.absolutePath)

            var trackIndex = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val candidate = extractor.getTrackFormat(i)
                val mime = candidate.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    trackIndex = i
                    format = candidate
                    break
                }
            }
            if (trackIndex < 0 || format == null) {
                throw IllegalStateException("没有找到音频轨（${extractor.trackCount} 条轨道）")
            }

            val mime = format.getString(MediaFormat.KEY_MIME)!!
            val sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

            extractor.selectTrack(trackIndex)
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            val output = ByteArrayOutputStream()
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var iterations = 0

            while (!outputDone) {
                if (++iterations > MAX_ITERATIONS) {
                    throw IllegalStateException("解码超过 $MAX_ITERATIONS 轮仍未结束")
                }

                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (inIndex >= 0) {
                        val buffer = codec.getInputBuffer(inIndex)!!
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(
                                inIndex, 0, 0, 0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                when (val outIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)) {
                    MediaCodec.INFO_TRY_AGAIN_LATER -> Unit

                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED ->
                        Log.d(TAG, "输出格式变为 ${codec.outputFormat}")

                    else -> {
                        if (outIndex >= 0) {
                            if (info.size > 0) {
                                val buffer = codec.getOutputBuffer(outIndex)!!
                                val chunk = ByteArray(info.size)
                                buffer.position(info.offset)
                                buffer.limit(info.offset + info.size)
                                buffer.get(chunk)
                                output.write(chunk)
                            }
                            codec.releaseOutputBuffer(outIndex, false)
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                                outputDone = true
                            }
                        }
                    }
                }
            }

            val pcm = output.toByteArray()
            if (pcm.isEmpty()) throw IllegalStateException("解码结果为空")
            Log.d(TAG, "解码 $mime → ${pcm.size} 字节 ${sampleRate}Hz/${channels}ch")
            return DecodedAudio(pcm, sampleRate, channels)
        } finally {
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
            runCatching { extractor.release() }
        }
    }
}

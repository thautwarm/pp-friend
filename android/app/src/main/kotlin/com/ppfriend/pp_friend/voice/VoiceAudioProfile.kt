package com.ppfriend.pp_friend.voice

import android.media.AudioAttributes
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaRecorder

/**
 * 原生音频配置。所有字段都由 Dart 侧传入，仅用于实测对比，不承载业务逻辑。
 *
 * 对应 docs/voice-engine.md 的「实测矩阵」：基线为
 * voiceCommunication + voiceCommunication + none + manualAec=off + speakerphone=on，
 * 在此基础上一次只动一个变量。
 */
data class VoiceAudioProfile(
    /** voiceCommunication | mic | voiceRecognition | camcorder | unprocessed | voiceUplink | voiceDownlink */
    val captureSource: String = "voiceCommunication",
    /** voiceCommunication | media —— 这一项是 AEC 能否拿到参考信号的关键 */
    val playbackUsage: String = "voiceCommunication",
    /** none | lowLatency */
    val performanceMode: String = "none",
    /** 手动叠加 AcousticEchoCanceler effect。与 VOICE_COMMUNICATION 是两条不同路径，能否叠加因机型而异 */
    val manualAec: Boolean = false,
    val speakerphone: Boolean = true,
    /** inCommunication | normal */
    val audioManagerMode: String = "inCommunication",
) {
    val captureSourceValue: Int
        get() = when (captureSource) {
            "mic" -> MediaRecorder.AudioSource.MIC
            "voiceRecognition" -> MediaRecorder.AudioSource.VOICE_RECOGNITION
            "camcorder" -> MediaRecorder.AudioSource.CAMCORDER
            "unprocessed" -> MediaRecorder.AudioSource.UNPROCESSED
            "voiceUplink" -> MediaRecorder.AudioSource.VOICE_UPLINK
            "voiceDownlink" -> MediaRecorder.AudioSource.VOICE_DOWNLINK
            else -> MediaRecorder.AudioSource.VOICE_COMMUNICATION
        }

    /**
     * 播放属性。用 USAGE_MEDIA 时 AEC 拿不到参考信号 —— 这是最容易踩、
     * 且从插件表面完全看不出来的一个坑，所以这里必须可切换以便实测对照。
     */
    fun audioAttributes(): AudioAttributes {
        val builder = AudioAttributes.Builder()
        return if (playbackUsage == "media") {
            builder.setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build()
        } else {
            builder.setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
        }
    }

    /** PERFORMANCE_MODE_LOW_LATENCY 延迟低，但官方文档写明 Effects may not work，AEC 本身就是 effect。 */
    val performanceModeValue: Int
        get() = if (performanceMode == "lowLatency") {
            AudioTrack.PERFORMANCE_MODE_LOW_LATENCY
        } else {
            AudioTrack.PERFORMANCE_MODE_NONE
        }

    val audioManagerModeValue: Int
        get() = if (audioManagerMode == "normal") {
            AudioManager.MODE_NORMAL
        } else {
            AudioManager.MODE_IN_COMMUNICATION
        }

    companion object {
        fun fromMap(map: Map<*, *>?): VoiceAudioProfile {
            if (map == null) return VoiceAudioProfile()
            return VoiceAudioProfile(
                captureSource = map["captureSource"] as? String ?: "voiceCommunication",
                playbackUsage = map["playbackUsage"] as? String ?: "voiceCommunication",
                performanceMode = map["performanceMode"] as? String ?: "none",
                manualAec = map["manualAec"] as? Boolean ?: false,
                speakerphone = map["speakerphone"] as? Boolean ?: true,
                audioManagerMode = map["audioManagerMode"] as? String ?: "inCommunication",
            )
        }
    }

    fun toMap(): Map<String, Any> = mapOf(
        "captureSource" to captureSource,
        "playbackUsage" to playbackUsage,
        "performanceMode" to performanceMode,
        "manualAec" to manualAec,
        "speakerphone" to speakerphone,
        "audioManagerMode" to audioManagerMode,
    )
}

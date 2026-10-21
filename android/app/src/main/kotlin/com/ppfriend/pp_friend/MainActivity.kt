package com.ppfriend.pp_friend

import android.view.KeyEvent
import com.ppfriend.pp_friend.voice.NativeVoiceEngine
import com.ppfriend.pp_friend.voice.VoiceEnginePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        VoiceEnginePlugin.registerWith(
            flutterEngine.dartExecutor.binaryMessenger,
            applicationContext,
        )
    }

    /**
     * 回到前台 = 用户显式回来了。永久失焦后在这里重取音频焦点，
     * 会话才能从"外部音频占用"的暂停状态里恢复。
     */
    override fun onResume() {
        super.onResume()
        NativeVoiceEngine.get(applicationContext).onAppForeground()
    }

    override fun onPause() {
        NativeVoiceEngine.get(applicationContext).onAppBackground()
        super.onPause()
    }

    /**
     * 音量减键 = "让它闭嘴"（可在设置里关掉）。
     *
     * 三个条件都满足才拦截：设置里开着、**正在播放 AI 语音**、且在前台。
     * 其余时候原样放行 —— 不然会吞掉正常的音量调节，那很烦人。
     *
     * 局限：Activity 的 onKeyDown 只在 App 处于前台时收到事件，
     * 后台/锁屏收不到。那个场景由通知栏的「停止说话」按钮覆盖，
     * 所以关掉这个开关不会让"让它闭嘴"彻底没路走。
     */
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
            val engine = NativeVoiceEngine.get(applicationContext)
            if (engine.volumeKeyClearsQueue && engine.isPlaying()) {
                engine.onClearPlaybackRequested()
                return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }
}

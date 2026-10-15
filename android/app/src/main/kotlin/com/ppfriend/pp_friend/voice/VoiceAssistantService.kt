package com.ppfriend.pp_friend.voice

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * 只负责让系统不杀进程，**不拥有**音频引擎。
 *
 * 引擎是进程内单例，Service 被回收后引擎仍然存活；反过来 Service 也不负责
 * 启动/停止音频，那由 Dart 显式控制。两边通过 markServiceRunning 互相知道对方状态。
 */
class VoiceAssistantService : Service() {

    companion object {
        private const val TAG = "VoiceAssistantService"

        const val ACTION_START = "com.ppfriend.pp_friend.voice.START"
        /** 程序化停止（Dart 主动调的）。**不发事件** —— 发起方自己知道。 */
        const val ACTION_STOP = "com.ppfriend.pp_friend.voice.STOP"

        /** 通知栏「结束」按钮。要发事件让 Dart 收尾。 */
        const val ACTION_STOP_FROM_NOTIFICATION =
            "com.ppfriend.pp_friend.voice.STOP_FROM_NOTIFICATION"

        /** 通知栏「停止说话」按钮。只清播放队列，会话继续。 */
        const val ACTION_CLEAR = "com.ppfriend.pp_friend.voice.CLEAR"

        /**
         * 渠道重要性创建后不可修改，所以第一次就必须定对。
         * LOW = 不响、不弹、不震，只在通知栏常驻。
         */
        private const val CHANNEL_ID = "voice_assistant"
        private const val CHANNEL_NAME = "PP Friend"
        private const val CHANNEL_DESC = "对话进行中时显示"
        private const val NOTIFICATION_ID = 4242

        fun start(context: Context) {
            val intent = Intent(context, VoiceAssistantService::class.java).setAction(ACTION_START)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, VoiceAssistantService::class.java).setAction(ACTION_STOP)
            context.startService(intent)
        }
    }

    private val engine get() = NativeVoiceEngine.get(this)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CLEAR -> {
                // 只清播放队列，会话继续 —— 这是后台/锁屏下唯一能用的
                // "让它闭嘴"手段，音量键在后台收不到。
                Log.d(TAG, "clear playback requested")
                engine.onClearPlaybackRequested()
                return START_STICKY
            }

            // 通知栏「结束」：转成事件交给 Dart 收尾，而不是在这里单方面
            // 把音频掐掉，否则 Dart 侧的状态机会和原生不一致。
            ACTION_STOP_FROM_NOTIFICATION -> {
                Log.d(TAG, "stop requested from notification")
                engine.onEndRequestedFromNotification()
                engine.markServiceRunning(false)
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }

            // 程序化停止：Dart 自己发起的，它清楚要收尾，**不能再发事件回去** ——
            // 那会让 stop() 重入（teardown 期间 _busy 是 true，
            // 原来的守卫 `!active && !busy` 拦不住）。
            ACTION_STOP -> {
                Log.d(TAG, "stop requested programmatically")
                engine.markServiceRunning(false)
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }

            else -> {
                ensureChannel()
                // 必须在 startForegroundService() 后 5 秒内调用，
                // 否则 RemoteServiceException。这里没有任何前置耗时操作。
                startForeground(NOTIFICATION_ID, buildNotification())
                engine.markServiceRunning(true)
                Log.d(TAG, "foreground started")
                return START_STICKY
            }
        }
    }

    override fun onDestroy() {
        engine.markServiceRunning(false)
        Log.d(TAG, "destroyed")
        super.onDestroy()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = CHANNEL_DESC
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val clearIntent = PendingIntent.getService(
            this,
            2,
            Intent(this, VoiceAssistantService::class.java).setAction(ACTION_CLEAR),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, VoiceAssistantService::class.java)
                .setAction(ACTION_STOP_FROM_NOTIFICATION),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        builder
            .setContentTitle("PP Friend")
            .setContentText("对话进行中，可切到其他应用")
            .setSmallIcon(applicationInfo.icon)
            .setContentIntent(openApp)
            .setOngoing(true)
            .addAction(
                Notification.Action.Builder(
                    null,
                    "停止说话",
                    clearIntent,
                ).build()
            )
            .addAction(
                Notification.Action.Builder(
                    null,
                    "结束",
                    stopIntent,
                ).build()
            )

        // 静默由渠道的 IMPORTANCE_LOW + setSound(null, null) 保证。
        // framework 的 Notification.Builder 没有 setSilent（那是 NotificationCompat 的）。

        return builder.build()
    }
}

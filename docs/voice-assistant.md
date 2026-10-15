# 实时语音助手 · 需求与技术方案

平台：**仅 iOS + Android** ｜ 用途：**自用**（不考虑上架审核）

---

## 1. 目标

做一个随时能对话的语音助手：

- **全双工**：用户说话 AI 听，AI 说话用户听，两个方向同时开着。
- **可打断**：AI 说话时用户随时开口，立刻打断它。
- **后台不中断**：发起对话后可以切到别的 App（微信、浏览器）或锁屏，对话继续。

音频不落盘，全程走 PCM 流，所以**不涉及任何音频容器/编码格式的选择**。

---

## 2. 使用流程

```
打开 App → 点「开始对话」          ← 这一步不可省略
   ↓
前台服务启动，通知栏出现一条常驻条目
   ↓
切到微信 / 浏览器 / 锁屏 → 录音和播放都继续
   ↓
点「结束对话」（或通知上的按钮）→ 全部停止
```

**必须由用户在前台主动发起一次。** 系统不允许 App 在后台自己起麦克风，所以"已经在别的 App 里 → 助手自己醒过来开始听"做不到。

---

## 3. 三条硬约束

| # | 约束 | 不做会怎样 |
|---|---|---|
| 1 | Android：`microphone` 类型的前台服务必须在 App **前台**时创建 | 后台创建直接 `SecurityException` |
| 2 | App 进后台后，录音必须靠前台服务撑着 | 麦克风静默失效（不报错，只是没声音）；Android 15+ 连 audio focus 都申请不到 |
| 3 | 全双工必须开硬件回声消除（AEC） | 麦克风收进扬声器里 AI 自己的声音 → 助手自己打断自己，无限循环 |

---

## 4. 三个要解决的问题

### 4.1 回声消除（AEC）— 最大风险

| 平台 | 配置 |
|---|---|
| iOS | `AVAudioSessionMode.voiceChat`（启用 VoiceProcessingIO 硬件 AEC） |
| Android | `AndroidAudioSource.voiceCommunication` + `AudioManagerMode.modeInCommunication` + `speakerphone = true` |

⚠️ 音频会话必须**全程保持 active**。频繁 `deactivate` / `activate` 会重建音频路由并重置 AEC 滤波器，导致回声泄漏。

⚠️ `RecordConfig.echoCancel`（`AcousticEchoCanceler`）与 `voiceCommunication` 是两条不同的 AEC 路径，能否叠加因机型而异，必须真机对比。

### 4.2 打断（barge-in）

AI 说话时麦克风仍然开着 → 检测到用户开口 → 立刻停掉播放 → 通知服务端取消本轮 TTS。

难点：AEC 之后仍有残留能量，单纯按能量阈值判断会**误触发**（AI 自己音量大就以为用户在说话）。需要双讲检测，或把 VAD 放到服务端。

### 4.3 后台存活

| 平台 | 做法 |
|---|---|
| Android | 一个前台服务，声明 `microphone\|mediaPlayback` 两种类型 |
| iOS | `UIBackgroundModes: audio`，会话保持 active |
| 小米 HyperOS | **必须手动设置**：自启动允许 / 省电策略无限制 / 后台弹出界面允许。不做一定被杀 |

---

## 5. 技术栈

| 用途 | 包 |
|---|---|
| 录音（PCM 流 + AEC 配置） | `record` |
| 音频会话（voiceChat 模式 / 保持 active） | `audio_session` |
| 播放（TTS 流式 PCM） | `flutter_pcm_sound` |
| Android 前台服务 | `flutter_foreground_task` |
| 权限 | `permission_handler` |

---

## 6. 前台服务的必配项

**AndroidManifest.xml**

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />

<service
    android:name="你的.VoiceAssistantService"
    android:foregroundServiceType="microphone|mediaPlayback"
    android:exported="false" />
```

**代码要点**

- `NotificationChannel` 用 `IMPORTANCE_LOW` —— 通知渠道的重要性**创建后不可改**，第一次就要定对。
- `startForeground()` 必须在 `startForegroundService()` 后 **5 秒内**调用，否则崩溃（`RemoteServiceException`）。
- 通知设 `setOngoing(true)` + 静默，避免打扰。通知上加一个「结束」按钮。
- `flutter_foreground_task` 会替你写这些 Kotlin，但 **manifest 里的权限和 `<service>` 声明要自己写**。

**iOS Info.plist**

```xml
<key>NSMicrophoneUsageDescription</key>
<string>用于语音对话</string>
<key>UIBackgroundModes</key>
<array><string>audio</string></array>
```

---

## 7. 第一步：先验证 AEC，不要先搭架构

AEC 效果无法靠文档定论，只能真机测。先做一个页面：

- 「开始对话」按钮 → 起前台服务 + 常驻通知 + 开 PCM 录音 + **循环播一段测试音频**（模拟 AI 说话）
- 屏幕上一条**实时麦克风能量条**
- 三个开关，用于对比：`voiceChat` / `voiceCommunication` / `speakerphone`

**判据**

- 播放测试音频时，麦克风能量条应该**接近静默**
- 用户对着手机说话时，能量条应该**明显抬升**

**同时测**：按 Home、锁屏、5 分钟后回来，看能量条和音频是否还活着。

**这一关不过，整个方案要改成半双工**（AI 说话时静音麦克风，说完固定时长后再开）。所以必须最先确认。

---

## 8. 不做

- Web / Windows / macOS / Linux（只构建 iOS + Android）
- 音频落盘、编码格式选型（opus / aac / ogg）
- 波形图、倍速播放、听筒/扬声器切换（那是语音消息的需求）
- 后台播放音频**文件**（这里播的是实时 TTS 流）
- 「在别的 App 里助手自己醒过来」—— 系统禁止。以后若真需要，唯一出路是做成系统默认助手（`VoiceInteractionService`）

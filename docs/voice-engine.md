# Android 原生语音引擎

范围：**只做 Android**。iOS 以后补，Dart 接口不变。

---

## 架构

```
Flutter (Dart) ──MethodChannel/EventChannel──┐
                                             ↓
   VoiceEnginePlugin (进程内单例)  ←── AudioRecord / AudioTrack / AudioManager
                                             ↑
                        VoiceAssistantService (只调 startForeground() 保活)
```

- 引擎是**进程内单例**，Service **不拥有**引擎，只负责让系统不杀进程。
- 采集和播放是两个**独立原生阻塞线程**，不跑在 Flutter main isolate 上。
- 切后台时 Dart isolate 照常运行，WebSocket / STT / LLM 留在 Dart。

---

## Dart 契约（定死，以后不改）

```dart
abstract class VoiceEngine {
  static VoiceEngine get instance =>
      Platform.isIOS ? IosVoiceEngine() : AndroidVoiceEngine();

  Future<void> beginSession();      // FGS + setMode + AEC + 开采集/播放，幂等
  Future<void> endSession();        // 释放全部资源，幂等
  Future<void> pushPlayback(Uint8List pcm16le);
  Future<void> flushPlayback();     // 打断：清空播放缓冲
  Stream<Uint8List> get micPcm;     // 16-bit LE / mono / 16k
  Stream<double> get micLevel;      // dBFS
  Stream<bool> get interruption;    // 来电、被其他 App 抢占
}
```

接口里**不出现** `audioSource` / `audioManagerMode` / `AVAudioSessionCategory` 等平台概念，全部藏在实现里。

VAD / 打断判定由 Dart（Rust FFI）负责，原生只提供 `micPcm` 和 `micLevel`。

---

## Android 三件套

| 组件 | 配置 |
|---|---|
| `AudioRecord` | `AudioSource.VOICE_COMMUNICATION`（系统强制开 AEC + NS）<br>采样率查设备实际支持值（通常 16k 或 48k）<br>`ENCODING_PCM_16BIT` |
| `AudioTrack` | ⚠️ `AudioAttributes` 用 **`USAGE_VOICE_COMMUNICATION` + `CONTENT_TYPE_SPEECH`**<br>用 `USAGE_MEDIA` 会导致 AEC 拿不到参考信号 ← 最容易踩且插件看不出来<br>`ENCODING_PCM_16BIT` + `MODE_STREAM` |
| `AudioManager` | `setMode(MODE_IN_COMMUNICATION)`<br>`setSpeakerphoneOn(true)`<br>`requestAudioFocus()` |

**性能模式取舍**：`AudioTrack` 用 `PERFORMANCE_MODE_LOW_LATENCY` 延迟低，但官方文档写明 *"Effects may not work"* —— AEC 本身就是 effect。必须实测。

**重采样**：Dart 声明的播放速率 ≠ 设备支持速率时，由原生重采样，Dart 不感知。

---

## 前台服务必配

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />

<service android:name=".VoiceAssistantService"
    android:foregroundServiceType="microphone|mediaPlayback"
    android:exported="false" />
```

- `NotificationChannel` 用 `IMPORTANCE_LOW` —— **渠道重要性创建后不可改**。
- `startForeground()` 必须在 `startForegroundService()` 后 **5 秒内**调用，否则崩溃。
- 通知设 `setOngoing(true)` + 静默，加一个「结束」按钮。
- ⚠️ Service 必须在 App **前台**时启动，后台启动会 `SecurityException`。
- ⚠️ 小米 HyperOS 需手动开：自启动 / 省电策略无限制 / 后台弹出界面。

---

## 实测矩阵

基线：`VOICE_COMMUNICATION` + `USAGE_VOICE_COMMUNICATION` + `NONE` + 手动 AEC 关 + speakerphone 开。

在此基础上**一次只动一个变量**：

| 变量 | 对比值 |
|---|---|
| 采集源 | `VOICE_COMMUNICATION` / `MIC` |
| 播放属性 | `USAGE_VOICE_COMMUNICATION` / `USAGE_MEDIA` |
| 性能模式 | `NONE` / `LOW_LATENCY` |
| 手动 AEC effect | 开 / 关 |
| speakerphone | 开 / 关 |

**判据**：播测试音频时 `micLevel` 接近静默；用户说话时明显抬升。
**同时测**：按 Home / 锁屏 / 5 分钟后回来。

---

## iOS 以后要补什么

| Dart 接口 | Android 实现 | iOS 实现 |
|---|---|---|
| `beginSession` | `setMode` + FGS + 开 AEC | `AVAudioSession` category=`playAndRecord`, mode=**`voiceChat`**, `setActive(true)` |
| 采集 | `AudioRecord` | `AVAudioEngine` inputNode |
| 播放 | `AudioTrack` | `AVAudioEngine` playerNode |
| `interruption` | 音频焦点丢失回调 | `AVAudioSession.interruptionNotification` |
| 保活 | 前台服务 | `UIBackgroundModes: audio` |

⚠️ iOS 会话必须**全程保持 active**，频繁 `deactivate`/`activate` 会重建路由并重置 AEC 滤波器。

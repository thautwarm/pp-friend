import AVFoundation
import Cocoa
import FlutterMacOS
import Network

/// 把 macOS 的语音引擎接到 Flutter 上。
///
/// 通道名、方法名、参数名和事件字段与 Android 的 `VoiceEnginePlugin.kt`
/// 一一对应；Dart 侧完全平台无关，Windows/Linux 以后照同一份契约实现即可。
final class VoiceEnginePlugin {
  static let methodChannelName = "pp_friend/voice_engine"
  static let micChannelName = "pp_friend/voice_engine/mic"
  static let levelsChannelName = "pp_friend/voice_engine/levels"
  static let eventsChannelName = "pp_friend/voice_engine/events"

  /// 通道 handler 由对象自己持有；不保留实例的话，通道会被提前释放。
  private static var shared: VoiceEnginePlugin?

  private let engine = MacVoiceEngine.shared

  private let methodChannel: FlutterMethodChannel
  private let micChannel: FlutterEventChannel
  private let levelsChannel: FlutterEventChannel
  private let eventsChannel: FlutterEventChannel

  private var micSink: FlutterEventSink?
  private var levelsSink: FlutterEventSink?
  private var eventsSink: FlutterEventSink?

  /// Ogg 解码器不是线程安全的，所有调用排到同一条串行队列。
  private let oggQueue = DispatchQueue(label: "pp_friend.voice.ogg")

  static func register(with messenger: FlutterBinaryMessenger) {
    shared = VoiceEnginePlugin(messenger: messenger)
  }

  private init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: Self.methodChannelName, binaryMessenger: messenger)
    micChannel = FlutterEventChannel(name: Self.micChannelName, binaryMessenger: messenger)
    levelsChannel = FlutterEventChannel(
      name: Self.levelsChannelName, binaryMessenger: messenger)
    eventsChannel = FlutterEventChannel(
      name: Self.eventsChannelName, binaryMessenger: messenger)

    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }

    wire(engine)
  }

  private func wire(_ engine: MacVoiceEngine) {
    micChannel.setStreamHandler(
      SinkHandler(
        onListen: { [weak self] sink in
          self?.micSink = sink
          engine.onMicFrame = { data in sink(FlutterStandardTypedData(bytes: data)) }
        },
        onCancel: { [weak self] in
          self?.micSink = nil
          engine.onMicFrame = nil
        }
      ))

    levelsChannel.setStreamHandler(
      SinkHandler(
        onListen: { [weak self] sink in
          self?.levelsSink = sink
          engine.onLevels = { mic, playback in sink([mic, playback]) }
        },
        onCancel: { [weak self] in
          self?.levelsSink = nil
          engine.onLevels = nil
        }
      ))

    eventsChannel.setStreamHandler(
      SinkHandler(
        onListen: { [weak self] sink in
          self?.eventsSink = sink
          engine.onEvent = { event in sink(event) }
        },
        onCancel: { [weak self] in
          self?.eventsSink = nil
          engine.onEvent = nil
        }
      ))
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]

    switch call.method {
    case "startService":
      engine.startService()
      result(true)

    case "stopService":
      engine.stopService()
      result(true)

    case "serviceRunning":
      result(engine.serviceRunning)

    case "applyDebugProfile":
      // macOS 没有 AudioManager 那套采集源/路由参数，原样回显即可。
      result(args)

    case "setVolumeKeyClearsQueue":
      engine.volumeKeyClearsQueue = args["enabled"] as? Bool ?? true
      result(true)

    case "startAudio":
      let preferred = (args["preferredSampleRate"] as? NSNumber)?.intValue ?? 16000
      do {
        result(try engine.startAudio(preferredSampleRate: preferred))
      } catch {
        result(
          FlutterError(
            code: "startAudioFailed",
            message: error.localizedDescription,
            details: nil))
      }

    case "stopAudio":
      engine.stopAudio()
      result(true)

    case "pushPlayback":
      guard let pcm = args["pcm"] as? FlutterStandardTypedData,
        let epoch = args["epoch"] as? NSNumber
      else {
        result(
          FlutterError(code: "badArgs", message: "pushPlayback 需要 pcm 与 epoch", details: nil))
        return
      }
      engine.pushPlayback(pcm: pcm.data, epoch: epoch.int64Value)
      result(true)

    case "flushPlayback":
      guard let epoch = args["newEpoch"] as? NSNumber else {
        result(FlutterError(code: "badArgs", message: "flushPlayback 需要 newEpoch", details: nil))
        return
      }
      result(engine.flushPlayback(newEpoch: epoch.int64Value))

    case "playbackBacklogFrames":
      result(engine.playbackBacklogFrames)

    case "playbackHeadMs":
      result(engine.playbackHeadMs)

    case "droppedMicFrames":
      result(engine.droppedMicFrames)

    case "isAudioRunning":
      result(engine.isAudioRunning)

    case "opusEncoderAvailable":
      result(engine.opusEncoderAvailable())

    case "encodeOpus":
      guard let pcm = args["pcm"] as? FlutterStandardTypedData,
        let rate = args["sampleRate"] as? NSNumber
      else {
        result(FlutterError(code: "badArgs", message: "encodeOpus 需要 pcm 与 sampleRate", details: nil))
        return
      }
      let channels = (args["channels"] as? NSNumber)?.intValue ?? 1
      DispatchQueue.global(qos: .userInitiated).async {
        let encoded = self.engine.encodeOpus(
          pcm: pcm.data, sampleRate: rate.intValue, channels: channels)
        DispatchQueue.main.async { result(encoded) }
      }

    case "feedOggStream":
      guard let bytes = args["bytes"] as? FlutterStandardTypedData else {
        result(FlutterError(code: "badArgs", message: "feedOggStream 需要 bytes", details: nil))
        return
      }
      oggQueue.async {
        do {
          let decoded = try self.engine.feedOggStream(bytes: bytes.data)
          DispatchQueue.main.async { result(decoded) }
        } catch {
          // 解码器可能进了错误状态：这条算失败，下一条从干净的 OpusHead 重来。
          self.engine.resetOggStream()
          DispatchQueue.main.async {
            result(
              FlutterError(
                code: "decodeFailed", message: error.localizedDescription, details: nil))
          }
        }
      }

    case "finishOggStream":
      oggQueue.async {
        do {
          let decoded = try self.engine.finishOggStream()
          DispatchQueue.main.async { result(decoded) }
        } catch {
          self.engine.resetOggStream()
          DispatchQueue.main.async {
            result(
              FlutterError(
                code: "decodeFailed", message: error.localizedDescription, details: nil))
          }
        }
      }

    case "resetOggStream":
      oggQueue.async {
        self.engine.resetOggStream()
        DispatchQueue.main.async { result(true) }
      }

    case "decodeAudio":
      guard let bytes = args["bytes"] as? FlutterStandardTypedData else {
        result(FlutterError(code: "badArgs", message: "decodeAudio 需要 bytes", details: nil))
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let decoded = try self.engine.decodeAudio(bytes: bytes.data)
          DispatchQueue.main.async { result(decoded) }
        } catch {
          DispatchQueue.main.async {
            result(
              FlutterError(
                code: "decodeFailed", message: error.localizedDescription, details: nil))
          }
        }
      }

    // ---- macOS 额外的方法 ----

    case "requestMicPermission":
      requestMicPermission(result: result)

    case "micPermissionStatus":
      result(Self.micPermissionStatus())

    case "probeLocalNetwork":
      probeLocalNetwork(args, result: result)

    case "openLocalNetworkSettings":
      Self.openLocalNetworkSettings()
      result(true)

    case "openMicSettings":
      Self.openMicSettings()
      result(true)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // ---------------------------------------------------------------- 本地网络

  /// 用 Network.framework 主动连一下目标地址。
  ///
  /// macOS 15+ 的本地网络授权只对「App 自己发起的网络请求」弹框；Dart 的
  /// HttpClient 走 BSD socket，系统可能既不弹框、也直接拒绝（表现为 brain
  /// 永远无响应）。这里连一下同一地址，把系统弹窗逼出来；授权之后 Dart 的
  /// 请求就能通。
  ///
  /// 返回 "ready" 只代表 TCP 连上了，不代表 HTTP 一定成功；"failed" 也
  /// 不阻止会话继续（brain 可能只是暂时没开机）。
  private func probeLocalNetwork(
    _ args: [String: Any], result: @escaping FlutterResult
  ) {
    guard let host = args["host"] as? String, !host.isEmpty,
      let portNumber = (args["port"] as? NSNumber)?.uint16Value,
      let port = NWEndpoint.Port(rawValue: portNumber)
    else {
      result("badArgs")
      return
    }

    let timeoutMs = (args["timeoutMs"] as? NSNumber)?.intValue ?? 5000
    let connection = NWConnection(
      host: NWEndpoint.Host(host), port: port, using: .tcp)

    let lock = NSLock()
    var finished = false
    func finish(_ status: String) {
      lock.lock()
      if finished {
        lock.unlock()
        return
      }
      finished = true
      lock.unlock()
      connection.cancel()
      DispatchQueue.main.async { result(status) }
    }

    connection.stateUpdateHandler = { state in
      switch state {
      case .ready:
        finish("ready")
      case .failed, .cancelled:
        finish("failed")
      default:
        break
      }
    }
    connection.start(queue: DispatchQueue.global(qos: .userInitiated))
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
      finish("timeout")
    }
  }

  private static func openLocalNetworkSettings() {
    guard
      let url = URL(
        string:
          "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }

  // ---------------------------------------------------------------- 权限

  private func requestMicPermission(result: @escaping FlutterResult) {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      result(true)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async { result(granted) }
      }
    case .denied, .restricted:
      result(false)
    @unknown default:
      result(false)
    }
  }

  private static func micPermissionStatus() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "notDetermined"
    }
  }

  private static func openMicSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    else { return }
    NSWorkspace.shared.open(url)
  }
}

/// 把 EventChannel 的 onListen/onCancel 转成闭包。
private final class SinkHandler: NSObject, FlutterStreamHandler {
  private let onListenBlock: (@escaping FlutterEventSink) -> Void
  private let onCancelBlock: () -> Void

  init(
    onListen: @escaping (@escaping FlutterEventSink) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.onListenBlock = onListen
    self.onCancelBlock = onCancel
  }

  func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    onListenBlock(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    onCancelBlock()
    return nil
  }
}

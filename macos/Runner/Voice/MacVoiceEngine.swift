import AVFoundation
import Cocoa
import FlutterMacOS

/// macOS 侧的语音引擎。
///
/// 语义和 Android 的 `NativeVoiceEngine` 对齐：20ms 一帧、epoch 过滤、
/// flush 后播放头归零、backlog 含设备缓冲、电平 ~30Hz。
///
/// 音频 I/O 用 AVAudioEngine：
/// - 采集：inputNode tap + VPIO（Apple 的 AEC）。
/// - 播放：AVAudioPlayerNode → mainMixer → output。
/// - 播放电平：mainMixer 上的 tap（混音后、系统音量前）。
///
/// 可移植的计时/分帧逻辑在 `AudioSupport.swift`，这里只做 AVFoundation 接线。
final class MacVoiceEngine {
  static let shared = MacVoiceEngine()

  // ---------------------------------------------------------------- 回调

  /// 采集 PCM（mono 16-bit LE）。
  var onMicFrame: ((Data) -> Void)?

  /// [micDb, playbackDb]，dBFS，静默 -120。
  var onLevels: ((Double, Double) -> Void)?

  /// 离散事件，字段与 Android 完全一致。
  var onEvent: (([String: Any]) -> Void)?

  var volumeKeyClearsQueue = true

  // ---------------------------------------------------------------- 状态

  private let audio = AVAudioEngine()
  private let player = AVAudioPlayerNode()

  private var running = false
  private var sampleRate: Double = 48_000
  private var framesPerChunk = 960
  private var playbackFormat: AVAudioFormat?
  private var framer: MicFramer?
  private var timeline = PlaybackTimeline()

  private var playerAttached = false
  private var inputTapInstalled = false
  private var mixerTapInstalled = false
  private var configObserver: NSObjectProtocol?
  private var wakeObserver: NSObjectProtocol?

  private let stateLock = NSLock()
  private var micDb: Double = -120
  private var playbackDb: Double = -120
  private var lastPlaybackLevelAt: CFTimeInterval = 0
  private var lastPermissionCheckAt: CFTimeInterval = 0
  private var restartScheduled = false

  /// 下一次 push 必须显式 play 一次。
  ///
  /// stop()/reset() 之后 isPlaying 不一定可靠；引擎被系统停掉再重启时
  /// 更明显。不强制 play 的话 buffer 会静静躺在队列里，等下一次 play
  /// 才一起放出来 —— 听起来就是“刚才的 AI 语音半天没响，后来突然补播”。
  private var needsPlayerPlay = true

  /// 会话期间阻止 App Nap，不然长时间空闲后定时器和音频都可能被系统节流。
  private var micActivity: NSObjectProtocol?

  /// 防睡眠锁：说话/放音时续期，安静满 60 秒就释放，允许系统睡眠。
  /// 和 App Nap 是两件事：这个带 idleSystemSleepDisabled，只防“整机睡”。
  private var sleepGuard: NSObjectProtocol?
  private var sleepGuardTimer: Timer?
  private var lastSleepGuardRefreshAt: CFTimeInterval = 0
  private static let sleepGuardWindow: TimeInterval = 60
  private static let sleepGuardThrottle: TimeInterval = 1.0

  /// 最近一次收到采集 buffer 的时刻（watchdog 用，和音量无关）。
  private var lastMicBufferAt: CFTimeInterval = 0
  private var micStallRestarts = 0
  private var lastMicWatchdogAt: CFTimeInterval = 0

  private var pendingMicFrames = 0
  private var droppedMicFrameCount = 0
  private var headBaseline: AVAudioFramePosition?

  private var levelsTimer: Timer?

  /// 主线程队列里最多压多少帧（24 × 20ms ≈ 480ms）。超了丢新帧并计数。
  private static let maxPendingMicFrames = 24

  private init() {}

  // ---------------------------------------------------------------- 服务

  func startService() {}
  func stopService() {}
  var serviceRunning: Bool { false }

  // ---------------------------------------------------------------- 音频生命周期

  func startAudio(preferredSampleRate: Int) throws -> [String: Any] {
    if running { return currentFormatMap() }
    stopAudioInternal()

    let input = audio.inputNode

    // 先开 VPIO 再读格式：VPIO 会把输入固定到它自己的格式（常见 44.1k，
    // 多声道时 channel 0 是处理后的麦克风，其余是元数据）。
    do {
      try input.setVoiceProcessingEnabled(true)
    } catch {
      // 没有 AEC 也要能说话：退回普通输入，至少不是不能用的状态。
      emit([
        "type": "engineFailure",
        "reason": "无法开启回声消除：\(error.localizedDescription)",
      ])
    }

    let inFormat = input.outputFormat(forBus: 0)
    guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
      throw NSError(
        domain: "pp_friend", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "没有可用的麦克风输入格式"])
    }

    sampleRate = inFormat.sampleRate
    framesPerChunk = max(1, Int((sampleRate / 50.0).rounded()))

    guard
      let pbFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false)
    else {
      throw NSError(
        domain: "pp_friend", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "建不出播放格式"])
    }
    playbackFormat = pbFormat

    audio.attach(player)
    playerAttached = true
    audio.connect(player, to: audio.mainMixerNode, format: pbFormat)

    let frameBytes = framesPerChunk * 2
    framer = MicFramer(frameBytes: frameBytes)
    input.installTap(
      onBus: 0,
      bufferSize: AVAudioFrameCount(framesPerChunk),
      format: inFormat
    ) { [weak self] buffer, _ in
      self?.handleInput(buffer)
    }
    inputTapInstalled = true

    audio.mainMixerNode.installTap(
      onBus: 0, bufferSize: 1024, format: nil
    ) { [weak self] buffer, _ in
      self?.handlePlaybackLevel(buffer)
    }
    mixerTapInstalled = true

    audio.prepare()
    do {
      try audio.start()
    } catch {
      stopAudioInternal()
      throw error
    }

    running = true
    timeline = PlaybackTimeline()
    headBaseline = nil
    needsPlayerPlay = true
    micStallRestarts = 0
    lastMicBufferAt = CACurrentMediaTime()
    lastPermissionCheckAt = CACurrentMediaTime()
    micActivity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiated, reason: "PP Friend voice session")
    refreshSleepGuard()
    startLevelsTimer()
    installConfigObserver()
    return currentFormatMap()
  }

  func stopAudio() {
    guard running else { return }
    stopAudioInternal()
  }

  var isAudioRunning: Bool { running }

  private func stopAudioInternal() {
    running = false
    restartScheduled = false
    needsPlayerPlay = true
    if let activity = micActivity {
      ProcessInfo.processInfo.endActivity(activity)
      micActivity = nil
    }
    releaseSleepGuard()
    levelsTimer?.invalidate()
    levelsTimer = nil

    if let observer = configObserver {
      NotificationCenter.default.removeObserver(observer)
      configObserver = nil
    }
    if let observer = wakeObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      wakeObserver = nil
    }

    if inputTapInstalled {
      audio.inputNode.removeTap(onBus: 0)
      inputTapInstalled = false
    }
    if mixerTapInstalled {
      audio.mainMixerNode.removeTap(onBus: 0)
      mixerTapInstalled = false
    }

    player.stop()
    if playerAttached {
      audio.detach(player)
      playerAttached = false
    }
    audio.stop()
    // 引擎已经停了，这时关 VPIO 才是安全的。
    try? audio.inputNode.setVoiceProcessingEnabled(false)

    timeline = PlaybackTimeline()
    headBaseline = nil
    framer?.reset()
    framer = nil
    playbackFormat = nil

    stateLock.lock()
    micDb = -120
    playbackDb = -120
    pendingMicFrames = 0
    stateLock.unlock()
    onLevels?(-120, -120)
  }

  private func currentFormatMap() -> [String: Any] {
    [
      "sampleRate": Int(sampleRate),
      "channels": 1,
      "framesPerChunk": framesPerChunk,
    ]
  }

  // ---------------------------------------------------------------- 采集

  private func handleInput(_ buffer: AVAudioPCMBuffer) {
    guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
    let count = Int(buffer.frameLength)
    // VPIO 打开后 channel 0 是处理过的麦克风；没开时也取第一路。
    let samples = channels[0]

    let db = rmsDb(samples, count: count)
    stateLock.lock()
    micDb = db
    lastMicBufferAt = CACurrentMediaTime()
    stateLock.unlock()

    // 说话才续防睡眠锁；安静时让它 60 秒后自然过期。
    if db > -45 {
      DispatchQueue.main.async { [weak self] in
        self?.refreshSleepGuard()
      }
    }

    let pcm = floatToInt16LE(samples, count: count)
    stateLock.lock()
    let frames = framer?.append(pcm) ?? []
    stateLock.unlock()

    for frame in frames {
      deliverMicFrame(frame)
    }
  }

  private func deliverMicFrame(_ frame: Data) {
    stateLock.lock()
    if pendingMicFrames >= Self.maxPendingMicFrames {
      droppedMicFrameCount += frame.count / 2
      stateLock.unlock()
      return
    }
    pendingMicFrames += 1
    stateLock.unlock()

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.onMicFrame?(frame)
      self.stateLock.lock()
      self.pendingMicFrames -= 1
      self.stateLock.unlock()
    }
  }

  var droppedMicFrames: Int {
    stateLock.lock()
    defer { stateLock.unlock() }
    return droppedMicFrameCount
  }

  // ---------------------------------------------------------------- 播放

  func pushPlayback(pcm: Data, epoch: Int64) {
    guard running, let format = playbackFormat else { return }
    guard timeline.accepts(epoch: epoch) else { return }

    let frames = pcm.count / 2
    guard frames > 0,
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
    else { return }
    buffer.frameLength = AVAudioFrameCount(frames)

    pcm.withUnsafeBytes { raw in
      guard let src = raw.bindMemory(to: Int16.self).baseAddress,
        let dst = buffer.floatChannelData?[0]
      else { return }
      for i in 0..<frames {
        dst[i] = Float(src[i]) / 32768.0
      }
    }

    let generation = timeline.schedule(frames)
    // **先排 buffer，再 play。** 反过来会在队列为空时先启动节点，
    // 个别设备上第一块会晚半拍。
    player.scheduleBuffer(
      buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack
    ) { [weak self] _ in
      DispatchQueue.main.async {
        guard let self else { return }
        self.timeline.played(frames, generation: generation)
        // 不要在 completion handler 里 stop 播放器：Apple 明确说这可能在
        // 渲染队列上死锁，而且 flush 之后过期的回调可能误停新的一条。
        // 队列空了就让它空转，下一块落下来会继续播。
      }
    }
    ensurePlayerStarted()
  }

  /// 保证引擎在跑、播放器真的在 play。
  private func ensurePlayerStarted() {
    if !audio.isRunning {
      do {
        try audio.start()
      } catch {
        emit([
          "type": "engineFailure",
          "reason": "音频引擎意外停止后重启失败：\(error.localizedDescription)",
        ])
        return
      }
      needsPlayerPlay = true
    }
    if needsPlayerPlay || !player.isPlaying {
      player.play()
      needsPlayerPlay = false
      headBaseline = nil
    }
  }

  func flushPlayback(newEpoch: Int64) -> Int {
    let discarded = timeline.flush(newEpoch: newEpoch)
    // stop() 丢掉还没播的 buffer；reset() 再清节点内部状态。VPIO 下
    // 只 stop 有时仍会把已经交给渲染线程的那一块放完，听起来就是
    // “打断了还在响”。
    player.stop()
    player.reset()
    needsPlayerPlay = true
    headBaseline = nil
    return discarded
  }

  var playbackBacklogFrames: Int { timeline.backlogFrames }

  var playbackHeadMs: Int {
    guard running, player.isPlaying, let nodeTime = player.lastRenderTime,
      let playerTime = player.playerTime(forNodeTime: nodeTime)
    else { return 0 }

    if headBaseline == nil { headBaseline = playerTime.sampleTime }
    let played = playerTime.sampleTime - (headBaseline ?? 0)
    guard played > 0 else { return 0 }
    return Int(Double(played) * 1000.0 / sampleRate)
  }

  // ---------------------------------------------------------------- 防睡眠

  /// 说话/放音时续期；安静满 60 秒自动释放，让系统按正常策略睡眠。
  private func refreshSleepGuard() {
    let now = CACurrentMediaTime()
    if sleepGuard != nil && now - lastSleepGuardRefreshAt < Self.sleepGuardThrottle {
      return
    }
    lastSleepGuardRefreshAt = now
    if sleepGuard == nil {
      sleepGuard = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .idleSystemSleepDisabled],
        reason: "PP Friend conversation")
    }
    sleepGuardTimer?.invalidate()
    sleepGuardTimer = Timer.scheduledTimer(
      withTimeInterval: Self.sleepGuardWindow, repeats: false
    ) { [weak self] _ in
      self?.releaseSleepGuard()
    }
  }

  private func releaseSleepGuard() {
    sleepGuardTimer?.invalidate()
    sleepGuardTimer = nil
    if let token = sleepGuard {
      ProcessInfo.processInfo.endActivity(token)
      sleepGuard = nil
    }
    lastSleepGuardRefreshAt = 0
  }

  // ---------------------------------------------------------------- 电平

  private func handlePlaybackLevel(_ buffer: AVAudioPCMBuffer) {
    guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
    let db = rmsDb(channels[0], count: Int(buffer.frameLength))
    stateLock.lock()
    playbackDb = db
    lastPlaybackLevelAt = CACurrentMediaTime()
    stateLock.unlock()

    // AI 在出声也算“在用”，同样续一下防睡眠锁。
    if db > -45 {
      DispatchQueue.main.async { [weak self] in
        self?.refreshSleepGuard()
      }
    }
  }

  private func startLevelsTimer() {
    levelsTimer?.invalidate()
    levelsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
      [weak self] _ in
      guard let self else { return }

      // 运行中权限被撤销：输入还有格式，但只会给静音。每秒查一次，
      // 发现不是 authorized 就当麦克风死了，别装作还在工作。
      let now = CACurrentMediaTime()
      if now - self.lastPermissionCheckAt > 1.0 {
        self.lastPermissionCheckAt = now
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
          self.emit([
            "type": "micSilentlyDead",
            "reason": "系统麦克风权限已被撤销",
          ])
          self.stopAudioInternal()
          return
        }
      }

      // 长时间空闲后系统可能悄悄停掉音频图：引擎还标着 running，tap 却
      // 不再送 buffer。用「有没有采集数据」判断，和音量无关，所以真安静
      // 时不会误判。重启几次还不行就按 micSilentlyDead 停掉会话。
      if now - self.lastMicWatchdogAt > 1.0 {
        self.lastMicWatchdogAt = now
        self.stateLock.lock()
        let lastMic = self.lastMicBufferAt
        self.stateLock.unlock()
        if self.running && !self.restartScheduled && lastMic > 0
          && now - lastMic > 2.0
        {
          if self.micStallRestarts < 3 {
            self.micStallRestarts += 1
            self.emit([
              "type": "engineFailure",
              "reason": "麦克风 2 秒没有数据，重建音频图（第 \(self.micStallRestarts) 次）",
            ])
            _ = self.rebuildAudioGraph()
          } else {
            self.emit([
              "type": "micSilentlyDead",
              "reason": "麦克风长时间没有数据，重建音频图无效",
            ])
            self.stopAudioInternal()
          }
          return
        }
      }

      self.stateLock.lock()
      let mic = self.micDb
      var playback = self.playbackDb
      if CACurrentMediaTime() - self.lastPlaybackLevelAt > 0.1 {
        playback = -120
        self.playbackDb = -120
      }
      self.stateLock.unlock()
      self.onLevels?(mic, playback)
    }
  }

  // ---------------------------------------------------------------- 设备变化

  private func installConfigObserver() {
    configObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: audio,
      queue: .main
    ) { [weak self] _ in
      self?.scheduleGraphRestart()
    }

    // 睡眠/唤醒：AVAudioEngine 在唤醒后经常需要重新 start。
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.scheduleGraphRestart()
    }
  }

  /// 设备变化/唤醒后给系统一点时间，再重启音频图并补一对打断事件。
  private func scheduleGraphRestart() {
    // 设备变化和唤醒可能连着来，合并成一次重启。
    guard running, !restartScheduled else { return }
    restartScheduled = true
    emit([
      "type": "interruptionBegan",
      "transient": true,
      "canDuck": false,
    ])
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      guard let self else { return }
      self.restartScheduled = false
      guard self.running else { return }
      if self.rebuildAudioGraph() {
        self.emit([
          "type": "interruptionEnded",
          "shouldResume": true,
        ])
      }
    }
  }

  /// 停掉引擎、重新读输入格式、重装 tap、再启动。
  ///
  /// 只 `stop/prepare/start` 不重装 tap 是不够的：长时间空闲或设备变化后，
  /// 引擎可能还标着 running，但输入 tap 已经不再送 buffer，表现就是
  /// “麦一直开着，但说什么它都不理”。这里把采集链路整体重建。
  @discardableResult
  private func rebuildAudioGraph() -> Bool {
    guard running else { return false }
    audio.stop()
    if inputTapInstalled {
      audio.inputNode.removeTap(onBus: 0)
      inputTapInstalled = false
    }

    do {
      try? audio.inputNode.setVoiceProcessingEnabled(true)
      let format = audio.inputNode.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else {
        throw NSError(
          domain: "pp_friend", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "没有可用的麦克风输入格式"])
      }
      // Dart 侧还在按旧采样率解释 mic 帧；输入速率变了就停掉，让用户重开。
      if Int(format.sampleRate) != Int(sampleRate) {
        emit([
          "type": "micSilentlyDead",
          "reason": "输入采样率从 \(Int(sampleRate)) 变为 \(Int(format.sampleRate))，请重新开始会话",
        ])
        stopAudioInternal()
        return false
      }

      framer = MicFramer(frameBytes: framesPerChunk * 2)
      audio.inputNode.installTap(
        onBus: 0,
        bufferSize: AVAudioFrameCount(framesPerChunk),
        format: format
      ) { [weak self] buffer, _ in
        self?.handleInput(buffer)
      }
      inputTapInstalled = true

      audio.prepare()
      try audio.start()
      needsPlayerPlay = true
      ensurePlayerStarted()
      lastMicBufferAt = CACurrentMediaTime()
      micStallRestarts = 0
      return true
    } catch {
      emit([
        "type": "engineFailure",
        "reason": "音频图重建失败：\(error.localizedDescription)",
      ])
      return false
    }
  }

  // ---------------------------------------------------------------- 编解码

  /// 下行连续 Ogg 流解码器。插件层保证所有调用都在同一个串行队列上。
  private let oggDecoder = OggOpusDecoder()

  func opusEncoderAvailable() -> Bool { OggOpusEncoder.available() }

  func encodeOpus(pcm: Data, sampleRate: Int, channels: Int) -> Data? {
    try? OggOpusEncoder.encode(
      pcm: pcm, sampleRate: sampleRate, channels: channels)
  }

  func feedOggStream(bytes: Data) throws -> [String: Any]? {
    try oggDecoder.feed(bytes)?.map
  }

  func finishOggStream() throws -> [String: Any]? {
    try oggDecoder.finish()?.map
  }

  func resetOggStream() {
    oggDecoder.reset()
  }

  func decodeAudio(bytes: Data) throws -> [String: Any] {
    // 只有 Ogg Opus 走这条路；WAV/MP3 当前没有调用方。
    guard bytes.count >= 4, bytes.prefix(4) == Data("OggS".utf8) else {
      throw NSError(
        domain: "pp_friend", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "只支持 Ogg Opus"])
    }
    let decoder = OggOpusDecoder()
    guard let decoded = try decoder.feed(bytes) else {
      throw NSError(
        domain: "pp_friend", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Ogg Opus 里没有可解码的音频"])
    }
    return decoded.map
  }

  // ---------------------------------------------------------------- 工具

  private func emit(_ event: [String: Any]) {
    onEvent?(event)
  }
}

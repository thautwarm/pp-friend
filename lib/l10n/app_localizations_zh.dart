// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get save => '保存';

  @override
  String get saved => '已保存';

  @override
  String get delete => '删除';

  @override
  String get clear => '清空';

  @override
  String get cancel => '算了';

  @override
  String get settingsTitle => '配置';

  @override
  String get tabProfiles => '档案';

  @override
  String get tabGeneral => '通用';

  @override
  String get languageSection => '语言';

  @override
  String get languageFollowSystem => '跟随系统';

  @override
  String get languageChinese => '中文';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageJapanese => '日本語';

  @override
  String get languageChanged => '界面语言已切换';

  @override
  String saveFailed(String error) {
    return '没保存成功：$error';
  }

  @override
  String get profileGoneUnsaved => '这个档案已经不在了，改动没有保存';

  @override
  String get noAppToOpenPage => '没找到能打开网页的应用';

  @override
  String openPageFailed(String error) {
    return '打开网页失败：$error';
  }

  @override
  String get voiceprintImported => '声纹已导入';

  @override
  String notVoiceprint(String message) {
    return '这个文件不是声纹：$message';
  }

  @override
  String importFailed(String error) {
    return '导入失败：$error';
  }

  @override
  String get voiceprintRemoved => '声纹已删除';

  @override
  String saveFailedBeforeSwitch(String error) {
    return '没保存成功，先别切：$error';
  }

  @override
  String saveFailedBeforeAdd(String error) {
    return '没保存成功，先别新建：$error';
  }

  @override
  String get newProfile => '新档案';

  @override
  String get newProfileTooltip => '新建档案';

  @override
  String get profileDisabled => '已关闭';

  @override
  String get localSegmentation => '本地断句';

  @override
  String get localSegmentationBody =>
      '在手机上用 Silero VAD 切句，只上传成句的片段。\n这些参数是全局的，切换档案不会重新加载模型。';

  @override
  String get vadMinSilenceMsLabel => '静音判定 (ms)';

  @override
  String get vadMinSilenceMsHint => '700 —— 最重要的一项。调小更跟手，太小会切断句内停顿';

  @override
  String get vadThresholdLabel => '语音概率阈值';

  @override
  String get vadThresholdHint => '0.5 —— 0~1。调低更容易触发，调高更保守';

  @override
  String get vadSpeechPadMsLabel => '前后外扩 (ms)';

  @override
  String get vadSpeechPadMsHint => '200 —— 段两端各留一点，不留会切掉第一个字';

  @override
  String get vadMinSpeechMsLabel => '最短有效语音 (ms)';

  @override
  String get vadMinSpeechMsHint => '300 —— 比这短直接丢，咳嗽一声不触发上传';

  @override
  String get vadMaxSpeechSLabel => '最长一句 (s)';

  @override
  String get vadMaxSpeechSHint => '60 —— 说超过就强制切开，避免一直说不完';

  @override
  String get speakerRecognition => '说话人识别';

  @override
  String get onlyMyVoice => '只识别本人的声音';

  @override
  String get voiceprintImportedStatus => '已导入声纹';

  @override
  String get voiceprintNeeded => '需要先导入声纹';

  @override
  String get openVoiceprintPage => '本地创建你的声纹并下载';

  @override
  String get voiceprintOptionalHint => '可选。声纹用来过滤别人的声音和杂音，只把你自己的话发给 agent。';

  @override
  String get reimportVoiceprint => '重新导入声纹';

  @override
  String get importVoiceprint => '导入声纹';

  @override
  String get deleteVoiceprint => '删除声纹';

  @override
  String get similarityThreshold => '相似度阈值';

  @override
  String get volumeKeys => '音量键';

  @override
  String get volumeKeyClearsQueue => '音量减键清空队列';

  @override
  String get volumeKeySubtitle => '开着：AI 说话时按音量减让它闭嘴（仅前台）。\n后台和锁屏用通知栏的「停止说话」。';

  @override
  String get settingsNotice =>
      '识别和合成在 brain 那边，手机只负责采集、切句、上传、播放。\n本机保存的是展示用的历史，不是对话上下文；删掉它不影响 brain 那边的记忆。';

  @override
  String get profileAppearance => '这个档案长什么样';

  @override
  String get nameLabel => '名字';

  @override
  String get nameHint => '例如 员工3 —— 留空就用 brain_id';

  @override
  String get themeColor => '主题色';

  @override
  String get colorIndigo => '靛蓝';

  @override
  String get colorInkGreen => '墨绿';

  @override
  String get colorTerracotta => '陶土';

  @override
  String get colorPurple => '紫';

  @override
  String get colorLakeBlue => '湖蓝';

  @override
  String get colorOchre => '赭黄';

  @override
  String get colorRose => '玫红';

  @override
  String get colorSlate => '石板';

  @override
  String get baseUrlLabel => 'Base URL';

  @override
  String get baseUrlHint => 'http://192.168.0.100:8000';

  @override
  String get brainIdLabel => 'brain_id';

  @override
  String get brainIdHint => '例如 员工3 —— 像名字一样有语义';

  @override
  String get tokenLabel => 'Bearer token';

  @override
  String get tokenHint => '留空表示该部署没启用鉴权，不会发这个头';

  @override
  String get statusSection => '状态';

  @override
  String get enabled => '启用';

  @override
  String get enabledSubtitleOn => '会一直收它的消息（没聚焦时只记文字，不出声）';

  @override
  String get enabledSubtitleOff => '不连它。历史仍然留在盘上，随时可以再打开';

  @override
  String get focusedDisabledWarning => '它现在是主界面上选中的那个。保存之后会自动切到别的开着的档案。';

  @override
  String get switchToThisProfile => '切到这个档案';

  @override
  String get switchBySwipeHint => '主界面上左右滑说话按钮也能切';

  @override
  String get historySection => '历史';

  @override
  String historyUsage(String size) {
    return '盘上占 $size。\n永久保留，没有自动清理 —— 攒到几百 MB 就自己来这里清。';
  }

  @override
  String get clearHistoryTitle => '清空这个档案的历史？';

  @override
  String get clearHistoryBody =>
      '主界面上这个档案的消息会全部消失，而且找不回来。\n\nbrain 那边的记忆不受影响 —— 本地存的是展示用的历史，对话上下文一直挂在 brain_id 上。';

  @override
  String get historyCleared => '已清空';

  @override
  String deleteProfileTitle(String name) {
    return '删掉「$name」？';
  }

  @override
  String get deleteProfileBody =>
      '这个档案的 brain 配置和主题色都会没。\n\n盘上的历史不跟着删 —— 万一删错了，那一份还在。';

  @override
  String get deleteProfileAction => '删除这个档案';

  @override
  String get chooseAvatar => '选头像';

  @override
  String get changeAvatar => '换头像';

  @override
  String get removeAvatar => '去掉';

  @override
  String avatarPickFailed(String error) {
    return '打不开相册：$error';
  }

  @override
  String get debugPanelTooltip => '调试面板';

  @override
  String get brainConfigTooltip => 'brain 配置';

  @override
  String get starting => '请稍候…';

  @override
  String get tapToStart => '点击开始对话';

  @override
  String get segmenterUnavailable => '⚠️ 断句引擎不可用';

  @override
  String get tokenInvalid => '⚠️ token 无效';

  @override
  String get brainUnresponsive => '⚠️ brain 无响应';

  @override
  String get mutedUploadingOff => '闭麦中 · 说的话不会上传';

  @override
  String get speakingCanClear => '正在说话 · 音量减可以清空';

  @override
  String get speaking => '正在说话';

  @override
  String get listening => '正在听你说';

  @override
  String queuedUtterances(int count) {
    return '还有 $count 句在上传';
  }

  @override
  String get idleHint => '直接说话就行';

  @override
  String get emptyHint => '开始之后，你和它说的话都会出现在这里';

  @override
  String get segmenterLoadFailed => '本地断句引擎加载失败';

  @override
  String get segmenterLoadFailedBody =>
      '多半是 Rust 动态库（librust_lib_pp_friend.so）没打进 APK，或 ABI 对不上。重跑 tools/build_rust_android.sh 再装一次。';

  @override
  String get noBrain => '还没配置 brain';

  @override
  String get noBrainBody => '填好 Base URL 和 brain_id 才能开始对话。';

  @override
  String get goToSettings => '去配置';

  @override
  String get mute => '闭麦';

  @override
  String get muted => '闭麦中';

  @override
  String get bargeIn => '打断';

  @override
  String get debugTitle => '调试面板';

  @override
  String get conversationActive => '对话中';

  @override
  String get notStarted => '未开始';

  @override
  String get aiSpeaking => 'AI 说话中';

  @override
  String get aiSilent => 'AI 静默';

  @override
  String voiceprintScore(String score) {
    return '声纹 $score';
  }

  @override
  String get voiceprintPending => '声纹待测';

  @override
  String get voiceprintOff => '声纹比对关';

  @override
  String targetProbability(String probability) {
    return '本人概率 $probability';
  }

  @override
  String get speakerRecognitionOff => '说话人识别关';

  @override
  String get droppedMicFrames => '丢弃采集帧';

  @override
  String get playbackBacklog => '播放积压帧';

  @override
  String get uploadQueue => '上传队列';

  @override
  String get droppedUtterances => '丢弃句子';

  @override
  String get polling => '轮询中';

  @override
  String get stopped => '停止';

  @override
  String get upstreamCodec => '上行编码';

  @override
  String get segmentBuffer => '断句缓冲';

  @override
  String get segmentDropped => '断句丢弃';

  @override
  String get forcedCuts => '强制切句';

  @override
  String get feedCost => 'feed 耗时';

  @override
  String get filteredNonTarget => '滤掉非本人';

  @override
  String get startConversation => '开始对话';

  @override
  String get endConversation => '结束对话';

  @override
  String get droppedFramesWarning =>
      '采集帧被丢弃说明主线程没跟上。这是有意的背压策略（宁可丢帧也不让延迟累积），但持续增长要查。';

  @override
  String get realtimeLevel => '实时电平';

  @override
  String get levelExplanation =>
      '播测试音时麦克风条应接近静默；你一开口应明显抬升。这就是 AEC 的判据。（不做自动打断之后这里没有阈值线了，纯看电平。）';

  @override
  String get stopTestTone => '停止测试音';

  @override
  String get playTestTone => '播放测试音（AEC 自测）';

  @override
  String get sendTestUtterance => '发送测试语音（验证上行）';

  @override
  String get testToneExplanation =>
      '测试音不经过 brain，循环播放，所以 brain 没起也能用 —— 这是唯一一个永远可用的 AEC 验证入口。「发送测试语音」则把一段测试音当成你说的话走完整条上行链路，不需要麦克风就能验证编码、multipart、鉴权和文本回流。';

  @override
  String get clearAiVoice => '清空 AI 语音';

  @override
  String get clearPlaybackExplanation => '协议上不做自动打断 —— 收到就播。要让它闭嘴得手动触发：';

  @override
  String get clearPlaybackQueue => '清空播放队列';

  @override
  String get clearPlaybackDetail =>
      '• 通知栏「停止说话」按钮 —— 后台、锁屏都能用\n• 音量减键 —— 只在 App 前台且正在播 AI 语音时拦截，其余时候放行，不影响正常调音量。拦不拦由设置页的「音量减键清空队列」决定，关了它就纯调音量\n\n两者都只清音频。文本不受影响，照样进消息流。';

  @override
  String get aecPanel => 'AEC 实测面板';

  @override
  String get aecPanelActiveSubtitle => '改动会立即重启音频链路';

  @override
  String get aecPanelSubtitle => '一次只动一个变量';

  @override
  String get captureSource => '采集源';

  @override
  String get playbackUsage => '播放属性';

  @override
  String get playbackUsageHint => 'media 会让 AEC 拿不到参考信号';

  @override
  String get performanceMode => '性能模式';

  @override
  String get performanceModeHint => 'lowLatency 下 effects 可能失效';

  @override
  String get manualAec => '手动 AEC';

  @override
  String get manualAecHint =>
      '叠加 AcousticEchoCanceler，与 voiceCommunication 是两条路径';

  @override
  String get speakerphone => '扬声器';

  @override
  String get speakerphoneHint => 'setSpeakerphoneOn —— 可热切，不必重启';

  @override
  String get eventLog => '事件日志';

  @override
  String get noEvents => '还没有事件。回主界面点一下按钮，说话之后这里会有东西。';

  @override
  String get noEnabledProfiles => '没有启用的档案';

  @override
  String get noEnabledProfilesBody => '去配置里新建一个，或者把原来那个打开';

  @override
  String switchToProfile(String name) {
    return '切到$name';
  }

  @override
  String get previousProfile => '上一个档案';

  @override
  String get nextProfile => '下一个档案';

  @override
  String get micAfterAec => '麦克风 (AEC 后)';

  @override
  String get playbackOutput => '播放输出';

  @override
  String get silent => '静默';

  @override
  String get orbStart => '开始对话';

  @override
  String get orbStarting => '正在启动';

  @override
  String get orbEnd => '结束对话';

  @override
  String get jumpToBottom => '回到底部';
}

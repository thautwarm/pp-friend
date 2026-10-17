import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ja.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ja'),
    Locale('zh'),
  ];

  /// No description provided for @save.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get save;

  /// No description provided for @saved.
  ///
  /// In zh, this message translates to:
  /// **'已保存'**
  String get saved;

  /// No description provided for @delete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get delete;

  /// No description provided for @clear.
  ///
  /// In zh, this message translates to:
  /// **'清空'**
  String get clear;

  /// No description provided for @cancel.
  ///
  /// In zh, this message translates to:
  /// **'算了'**
  String get cancel;

  /// No description provided for @settingsTitle.
  ///
  /// In zh, this message translates to:
  /// **'配置'**
  String get settingsTitle;

  /// No description provided for @tabProfiles.
  ///
  /// In zh, this message translates to:
  /// **'档案'**
  String get tabProfiles;

  /// No description provided for @tabGeneral.
  ///
  /// In zh, this message translates to:
  /// **'通用'**
  String get tabGeneral;

  /// No description provided for @languageSection.
  ///
  /// In zh, this message translates to:
  /// **'语言'**
  String get languageSection;

  /// No description provided for @languageFollowSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get languageFollowSystem;

  /// No description provided for @languageChinese.
  ///
  /// In zh, this message translates to:
  /// **'中文'**
  String get languageChinese;

  /// No description provided for @languageEnglish.
  ///
  /// In zh, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languageJapanese.
  ///
  /// In zh, this message translates to:
  /// **'日本語'**
  String get languageJapanese;

  /// No description provided for @languageChanged.
  ///
  /// In zh, this message translates to:
  /// **'界面语言已切换'**
  String get languageChanged;

  /// No description provided for @saveFailed.
  ///
  /// In zh, this message translates to:
  /// **'没保存成功：{error}'**
  String saveFailed(String error);

  /// No description provided for @profileGoneUnsaved.
  ///
  /// In zh, this message translates to:
  /// **'这个档案已经不在了，改动没有保存'**
  String get profileGoneUnsaved;

  /// No description provided for @noAppToOpenPage.
  ///
  /// In zh, this message translates to:
  /// **'没找到能打开网页的应用'**
  String get noAppToOpenPage;

  /// No description provided for @openPageFailed.
  ///
  /// In zh, this message translates to:
  /// **'打开网页失败：{error}'**
  String openPageFailed(String error);

  /// No description provided for @voiceprintImported.
  ///
  /// In zh, this message translates to:
  /// **'声纹已导入'**
  String get voiceprintImported;

  /// No description provided for @notVoiceprint.
  ///
  /// In zh, this message translates to:
  /// **'这个文件不是声纹：{message}'**
  String notVoiceprint(String message);

  /// No description provided for @importFailed.
  ///
  /// In zh, this message translates to:
  /// **'导入失败：{error}'**
  String importFailed(String error);

  /// No description provided for @voiceprintRemoved.
  ///
  /// In zh, this message translates to:
  /// **'声纹已删除'**
  String get voiceprintRemoved;

  /// No description provided for @saveFailedBeforeSwitch.
  ///
  /// In zh, this message translates to:
  /// **'没保存成功，先别切：{error}'**
  String saveFailedBeforeSwitch(String error);

  /// No description provided for @saveFailedBeforeAdd.
  ///
  /// In zh, this message translates to:
  /// **'没保存成功，先别新建：{error}'**
  String saveFailedBeforeAdd(String error);

  /// No description provided for @newProfile.
  ///
  /// In zh, this message translates to:
  /// **'新档案'**
  String get newProfile;

  /// No description provided for @newProfileTooltip.
  ///
  /// In zh, this message translates to:
  /// **'新建档案'**
  String get newProfileTooltip;

  /// No description provided for @profileDisabled.
  ///
  /// In zh, this message translates to:
  /// **'已关闭'**
  String get profileDisabled;

  /// No description provided for @localSegmentation.
  ///
  /// In zh, this message translates to:
  /// **'本地断句'**
  String get localSegmentation;

  /// No description provided for @localSegmentationBody.
  ///
  /// In zh, this message translates to:
  /// **'在手机上用 Silero VAD 切句，只上传成句的片段。\n这些参数是全局的，切换档案不会重新加载模型。'**
  String get localSegmentationBody;

  /// No description provided for @vadMinSilenceMsLabel.
  ///
  /// In zh, this message translates to:
  /// **'静音判定 (ms)'**
  String get vadMinSilenceMsLabel;

  /// No description provided for @vadMinSilenceMsHint.
  ///
  /// In zh, this message translates to:
  /// **'700 —— 最重要的一项。调小更跟手，太小会切断句内停顿'**
  String get vadMinSilenceMsHint;

  /// No description provided for @vadThresholdLabel.
  ///
  /// In zh, this message translates to:
  /// **'语音概率阈值'**
  String get vadThresholdLabel;

  /// No description provided for @vadThresholdHint.
  ///
  /// In zh, this message translates to:
  /// **'0.5 —— 0~1。调低更容易触发，调高更保守'**
  String get vadThresholdHint;

  /// No description provided for @vadSpeechPadMsLabel.
  ///
  /// In zh, this message translates to:
  /// **'前后外扩 (ms)'**
  String get vadSpeechPadMsLabel;

  /// No description provided for @vadSpeechPadMsHint.
  ///
  /// In zh, this message translates to:
  /// **'200 —— 段两端各留一点，不留会切掉第一个字'**
  String get vadSpeechPadMsHint;

  /// No description provided for @vadMinSpeechMsLabel.
  ///
  /// In zh, this message translates to:
  /// **'最短有效语音 (ms)'**
  String get vadMinSpeechMsLabel;

  /// No description provided for @vadMinSpeechMsHint.
  ///
  /// In zh, this message translates to:
  /// **'300 —— 比这短直接丢，咳嗽一声不触发上传'**
  String get vadMinSpeechMsHint;

  /// No description provided for @vadMaxSpeechSLabel.
  ///
  /// In zh, this message translates to:
  /// **'最长一句 (s)'**
  String get vadMaxSpeechSLabel;

  /// No description provided for @vadMaxSpeechSHint.
  ///
  /// In zh, this message translates to:
  /// **'60 —— 说超过就强制切开，避免一直说不完'**
  String get vadMaxSpeechSHint;

  /// No description provided for @speakerRecognition.
  ///
  /// In zh, this message translates to:
  /// **'说话人识别'**
  String get speakerRecognition;

  /// No description provided for @onlyMyVoice.
  ///
  /// In zh, this message translates to:
  /// **'只识别本人的声音'**
  String get onlyMyVoice;

  /// No description provided for @voiceprintImportedStatus.
  ///
  /// In zh, this message translates to:
  /// **'已导入声纹'**
  String get voiceprintImportedStatus;

  /// No description provided for @voiceprintNeeded.
  ///
  /// In zh, this message translates to:
  /// **'需要先导入声纹'**
  String get voiceprintNeeded;

  /// No description provided for @openVoiceprintPage.
  ///
  /// In zh, this message translates to:
  /// **'本地创建你的声纹并下载'**
  String get openVoiceprintPage;

  /// No description provided for @voiceprintOptionalHint.
  ///
  /// In zh, this message translates to:
  /// **'可选。声纹用来过滤别人的声音和杂音，只把你自己的话发给 agent。'**
  String get voiceprintOptionalHint;

  /// No description provided for @reimportVoiceprint.
  ///
  /// In zh, this message translates to:
  /// **'重新导入声纹'**
  String get reimportVoiceprint;

  /// No description provided for @importVoiceprint.
  ///
  /// In zh, this message translates to:
  /// **'导入声纹'**
  String get importVoiceprint;

  /// No description provided for @deleteVoiceprint.
  ///
  /// In zh, this message translates to:
  /// **'删除声纹'**
  String get deleteVoiceprint;

  /// No description provided for @similarityThreshold.
  ///
  /// In zh, this message translates to:
  /// **'相似度阈值'**
  String get similarityThreshold;

  /// No description provided for @volumeKeys.
  ///
  /// In zh, this message translates to:
  /// **'音量键'**
  String get volumeKeys;

  /// No description provided for @volumeKeyClearsQueue.
  ///
  /// In zh, this message translates to:
  /// **'音量减键清空队列'**
  String get volumeKeyClearsQueue;

  /// No description provided for @volumeKeySubtitle.
  ///
  /// In zh, this message translates to:
  /// **'开着：AI 说话时按音量减让它闭嘴（仅前台）。\n后台和锁屏用通知栏的「停止说话」。'**
  String get volumeKeySubtitle;

  /// No description provided for @settingsNotice.
  ///
  /// In zh, this message translates to:
  /// **'识别和合成在 brain 那边，手机只负责采集、切句、上传、播放。\n本机保存的是展示用的历史，不是对话上下文；删掉它不影响 brain 那边的记忆。'**
  String get settingsNotice;

  /// No description provided for @profileAppearance.
  ///
  /// In zh, this message translates to:
  /// **'这个档案长什么样'**
  String get profileAppearance;

  /// No description provided for @nameLabel.
  ///
  /// In zh, this message translates to:
  /// **'名字'**
  String get nameLabel;

  /// No description provided for @nameHint.
  ///
  /// In zh, this message translates to:
  /// **'例如 员工3 —— 留空就用 brain_id'**
  String get nameHint;

  /// No description provided for @themeColor.
  ///
  /// In zh, this message translates to:
  /// **'主题色'**
  String get themeColor;

  /// No description provided for @colorIndigo.
  ///
  /// In zh, this message translates to:
  /// **'靛蓝'**
  String get colorIndigo;

  /// No description provided for @colorInkGreen.
  ///
  /// In zh, this message translates to:
  /// **'墨绿'**
  String get colorInkGreen;

  /// No description provided for @colorTerracotta.
  ///
  /// In zh, this message translates to:
  /// **'陶土'**
  String get colorTerracotta;

  /// No description provided for @colorPurple.
  ///
  /// In zh, this message translates to:
  /// **'紫'**
  String get colorPurple;

  /// No description provided for @colorLakeBlue.
  ///
  /// In zh, this message translates to:
  /// **'湖蓝'**
  String get colorLakeBlue;

  /// No description provided for @colorOchre.
  ///
  /// In zh, this message translates to:
  /// **'赭黄'**
  String get colorOchre;

  /// No description provided for @colorRose.
  ///
  /// In zh, this message translates to:
  /// **'玫红'**
  String get colorRose;

  /// No description provided for @colorSlate.
  ///
  /// In zh, this message translates to:
  /// **'石板'**
  String get colorSlate;

  /// No description provided for @baseUrlLabel.
  ///
  /// In zh, this message translates to:
  /// **'Base URL'**
  String get baseUrlLabel;

  /// No description provided for @baseUrlHint.
  ///
  /// In zh, this message translates to:
  /// **'http://192.168.0.100:8000'**
  String get baseUrlHint;

  /// No description provided for @brainIdLabel.
  ///
  /// In zh, this message translates to:
  /// **'brain_id'**
  String get brainIdLabel;

  /// No description provided for @brainIdHint.
  ///
  /// In zh, this message translates to:
  /// **'例如 员工3 —— 像名字一样有语义'**
  String get brainIdHint;

  /// No description provided for @tokenLabel.
  ///
  /// In zh, this message translates to:
  /// **'Bearer token'**
  String get tokenLabel;

  /// No description provided for @tokenHint.
  ///
  /// In zh, this message translates to:
  /// **'留空表示该部署没启用鉴权，不会发这个头'**
  String get tokenHint;

  /// No description provided for @statusSection.
  ///
  /// In zh, this message translates to:
  /// **'状态'**
  String get statusSection;

  /// No description provided for @enabled.
  ///
  /// In zh, this message translates to:
  /// **'启用'**
  String get enabled;

  /// No description provided for @enabledSubtitleOn.
  ///
  /// In zh, this message translates to:
  /// **'会一直收它的消息（没聚焦时只记文字，不出声）'**
  String get enabledSubtitleOn;

  /// No description provided for @enabledSubtitleOff.
  ///
  /// In zh, this message translates to:
  /// **'不连它。历史仍然留在盘上，随时可以再打开'**
  String get enabledSubtitleOff;

  /// No description provided for @focusedDisabledWarning.
  ///
  /// In zh, this message translates to:
  /// **'它现在是主界面上选中的那个。保存之后会自动切到别的开着的档案。'**
  String get focusedDisabledWarning;

  /// No description provided for @switchToThisProfile.
  ///
  /// In zh, this message translates to:
  /// **'切到这个档案'**
  String get switchToThisProfile;

  /// No description provided for @switchBySwipeHint.
  ///
  /// In zh, this message translates to:
  /// **'主界面上左右滑说话按钮也能切'**
  String get switchBySwipeHint;

  /// No description provided for @historySection.
  ///
  /// In zh, this message translates to:
  /// **'历史'**
  String get historySection;

  /// No description provided for @historyUsage.
  ///
  /// In zh, this message translates to:
  /// **'盘上占 {size}。\n永久保留，没有自动清理 —— 攒到几百 MB 就自己来这里清。'**
  String historyUsage(String size);

  /// No description provided for @clearHistoryTitle.
  ///
  /// In zh, this message translates to:
  /// **'清空这个档案的历史？'**
  String get clearHistoryTitle;

  /// No description provided for @clearHistoryBody.
  ///
  /// In zh, this message translates to:
  /// **'主界面上这个档案的消息会全部消失，而且找不回来。\n\nbrain 那边的记忆不受影响 —— 本地存的是展示用的历史，对话上下文一直挂在 brain_id 上。'**
  String get clearHistoryBody;

  /// No description provided for @historyCleared.
  ///
  /// In zh, this message translates to:
  /// **'已清空'**
  String get historyCleared;

  /// No description provided for @deleteProfileTitle.
  ///
  /// In zh, this message translates to:
  /// **'删掉「{name}」？'**
  String deleteProfileTitle(String name);

  /// No description provided for @deleteProfileBody.
  ///
  /// In zh, this message translates to:
  /// **'这个档案的 brain 配置和主题色都会没。\n\n盘上的历史不跟着删 —— 万一删错了，那一份还在。'**
  String get deleteProfileBody;

  /// No description provided for @deleteProfileAction.
  ///
  /// In zh, this message translates to:
  /// **'删除这个档案'**
  String get deleteProfileAction;

  /// No description provided for @chooseAvatar.
  ///
  /// In zh, this message translates to:
  /// **'选头像'**
  String get chooseAvatar;

  /// No description provided for @changeAvatar.
  ///
  /// In zh, this message translates to:
  /// **'换头像'**
  String get changeAvatar;

  /// No description provided for @removeAvatar.
  ///
  /// In zh, this message translates to:
  /// **'去掉'**
  String get removeAvatar;

  /// No description provided for @avatarPickFailed.
  ///
  /// In zh, this message translates to:
  /// **'打不开相册：{error}'**
  String avatarPickFailed(String error);

  /// No description provided for @debugPanelTooltip.
  ///
  /// In zh, this message translates to:
  /// **'调试面板'**
  String get debugPanelTooltip;

  /// No description provided for @brainConfigTooltip.
  ///
  /// In zh, this message translates to:
  /// **'brain 配置'**
  String get brainConfigTooltip;

  /// No description provided for @starting.
  ///
  /// In zh, this message translates to:
  /// **'请稍候…'**
  String get starting;

  /// No description provided for @tapToStart.
  ///
  /// In zh, this message translates to:
  /// **'点击开始对话'**
  String get tapToStart;

  /// No description provided for @segmenterUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'⚠️ 断句引擎不可用'**
  String get segmenterUnavailable;

  /// No description provided for @tokenInvalid.
  ///
  /// In zh, this message translates to:
  /// **'⚠️ token 无效'**
  String get tokenInvalid;

  /// No description provided for @brainUnresponsive.
  ///
  /// In zh, this message translates to:
  /// **'⚠️ brain 无响应'**
  String get brainUnresponsive;

  /// No description provided for @mutedUploadingOff.
  ///
  /// In zh, this message translates to:
  /// **'闭麦中 · 说的话不会上传'**
  String get mutedUploadingOff;

  /// No description provided for @speakingCanClear.
  ///
  /// In zh, this message translates to:
  /// **'正在说话 · 音量减可以清空'**
  String get speakingCanClear;

  /// No description provided for @speaking.
  ///
  /// In zh, this message translates to:
  /// **'正在说话'**
  String get speaking;

  /// No description provided for @listening.
  ///
  /// In zh, this message translates to:
  /// **'正在听你说'**
  String get listening;

  /// No description provided for @queuedUtterances.
  ///
  /// In zh, this message translates to:
  /// **'还有 {count} 句在上传'**
  String queuedUtterances(int count);

  /// No description provided for @idleHint.
  ///
  /// In zh, this message translates to:
  /// **'直接说话就行'**
  String get idleHint;

  /// No description provided for @emptyHint.
  ///
  /// In zh, this message translates to:
  /// **'开始之后，你和它说的话都会出现在这里'**
  String get emptyHint;

  /// No description provided for @segmenterLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'本地断句引擎加载失败'**
  String get segmenterLoadFailed;

  /// No description provided for @segmenterLoadFailedBody.
  ///
  /// In zh, this message translates to:
  /// **'多半是 Rust 动态库（librust_lib_pp_friend.so）没打进 APK，或 ABI 对不上。重跑 tools/build_rust_android.sh 再装一次。'**
  String get segmenterLoadFailedBody;

  /// No description provided for @noBrain.
  ///
  /// In zh, this message translates to:
  /// **'还没配置 brain'**
  String get noBrain;

  /// No description provided for @noBrainBody.
  ///
  /// In zh, this message translates to:
  /// **'填好 Base URL 和 brain_id 才能开始对话。'**
  String get noBrainBody;

  /// No description provided for @goToSettings.
  ///
  /// In zh, this message translates to:
  /// **'去配置'**
  String get goToSettings;

  /// No description provided for @mute.
  ///
  /// In zh, this message translates to:
  /// **'闭麦'**
  String get mute;

  /// No description provided for @muted.
  ///
  /// In zh, this message translates to:
  /// **'闭麦中'**
  String get muted;

  /// No description provided for @bargeIn.
  ///
  /// In zh, this message translates to:
  /// **'打断'**
  String get bargeIn;

  /// No description provided for @debugTitle.
  ///
  /// In zh, this message translates to:
  /// **'调试面板'**
  String get debugTitle;

  /// No description provided for @conversationActive.
  ///
  /// In zh, this message translates to:
  /// **'对话中'**
  String get conversationActive;

  /// No description provided for @notStarted.
  ///
  /// In zh, this message translates to:
  /// **'未开始'**
  String get notStarted;

  /// No description provided for @aiSpeaking.
  ///
  /// In zh, this message translates to:
  /// **'AI 说话中'**
  String get aiSpeaking;

  /// No description provided for @aiSilent.
  ///
  /// In zh, this message translates to:
  /// **'AI 静默'**
  String get aiSilent;

  /// No description provided for @voiceprintScore.
  ///
  /// In zh, this message translates to:
  /// **'声纹 {score}'**
  String voiceprintScore(String score);

  /// No description provided for @voiceprintPending.
  ///
  /// In zh, this message translates to:
  /// **'声纹待测'**
  String get voiceprintPending;

  /// No description provided for @voiceprintOff.
  ///
  /// In zh, this message translates to:
  /// **'声纹比对关'**
  String get voiceprintOff;

  /// No description provided for @targetProbability.
  ///
  /// In zh, this message translates to:
  /// **'本人概率 {probability}'**
  String targetProbability(String probability);

  /// No description provided for @speakerRecognitionOff.
  ///
  /// In zh, this message translates to:
  /// **'说话人识别关'**
  String get speakerRecognitionOff;

  /// No description provided for @droppedMicFrames.
  ///
  /// In zh, this message translates to:
  /// **'丢弃采集帧'**
  String get droppedMicFrames;

  /// No description provided for @playbackBacklog.
  ///
  /// In zh, this message translates to:
  /// **'播放积压帧'**
  String get playbackBacklog;

  /// No description provided for @uploadQueue.
  ///
  /// In zh, this message translates to:
  /// **'上传队列'**
  String get uploadQueue;

  /// No description provided for @droppedUtterances.
  ///
  /// In zh, this message translates to:
  /// **'丢弃句子'**
  String get droppedUtterances;

  /// No description provided for @polling.
  ///
  /// In zh, this message translates to:
  /// **'轮询中'**
  String get polling;

  /// No description provided for @stopped.
  ///
  /// In zh, this message translates to:
  /// **'停止'**
  String get stopped;

  /// No description provided for @upstreamCodec.
  ///
  /// In zh, this message translates to:
  /// **'上行编码'**
  String get upstreamCodec;

  /// No description provided for @segmentBuffer.
  ///
  /// In zh, this message translates to:
  /// **'断句缓冲'**
  String get segmentBuffer;

  /// No description provided for @segmentDropped.
  ///
  /// In zh, this message translates to:
  /// **'断句丢弃'**
  String get segmentDropped;

  /// No description provided for @forcedCuts.
  ///
  /// In zh, this message translates to:
  /// **'强制切句'**
  String get forcedCuts;

  /// No description provided for @feedCost.
  ///
  /// In zh, this message translates to:
  /// **'feed 耗时'**
  String get feedCost;

  /// No description provided for @filteredNonTarget.
  ///
  /// In zh, this message translates to:
  /// **'滤掉非本人'**
  String get filteredNonTarget;

  /// No description provided for @startConversation.
  ///
  /// In zh, this message translates to:
  /// **'开始对话'**
  String get startConversation;

  /// No description provided for @endConversation.
  ///
  /// In zh, this message translates to:
  /// **'结束对话'**
  String get endConversation;

  /// No description provided for @droppedFramesWarning.
  ///
  /// In zh, this message translates to:
  /// **'采集帧被丢弃说明主线程没跟上。这是有意的背压策略（宁可丢帧也不让延迟累积），但持续增长要查。'**
  String get droppedFramesWarning;

  /// No description provided for @realtimeLevel.
  ///
  /// In zh, this message translates to:
  /// **'实时电平'**
  String get realtimeLevel;

  /// No description provided for @levelExplanation.
  ///
  /// In zh, this message translates to:
  /// **'播测试音时麦克风条应接近静默；你一开口应明显抬升。这就是 AEC 的判据。（不做自动打断之后这里没有阈值线了，纯看电平。）'**
  String get levelExplanation;

  /// No description provided for @stopTestTone.
  ///
  /// In zh, this message translates to:
  /// **'停止测试音'**
  String get stopTestTone;

  /// No description provided for @playTestTone.
  ///
  /// In zh, this message translates to:
  /// **'播放测试音（AEC 自测）'**
  String get playTestTone;

  /// No description provided for @sendTestUtterance.
  ///
  /// In zh, this message translates to:
  /// **'发送测试语音（验证上行）'**
  String get sendTestUtterance;

  /// No description provided for @testToneExplanation.
  ///
  /// In zh, this message translates to:
  /// **'测试音不经过 brain，循环播放，所以 brain 没起也能用 —— 这是唯一一个永远可用的 AEC 验证入口。「发送测试语音」则把一段测试音当成你说的话走完整条上行链路，不需要麦克风就能验证编码、multipart、鉴权和文本回流。'**
  String get testToneExplanation;

  /// No description provided for @clearAiVoice.
  ///
  /// In zh, this message translates to:
  /// **'清空 AI 语音'**
  String get clearAiVoice;

  /// No description provided for @clearPlaybackExplanation.
  ///
  /// In zh, this message translates to:
  /// **'协议上不做自动打断 —— 收到就播。要让它闭嘴得手动触发：'**
  String get clearPlaybackExplanation;

  /// No description provided for @clearPlaybackQueue.
  ///
  /// In zh, this message translates to:
  /// **'清空播放队列'**
  String get clearPlaybackQueue;

  /// No description provided for @clearPlaybackDetail.
  ///
  /// In zh, this message translates to:
  /// **'• 通知栏「停止说话」按钮 —— 后台、锁屏都能用\n• 音量减键 —— 只在 App 前台且正在播 AI 语音时拦截，其余时候放行，不影响正常调音量。拦不拦由设置页的「音量减键清空队列」决定，关了它就纯调音量\n\n两者都只清音频。文本不受影响，照样进消息流。'**
  String get clearPlaybackDetail;

  /// No description provided for @aecPanel.
  ///
  /// In zh, this message translates to:
  /// **'AEC 实测面板'**
  String get aecPanel;

  /// No description provided for @aecPanelActiveSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'改动会立即重启音频链路'**
  String get aecPanelActiveSubtitle;

  /// No description provided for @aecPanelSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'一次只动一个变量'**
  String get aecPanelSubtitle;

  /// No description provided for @captureSource.
  ///
  /// In zh, this message translates to:
  /// **'采集源'**
  String get captureSource;

  /// No description provided for @playbackUsage.
  ///
  /// In zh, this message translates to:
  /// **'播放属性'**
  String get playbackUsage;

  /// No description provided for @playbackUsageHint.
  ///
  /// In zh, this message translates to:
  /// **'media 会让 AEC 拿不到参考信号'**
  String get playbackUsageHint;

  /// No description provided for @performanceMode.
  ///
  /// In zh, this message translates to:
  /// **'性能模式'**
  String get performanceMode;

  /// No description provided for @performanceModeHint.
  ///
  /// In zh, this message translates to:
  /// **'lowLatency 下 effects 可能失效'**
  String get performanceModeHint;

  /// No description provided for @manualAec.
  ///
  /// In zh, this message translates to:
  /// **'手动 AEC'**
  String get manualAec;

  /// No description provided for @manualAecHint.
  ///
  /// In zh, this message translates to:
  /// **'叠加 AcousticEchoCanceler，与 voiceCommunication 是两条路径'**
  String get manualAecHint;

  /// No description provided for @speakerphone.
  ///
  /// In zh, this message translates to:
  /// **'扬声器'**
  String get speakerphone;

  /// No description provided for @speakerphoneHint.
  ///
  /// In zh, this message translates to:
  /// **'setSpeakerphoneOn —— 可热切，不必重启'**
  String get speakerphoneHint;

  /// No description provided for @eventLog.
  ///
  /// In zh, this message translates to:
  /// **'事件日志'**
  String get eventLog;

  /// No description provided for @noEvents.
  ///
  /// In zh, this message translates to:
  /// **'还没有事件。回主界面点一下按钮，说话之后这里会有东西。'**
  String get noEvents;

  /// No description provided for @noEnabledProfiles.
  ///
  /// In zh, this message translates to:
  /// **'没有启用的档案'**
  String get noEnabledProfiles;

  /// No description provided for @noEnabledProfilesBody.
  ///
  /// In zh, this message translates to:
  /// **'去配置里新建一个，或者把原来那个打开'**
  String get noEnabledProfilesBody;

  /// No description provided for @switchToProfile.
  ///
  /// In zh, this message translates to:
  /// **'切到{name}'**
  String switchToProfile(String name);

  /// No description provided for @previousProfile.
  ///
  /// In zh, this message translates to:
  /// **'上一个档案'**
  String get previousProfile;

  /// No description provided for @nextProfile.
  ///
  /// In zh, this message translates to:
  /// **'下一个档案'**
  String get nextProfile;

  /// No description provided for @micAfterAec.
  ///
  /// In zh, this message translates to:
  /// **'麦克风 (AEC 后)'**
  String get micAfterAec;

  /// No description provided for @playbackOutput.
  ///
  /// In zh, this message translates to:
  /// **'播放输出'**
  String get playbackOutput;

  /// No description provided for @silent.
  ///
  /// In zh, this message translates to:
  /// **'静默'**
  String get silent;

  /// No description provided for @orbStart.
  ///
  /// In zh, this message translates to:
  /// **'开始对话'**
  String get orbStart;

  /// No description provided for @orbStarting.
  ///
  /// In zh, this message translates to:
  /// **'正在启动'**
  String get orbStarting;

  /// No description provided for @orbEnd.
  ///
  /// In zh, this message translates to:
  /// **'结束对话'**
  String get orbEnd;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ja', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ja':
      return AppLocalizationsJa();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}

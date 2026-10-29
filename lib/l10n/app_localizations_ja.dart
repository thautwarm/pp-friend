// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get save => '保存';

  @override
  String get saved => '保存しました';

  @override
  String get delete => '削除';

  @override
  String get clear => 'クリア';

  @override
  String get cancel => 'キャンセル';

  @override
  String get settingsTitle => '設定';

  @override
  String get tabProfiles => 'プロフィール';

  @override
  String get tabGeneral => '一般';

  @override
  String get languageSection => '言語';

  @override
  String get languageFollowSystem => 'システムに従う';

  @override
  String get languageChinese => '中文';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageJapanese => '日本語';

  @override
  String get languageChanged => '表示言語を切り替えました';

  @override
  String saveFailed(String error) {
    return '保存できませんでした：$error';
  }

  @override
  String get profileGoneUnsaved => 'このプロフィールはもう存在しません。変更は保存されていません';

  @override
  String get noAppToOpenPage => 'ページを開けるアプリが見つかりません';

  @override
  String openPageFailed(String error) {
    return 'ページを開けませんでした：$error';
  }

  @override
  String get voiceprintImported => '声紋をインポートしました';

  @override
  String notVoiceprint(String message) {
    return 'このファイルは声紋ではありません：$message';
  }

  @override
  String importFailed(String error) {
    return 'インポートに失敗しました：$error';
  }

  @override
  String get voiceprintRemoved => '声紋を削除しました';

  @override
  String saveFailedBeforeSwitch(String error) {
    return '保存できませんでした。切り替える前に確認してください：$error';
  }

  @override
  String saveFailedBeforeAdd(String error) {
    return '保存できませんでした。新規作成する前に確認してください：$error';
  }

  @override
  String get newProfile => '新しいプロフィール';

  @override
  String get newProfileTooltip => 'プロフィールを新規作成';

  @override
  String get profileDisabled => 'オフ';

  @override
  String get localSegmentation => '端末上の区間検出';

  @override
  String get localSegmentationBody =>
      'スマホ上で Silero VAD を使って文を区切り、完成した区間だけを送信します。\nこれらの設定は全体共通です。プロフィールを切り替えてもモデルは再読み込みされません。';

  @override
  String get vadMinSilenceMsLabel => '無音判定 (ms)';

  @override
  String get vadMinSilenceMsHint =>
      '700 ― 最も重要な項目。小さくすると反応が速くなるが、小さすぎると文中の間で切れる';

  @override
  String get vadThresholdLabel => '音声確率のしきい値';

  @override
  String get vadThresholdHint => '0.5 ― 0〜1。低いほど反応しやすく、高いほど保守的';

  @override
  String get vadSpeechPadMsLabel => '前後の余白 (ms)';

  @override
  String get vadSpeechPadMsHint => '200 ― 区間の両端に少し余白を残す。0 だと最初の音が切れる';

  @override
  String get vadMinSpeechMsLabel => '最短有効音声 (ms)';

  @override
  String get vadMinSpeechMsHint => '300 ― これより短い区間は捨てる。咳ではアップロードしない';

  @override
  String get vadMaxSpeechSLabel => '最長の一文 (s)';

  @override
  String get vadMaxSpeechSHint => '60 ― これを超えると強制的に区切る';

  @override
  String get speakerRecognition => '話者認識';

  @override
  String get onlyMyVoice => '本人の声だけを認識';

  @override
  String get voiceprintImportedStatus => '声紋インポート済み';

  @override
  String get voiceprintNeeded => '先に声紋をインポートしてください';

  @override
  String get openVoiceprintPage => '声紋をローカルで作成してダウンロード';

  @override
  String get voiceprintOptionalHint =>
      '任意です。声紋は他の人の声や雑音を除き、あなた自身の発話だけをエージェントに送るために使います。';

  @override
  String get reimportVoiceprint => '声紋を再インポート';

  @override
  String get importVoiceprint => '声紋をインポート';

  @override
  String get deleteVoiceprint => '声紋を削除';

  @override
  String get similarityThreshold => '類似度のしきい値';

  @override
  String get volumeKeys => '音量キー';

  @override
  String get volumeKeyClearsQueue => '音量ダウンキーでキューをクリア';

  @override
  String get volumeKeySubtitle =>
      'オン：AI が話しているときに音量ダウンで停止（前面のみ）。\nバックグラウンドとロック画面では通知の「話すのを停止」を使う。';

  @override
  String get settingsNotice =>
      '認識と合成は brain 側で行われ、スマホは収録・区間検出・送信・再生だけを担当します。\n端末に保存されるのは表示用の履歴で、会話のコンテキストではありません。削除しても brain 側の記憶には影響しません。';

  @override
  String get profileAppearance => 'このプロフィールの見た目';

  @override
  String get nameLabel => '名前';

  @override
  String get nameHint => '例：社員3 ― 空欄なら brain_id を使う';

  @override
  String get themeColor => 'テーマカラー';

  @override
  String get colorIndigo => 'インディゴ';

  @override
  String get colorInkGreen => '深緑';

  @override
  String get colorTerracotta => 'テラコッタ';

  @override
  String get colorPurple => '紫';

  @override
  String get colorLakeBlue => 'レイクブルー';

  @override
  String get colorOchre => '黄土';

  @override
  String get colorRose => 'ローズ';

  @override
  String get colorSlate => 'スレート';

  @override
  String get baseUrlLabel => 'Base URL';

  @override
  String get baseUrlHint => 'http://192.168.0.100:8000';

  @override
  String get brainIdLabel => 'brain_id';

  @override
  String get brainIdHint => '例：社員3 ― 名前のように意味を持たせる';

  @override
  String get tokenLabel => 'Bearer token';

  @override
  String get tokenHint => '空欄ならこのデプロイは認証なし。このヘッダーは送信されない';

  @override
  String get statusSection => '状態';

  @override
  String get enabled => '有効';

  @override
  String get enabledSubtitleOn => '常にメッセージを受信する（フォーカス外ではテキストのみ記録し、音は出さない）';

  @override
  String get enabledSubtitleOff => '接続しない。履歴はディスクに残り、いつでも再度開ける';

  @override
  String get focusedDisabledWarning =>
      '現在メイン画面で選択中のプロフィールです。保存すると他の有効なプロフィールに切り替わります。';

  @override
  String get switchToThisProfile => 'このプロフィールに切り替える';

  @override
  String get switchBySwipeHint => 'メイン画面で話すボタンを左右にスワイプしても切り替えられる';

  @override
  String get historySection => '履歴';

  @override
  String historyUsage(String size) {
    return 'ディスク使用量 $size。\n永久保存で自動削除はありません。数百 MB になったらここで消してください。';
  }

  @override
  String get clearHistoryTitle => 'このプロフィールの履歴を削除しますか？';

  @override
  String get clearHistoryBody =>
      'メイン画面のこのプロフィールのメッセージがすべて消え、元に戻せません。\n\nbrain 側の記憶には影響しません。ローカルに保存されるのは表示用の履歴で、会話のコンテキストは brain_id にあります。';

  @override
  String get historyCleared => '削除しました';

  @override
  String deleteProfileTitle(String name) {
    return '「$name」を削除しますか？';
  }

  @override
  String get deleteProfileBody =>
      'このプロフィールの brain 設定とテーマカラーが失われます。\n\nディスク上の履歴は削除されません。誤って削除してもその履歴は残ります。';

  @override
  String get deleteProfileAction => 'このプロフィールを削除';

  @override
  String get chooseAvatar => 'アイコンを選択';

  @override
  String get changeAvatar => 'アイコンを変更';

  @override
  String get removeAvatar => '外す';

  @override
  String avatarPickFailed(String error) {
    return 'フォトライブラリを開けません：$error';
  }

  @override
  String get debugPanelTooltip => 'デバッグパネル';

  @override
  String get brainConfigTooltip => 'brain 設定';

  @override
  String get starting => 'しばらくお待ちください…';

  @override
  String get tapToStart => 'タップして会話を開始';

  @override
  String get segmenterUnavailable => '⚠️ 区間検出エンジンが使えません';

  @override
  String get tokenInvalid => '⚠️ token が無効です';

  @override
  String get brainUnresponsive => '⚠️ brain が応答しません';

  @override
  String get mutedUploadingOff => 'ミュート中 · 話した内容は送信されません';

  @override
  String get speakingCanClear => '話し中 · 音量ダウンでクリア';

  @override
  String get speaking => '話し中';

  @override
  String get listening => '聞いています';

  @override
  String queuedUtterances(int count) {
    return 'さらに $count 文を送信中';
  }

  @override
  String get idleHint => 'そのまま話しかけてください';

  @override
  String get emptyHint => '開始すると、あなたと相手の会話がここに表示されます';

  @override
  String get segmenterLoadFailed => '端末上の区間検出エンジンの読み込みに失敗しました';

  @override
  String get segmenterLoadFailedBody =>
      '多くは Rust の動的ライブラリ（librust_lib_pp_friend.so）が APK に入っていないか、ABI が合っていません。tools/build_rust_android.sh を再実行して、もう一度インストールしてください。';

  @override
  String get noBrain => 'brain が未設定です';

  @override
  String get noBrainBody => '会話を始めるには Base URL と brain_id を入力してください。';

  @override
  String get goToSettings => '設定へ';

  @override
  String get mute => 'ミュート';

  @override
  String get muted => 'ミュート中';

  @override
  String get bargeIn => '割り込み';

  @override
  String get debugTitle => 'デバッグパネル';

  @override
  String get conversationActive => '会話中';

  @override
  String get notStarted => '未開始';

  @override
  String get aiSpeaking => 'AI が話し中';

  @override
  String get aiSilent => 'AI は静か';

  @override
  String voiceprintScore(String score) {
    return '声紋 $score';
  }

  @override
  String get voiceprintPending => '声紋は未計測';

  @override
  String get voiceprintOff => '声紋照合オフ';

  @override
  String targetProbability(String probability) {
    return '本人確率 $probability';
  }

  @override
  String get speakerRecognitionOff => '話者認識オフ';

  @override
  String get droppedMicFrames => '破棄した収録フレーム';

  @override
  String get playbackBacklog => '再生の滞留フレーム';

  @override
  String get uploadQueue => '送信キュー';

  @override
  String get droppedUtterances => '破棄した文';

  @override
  String get polling => 'ポーリング中';

  @override
  String get stopped => '停止';

  @override
  String get upstreamCodec => '上りエンコード';

  @override
  String get segmentBuffer => '区間バッファ';

  @override
  String get segmentDropped => '区間の破棄';

  @override
  String get forcedCuts => '強制区切り';

  @override
  String get feedCost => 'feed 時間';

  @override
  String get filteredNonTarget => '本人以外を除外';

  @override
  String get startConversation => '会話を開始';

  @override
  String get endConversation => '会話を終了';

  @override
  String get droppedFramesWarning =>
      '収録フレームの破棄はメインスレッドが追いついていないことを示します。これは意図的なバックプレッシャー（遅延を溜めるよりフレームを捨てる）ですが、増え続けるなら調査が必要です。';

  @override
  String get realtimeLevel => 'リアルタイムレベル';

  @override
  String get levelExplanation =>
      'テスト音の再生中、マイクのバーはほぼ無音になるはずです。あなたが話すと明確に上がります。これが AEC の判定基準です。（自動割り込みをやめたので、ここにしきい値線はありません。レベルだけを見ます。）';

  @override
  String get stopTestTone => 'テスト音を停止';

  @override
  String get playTestTone => 'テスト音を再生（AEC 自己テスト）';

  @override
  String get sendTestUtterance => 'テスト音声を送信（上り確認）';

  @override
  String get testToneExplanation =>
      'テスト音は brain を通らずループ再生されるので、brain が起動していなくても使えます。AEC をいつでも確認できる唯一の入口です。「テスト音声を送信」はテスト音をあなたの発話として上り経路全体に流し、マイクなしでエンコード、multipart、認証、テキストの戻りを確認できます。';

  @override
  String get clearAiVoice => 'AI 音声をクリア';

  @override
  String get clearPlaybackExplanation =>
      'プロトコル上、自動割り込みはしません。受信したら再生します。止めるには手動で：';

  @override
  String get clearPlaybackQueue => '再生キューをクリア';

  @override
  String get clearPlaybackDetail =>
      '・通知の「話すのを停止」ボタン ― バックグラウンドでもロック画面でも使える\n・音量ダウンキー ― アプリが前面で AI 音声を再生中のみ横取り。それ以外は通常の音量調整。横取りするかは設定の「音量ダウンキーでキューをクリア」で決まり、オフなら音量調整だけ\n\nどちらも音声だけを消します。テキストは影響を受けず、メッセージ欄に残ります。';

  @override
  String get aecPanel => 'AEC 実測パネル';

  @override
  String get aecPanelActiveSubtitle => '変更すると音声経路が即座に再起動します';

  @override
  String get aecPanelSubtitle => '一度に一つの変数だけ動かす';

  @override
  String get captureSource => '収録ソース';

  @override
  String get playbackUsage => '再生属性';

  @override
  String get playbackUsageHint => 'media にすると AEC が参照信号を取得できない';

  @override
  String get performanceMode => 'パフォーマンスモード';

  @override
  String get performanceModeHint => 'lowLatency では effects が無効になることがある';

  @override
  String get manualAec => '手動 AEC';

  @override
  String get manualAecHint =>
      'AcousticEchoCanceler を重ねる。voiceCommunication とは別経路';

  @override
  String get speakerphone => 'スピーカー';

  @override
  String get speakerphoneHint => 'setSpeakerphoneOn ― ホットスイッチ可能。再起動不要';

  @override
  String get eventLog => 'イベントログ';

  @override
  String get noEvents => 'まだイベントはありません。メイン画面でボタンを押して話すと、ここに表示されます。';

  @override
  String get noEnabledProfiles => '有効なプロフィールがありません';

  @override
  String get noEnabledProfilesBody => '設定で新規作成するか、元のプロフィールを有効にしてください';

  @override
  String switchToProfile(String name) {
    return '$nameに切り替え';
  }

  @override
  String get previousProfile => '前のプロフィール';

  @override
  String get nextProfile => '次のプロフィール';

  @override
  String get micAfterAec => 'マイク（AEC 後）';

  @override
  String get playbackOutput => '再生出力';

  @override
  String get silent => '無音';

  @override
  String get orbStart => '会話を開始';

  @override
  String get orbStarting => '起動中';

  @override
  String get orbEnd => '会話を終了';

  @override
  String get jumpToBottom => '最新へ戻る';

  @override
  String get onboardingTitle => '権限チェック';

  @override
  String get onboardingIntro => '初めて使う前に、下の項目を有効にしてください。あとから設定でいつでも確認できます。';

  @override
  String get microphonePermission => 'マイク';

  @override
  String get microphonePermissionBody => 'マイクがないと、あなたの声を聞けません。';

  @override
  String get permissionGranted => '許可済み';

  @override
  String get permissionDenied => '拒否済み';

  @override
  String get permissionRestricted => 'システムに制限されています';

  @override
  String get permissionNotDetermined => 'まだ要求していません';

  @override
  String get permissionUnknown => '不明';

  @override
  String get requestPermission => '許可を求める';

  @override
  String get openSystemSettings => 'システム設定を開く';

  @override
  String get localNetworkPermission => 'ローカルネットワーク';

  @override
  String get localNetworkPermissionBody =>
      'macOS 15 以降、LAN 上の brain へのアクセスには別途許可が必要です。他のプラットフォームにはありません。';

  @override
  String get localNetworkReady => '許可済み、brain に接続できます';

  @override
  String get localNetworkUnavailable => '許可されていないか、brain に接続できません';

  @override
  String get localNetworkNotConfigured => '先に設定で brain アドレスを入力してください';

  @override
  String get localNetworkUnsupported => 'このプラットフォームでは不要です';

  @override
  String get checkNow => '確認';

  @override
  String get checking => '確認中…';

  @override
  String get setBrainAddress => 'brain アドレスを設定';

  @override
  String get onboardingStart => '使い始める';

  @override
  String get permissionCheckEntry => '権限チェック';

  @override
  String get permissionCheckEntrySubtitle => 'マイク、ローカルネットワーク';

  @override
  String get permissionRequestFailed => '許可を取得できませんでした。システム設定で有効にしてください';

  @override
  String get brainEndpointTitle => 'brain アドレス';

  @override
  String get brainBaseUrlLabel => 'Base URL';

  @override
  String get saveAndCheck => '保存して確認';

  @override
  String get brainNotConfigured => '先に Base URL と brain_id を入力してください';

  @override
  String get notChecked => 'まだ確認していません';

  @override
  String brainHttpOk(int status) {
    return 'HTTP 接続済み（$status）';
  }

  @override
  String get brainHttpTimeout => '接続がタイムアウトしました';

  @override
  String brainHttpError(String error) {
    return '接続に失敗しました：$error';
  }

  @override
  String get invalidBrainUrl => 'アドレスは http:// または https:// で始めてください';

  @override
  String get micSettingsPath =>
      'システム設定 → プライバシーとセキュリティ → マイク → pp_friend を有効にする';

  @override
  String get localNetworkSettingsPath =>
      'システム設定 → プライバシーとセキュリティ → ローカルネットワーク → pp_friend を有効にする';

  @override
  String get continueBlocked => 'マイク、brain アドレス、ローカルネットワークの確認がすべて通ると続行できます';
}

// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get save => 'Save';

  @override
  String get saved => 'Saved';

  @override
  String get delete => 'Delete';

  @override
  String get clear => 'Clear';

  @override
  String get cancel => 'Cancel';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get tabProfiles => 'Profiles';

  @override
  String get tabGeneral => 'General';

  @override
  String get languageSection => 'Language';

  @override
  String get languageFollowSystem => 'Follow system';

  @override
  String get languageChinese => '中文';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageJapanese => '日本語';

  @override
  String get languageChanged => 'Language changed';

  @override
  String saveFailed(String error) {
    return 'Couldn\'t save: $error';
  }

  @override
  String get profileGoneUnsaved =>
      'This profile no longer exists. Nothing was saved.';

  @override
  String get noAppToOpenPage => 'No app can open this page.';

  @override
  String openPageFailed(String error) {
    return 'Couldn\'t open the page: $error';
  }

  @override
  String get voiceprintImported => 'Voiceprint imported';

  @override
  String notVoiceprint(String message) {
    return 'This file isn\'t a voiceprint: $message';
  }

  @override
  String importFailed(String error) {
    return 'Import failed: $error';
  }

  @override
  String get voiceprintRemoved => 'Voiceprint deleted';

  @override
  String saveFailedBeforeSwitch(String error) {
    return 'Couldn\'t save; profile not switched: $error';
  }

  @override
  String saveFailedBeforeAdd(String error) {
    return 'Couldn\'t save; profile not created: $error';
  }

  @override
  String get newProfile => 'New profile';

  @override
  String get newProfileTooltip => 'New profile';

  @override
  String get profileDisabled => 'Off';

  @override
  String get localSegmentation => 'On-device segmentation';

  @override
  String get localSegmentationBody =>
      'Silero VAD runs on the phone and only finished utterances are uploaded.\nThese settings are global; switching profiles does not reload the model.';

  @override
  String get vadMinSilenceMsLabel => 'Silence threshold (ms)';

  @override
  String get vadMinSilenceMsHint =>
      '700: the one that matters most. Lower reacts sooner; too low cuts pauses inside a sentence';

  @override
  String get vadThresholdLabel => 'Speech probability threshold';

  @override
  String get vadThresholdHint =>
      '0.5: from 0 to 1. Lower triggers more easily, higher is more conservative';

  @override
  String get vadSpeechPadMsLabel => 'Padding (ms)';

  @override
  String get vadSpeechPadMsHint =>
      '200: keep a little on both ends, otherwise the first syllable gets clipped';

  @override
  String get vadMinSpeechMsLabel => 'Minimum speech (ms)';

  @override
  String get vadMinSpeechMsHint =>
      '300: anything shorter is dropped, so a cough does not upload';

  @override
  String get vadMaxSpeechSLabel => 'Longest utterance (s)';

  @override
  String get vadMaxSpeechSHint =>
      '60: force a cut after this, so one sentence cannot run forever';

  @override
  String get speakerRecognition => 'Speaker recognition';

  @override
  String get onlyMyVoice => 'Only recognize my voice';

  @override
  String get voiceprintImportedStatus => 'Voiceprint imported';

  @override
  String get voiceprintNeeded => 'Import a voiceprint first';

  @override
  String get openVoiceprintPage =>
      'Create your voiceprint locally and download it';

  @override
  String get voiceprintOptionalHint =>
      'Optional. The voiceprint filters out other voices and noise so only your own speech reaches the agent.';

  @override
  String get reimportVoiceprint => 'Replace voiceprint';

  @override
  String get importVoiceprint => 'Import voiceprint';

  @override
  String get deleteVoiceprint => 'Delete voiceprint';

  @override
  String get similarityThreshold => 'Similarity threshold';

  @override
  String get volumeKeys => 'Volume keys';

  @override
  String get volumeKeyClearsQueue => 'Volume-down clears playback';

  @override
  String get volumeKeySubtitle =>
      'On: pressing volume-down while the AI speaks stops it (foreground only).\nIn the background or on the lock screen, use Stop speaking in the notification.';

  @override
  String get settingsNotice =>
      'Recognition and synthesis run on the brain. The phone only captures, segments, uploads, and plays.\nThe history stored here is for display, not conversation context. Deleting it does not affect the brain\'s memory.';

  @override
  String get profileAppearance => 'Profile appearance';

  @override
  String get nameLabel => 'Name';

  @override
  String get nameHint => 'e.g. Employee 3. Leave empty to use brain_id';

  @override
  String get themeColor => 'Accent color';

  @override
  String get colorIndigo => 'Indigo';

  @override
  String get colorInkGreen => 'Deep green';

  @override
  String get colorTerracotta => 'Terracotta';

  @override
  String get colorPurple => 'Purple';

  @override
  String get colorLakeBlue => 'Lake blue';

  @override
  String get colorOchre => 'Ochre';

  @override
  String get colorRose => 'Rose';

  @override
  String get colorSlate => 'Slate';

  @override
  String get baseUrlLabel => 'Base URL';

  @override
  String get baseUrlHint => 'http://192.168.0.100:8000';

  @override
  String get brainIdLabel => 'brain_id';

  @override
  String get brainIdHint =>
      'e.g. Employee 3. A meaningful name, just like the profile name';

  @override
  String get tokenLabel => 'Bearer token';

  @override
  String get tokenHint =>
      'Leave empty if the deployment has no auth; the header will not be sent';

  @override
  String get statusSection => 'Status';

  @override
  String get enabled => 'Enabled';

  @override
  String get enabledSubtitleOn =>
      'Keeps receiving its messages (when not focused, text is stored but not played)';

  @override
  String get enabledSubtitleOff =>
      'Not connected. History stays on disk and can be reopened anytime';

  @override
  String get focusedDisabledWarning =>
      'This is the profile selected on the main screen. Saving will switch to another enabled profile.';

  @override
  String get switchToThisProfile => 'Switch to this profile';

  @override
  String get switchBySwipeHint =>
      'You can also swipe the talk button on the main screen';

  @override
  String get historySection => 'History';

  @override
  String historyUsage(String size) {
    return '$size on disk.\nKept forever; no automatic cleanup. Clear it here if it reaches hundreds of MB.';
  }

  @override
  String get clearHistoryTitle => 'Clear this profile\'s history?';

  @override
  String get clearHistoryBody =>
      'Messages for this profile will disappear from the main screen and cannot be recovered.\n\nThe brain is unaffected: the local copy is display history, while conversation context lives on the brain_id.';

  @override
  String get historyCleared => 'Cleared';

  @override
  String deleteProfileTitle(String name) {
    return 'Delete \"$name\"?';
  }

  @override
  String get deleteProfileBody =>
      'This profile\'s brain settings and accent color will be removed.\n\nHistory on disk is kept, so an accidental delete does not lose it.';

  @override
  String get deleteProfileAction => 'Delete this profile';

  @override
  String get chooseAvatar => 'Choose avatar';

  @override
  String get changeAvatar => 'Change avatar';

  @override
  String get removeAvatar => 'Remove';

  @override
  String avatarPickFailed(String error) {
    return 'Couldn\'t open the photo library: $error';
  }

  @override
  String get debugPanelTooltip => 'Debug panel';

  @override
  String get brainConfigTooltip => 'Brain settings';

  @override
  String get starting => 'Starting…';

  @override
  String get tapToStart => 'Tap to start';

  @override
  String get segmenterUnavailable => '⚠️ Segmenter unavailable';

  @override
  String get tokenInvalid => '⚠️ Invalid token';

  @override
  String get brainUnresponsive => '⚠️ Brain not responding';

  @override
  String get mutedUploadingOff => 'Muted · speech is not uploaded';

  @override
  String get speakingCanClear => 'Speaking · volume-down clears it';

  @override
  String get speaking => 'Speaking';

  @override
  String get listening => 'Listening';

  @override
  String queuedUtterances(int count) {
    return '$count more utterances uploading';
  }

  @override
  String get idleHint => 'Just start talking';

  @override
  String get emptyHint =>
      'Once you start, everything you and the assistant say appears here';

  @override
  String get segmenterLoadFailed => 'On-device segmenter failed to load';

  @override
  String get segmenterLoadFailedBody =>
      'Usually the Rust library (librust_lib_pp_friend.so) is missing from the APK or the ABI does not match. Re-run tools/build_rust_android.sh and install again.';

  @override
  String get noBrain => 'No brain configured';

  @override
  String get noBrainBody => 'Fill in Base URL and brain_id before starting.';

  @override
  String get goToSettings => 'Open settings';

  @override
  String get mute => 'Mute';

  @override
  String get muted => 'Muted';

  @override
  String get bargeIn => 'Barge-in';

  @override
  String get debugTitle => 'Debug panel';

  @override
  String get conversationActive => 'Conversation active';

  @override
  String get notStarted => 'Not started';

  @override
  String get aiSpeaking => 'AI speaking';

  @override
  String get aiSilent => 'AI silent';

  @override
  String voiceprintScore(String score) {
    return 'Voiceprint $score';
  }

  @override
  String get voiceprintPending => 'Voiceprint pending';

  @override
  String get voiceprintOff => 'Voiceprint check off';

  @override
  String targetProbability(String probability) {
    return 'Target probability $probability';
  }

  @override
  String get speakerRecognitionOff => 'Speaker recognition off';

  @override
  String get droppedMicFrames => 'Dropped capture frames';

  @override
  String get playbackBacklog => 'Playback backlog';

  @override
  String get uploadQueue => 'Upload queue';

  @override
  String get droppedUtterances => 'Dropped utterances';

  @override
  String get polling => 'Polling';

  @override
  String get stopped => 'Stopped';

  @override
  String get upstreamCodec => 'Upstream codec';

  @override
  String get segmentBuffer => 'Segment buffer';

  @override
  String get segmentDropped => 'Dropped by segmenter';

  @override
  String get forcedCuts => 'Forced cuts';

  @override
  String get feedCost => 'Feed time';

  @override
  String get filteredNonTarget => 'Filtered (not target)';

  @override
  String get startConversation => 'Start conversation';

  @override
  String get endConversation => 'End conversation';

  @override
  String get droppedFramesWarning =>
      'Dropped capture frames mean the main thread fell behind. This is intentional backpressure (drop frames rather than accumulate latency), but a growing count needs investigation.';

  @override
  String get realtimeLevel => 'Live levels';

  @override
  String get levelExplanation =>
      'While the test tone plays, the mic bar should stay near silence; it should rise clearly when you speak. That is the AEC check. (Automatic barge-in is gone, so there is no threshold line now; just watch the level.)';

  @override
  String get stopTestTone => 'Stop test tone';

  @override
  String get playTestTone => 'Play test tone (AEC check)';

  @override
  String get sendTestUtterance => 'Send test utterance (verify upstream)';

  @override
  String get testToneExplanation =>
      'The test tone bypasses the brain and loops locally, so it works even when the brain is down; it is the one AEC check that always works. Send test utterance pushes a sample through the full upstream path, so you can verify encoding, multipart, auth, and text round-trip without a microphone.';

  @override
  String get clearAiVoice => 'Clear AI audio';

  @override
  String get clearPlaybackExplanation =>
      'The protocol does not auto-interrupt: audio plays as it arrives. Stopping it is manual:';

  @override
  String get clearPlaybackQueue => 'Clear playback queue';

  @override
  String get clearPlaybackDetail =>
      '• Stop speaking in the notification: works in the background and on the lock screen\n• Volume-down: intercepted only while the app is in the foreground and AI audio is playing; otherwise passed through so normal volume control still works. The settings switch \"Volume-down clears playback\" decides this; turn it off for plain volume control\n\nBoth only clear audio. Text still enters the message stream.';

  @override
  String get aecPanel => 'AEC test panel';

  @override
  String get aecPanelActiveSubtitle =>
      'Changes restart the audio pipeline immediately';

  @override
  String get aecPanelSubtitle => 'Change one variable at a time';

  @override
  String get captureSource => 'Capture source';

  @override
  String get playbackUsage => 'Playback usage';

  @override
  String get playbackUsageHint =>
      'media prevents AEC from getting a reference signal';

  @override
  String get performanceMode => 'Performance mode';

  @override
  String get performanceModeHint => 'effects may stop working in lowLatency';

  @override
  String get manualAec => 'Manual AEC';

  @override
  String get manualAecHint =>
      'Adds AcousticEchoCanceler; separate from voiceCommunication';

  @override
  String get speakerphone => 'Speakerphone';

  @override
  String get speakerphoneHint =>
      'setSpeakerphoneOn: can be toggled without a restart';

  @override
  String get eventLog => 'Event log';

  @override
  String get noEvents =>
      'No events yet. Go back, tap the button, speak, and entries will appear here.';

  @override
  String get noEnabledProfiles => 'No enabled profiles';

  @override
  String get noEnabledProfilesBody =>
      'Create one in settings, or enable the existing profile';

  @override
  String switchToProfile(String name) {
    return 'Switch to $name';
  }

  @override
  String get previousProfile => 'Previous profile';

  @override
  String get nextProfile => 'Next profile';

  @override
  String get micAfterAec => 'Microphone (after AEC)';

  @override
  String get playbackOutput => 'Playback output';

  @override
  String get silent => 'Silent';

  @override
  String get orbStart => 'Start conversation';

  @override
  String get orbStarting => 'Starting';

  @override
  String get orbEnd => 'End conversation';

  @override
  String get jumpToBottom => 'Jump to latest';

  @override
  String get onboardingTitle => 'Permissions';

  @override
  String get onboardingIntro =>
      'Before the first conversation, turn on the items below. You can come back to this page from Settings anytime.';

  @override
  String get microphonePermission => 'Microphone';

  @override
  String get microphonePermissionBody =>
      'Without the microphone, the app cannot hear you.';

  @override
  String get permissionGranted => 'Allowed';

  @override
  String get permissionDenied => 'Denied';

  @override
  String get permissionRestricted => 'Restricted by the system';

  @override
  String get permissionNotDetermined => 'Not requested yet';

  @override
  String get permissionUnknown => 'Unknown';

  @override
  String get requestPermission => 'Request permission';

  @override
  String get openSystemSettings => 'Open System Settings';

  @override
  String get localNetworkPermission => 'Local network';

  @override
  String get localNetworkPermissionBody =>
      'Since macOS 15, reaching a brain on your LAN requires separate permission. Other platforms do not have this.';

  @override
  String get localNetworkReady => 'Allowed, the brain is reachable';

  @override
  String get localNetworkUnavailable =>
      'Not allowed, or the brain is unreachable';

  @override
  String get localNetworkNotConfigured => 'Set a brain address first';

  @override
  String get localNetworkUnsupported => 'Not needed on this platform';

  @override
  String get checkNow => 'Check';

  @override
  String get checking => 'Checking…';

  @override
  String get setBrainAddress => 'Set brain address';

  @override
  String get onboardingStart => 'Start using it';

  @override
  String get permissionCheckEntry => 'Permissions';

  @override
  String get permissionCheckEntrySubtitle => 'Microphone, local network';

  @override
  String get permissionRequestFailed =>
      'Request failed; enable it in System Settings';

  @override
  String get brainEndpointTitle => 'Brain address';

  @override
  String get brainBaseUrlLabel => 'Base URL';

  @override
  String get saveAndCheck => 'Save and check';

  @override
  String get brainNotConfigured => 'Fill in Base URL and brain_id first';

  @override
  String get notChecked => 'Not checked yet';

  @override
  String brainHttpOk(int status) {
    return 'HTTP reachable ($status)';
  }

  @override
  String get brainHttpTimeout => 'Connection timed out';

  @override
  String brainHttpError(String error) {
    return 'Connection failed: $error';
  }

  @override
  String get invalidBrainUrl =>
      'The address must start with http:// or https://';

  @override
  String get micSettingsPath =>
      'System Settings → Privacy & Security → Microphone → enable pp_friend';

  @override
  String get localNetworkSettingsPath =>
      'System Settings → Privacy & Security → Local Network → enable pp_friend';

  @override
  String get continueBlocked =>
      'Allow the microphone, verify the brain address, and pass the local network check to continue';

  @override
  String get skipCurrentSpeech => 'Skip';

  @override
  String get skipCurrentSpeechTooltip => 'Skip the line currently playing';
}

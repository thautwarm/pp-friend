import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// 和语音引擎共用一条 MethodChannel；macOS 原生侧实现了 `requestMicPermission`。
const MethodChannel _channel = MethodChannel('pp_friend/voice_engine');

/// 麦克风权限状态。和 permission_handler 的 PermissionStatus 解耦，
/// UI 只关心这几种。
enum MicPermissionState { granted, denied, restricted, notDetermined, unknown }

/// 本地网络权限（只有 macOS 15+ 有这个概念）。
enum LocalNetworkState {
  /// 能连上目标地址 —— 权限已经允许，brain 也活着。
  ready,

  /// 没连上：可能没授权，也可能 brain 没开。
  unavailable,

  /// 还没填 brain 地址，没得探测。
  notConfigured,

  /// 当前平台不需要这个权限。
  unsupported,
}

/// 申请麦克风权限。
///
/// 先问原生语音引擎 —— macOS 用的是 `AVCaptureDevice`，`permission_handler`
/// 在 macOS 上没有实现。平台没有这条通道（比如 iOS 还没写原生侧）时，
/// 再回落到 `permission_handler`。
Future<bool> requestMicPermission() async {
  try {
    final granted = await _channel.invokeMethod<bool>('requestMicPermission');
    if (granted != null) return granted;
  } on MissingPluginException {
    // 这个平台没有原生语音引擎，走通用插件。
  } on PlatformException {
    // 原生实现失败，同样回落。
  }

  final status = await Permission.microphone.request();
  return status.isGranted;
}

/// 读麦克风权限状态，**不弹框**。
///
/// macOS 走原生 `AVCaptureDevice`，其他平台回落到 permission_handler。
Future<MicPermissionState> micPermissionStatus() async {
  try {
    final status = await _channel.invokeMethod<String>('micPermissionStatus');
    switch (status) {
      case 'authorized':
        return MicPermissionState.granted;
      case 'denied':
        return MicPermissionState.denied;
      case 'restricted':
        return MicPermissionState.restricted;
      case 'notDetermined':
        return MicPermissionState.notDetermined;
    }
  } on MissingPluginException {
    // 原生侧没有这条通道，走插件。
  } on PlatformException {
    // 原生失败也走插件。
  }

  try {
    final status = await Permission.microphone.status;
    if (status.isGranted || status.isLimited) {
      return MicPermissionState.granted;
    }
    if (status.isRestricted) return MicPermissionState.restricted;
    if (status.isPermanentlyDenied || status.isDenied) {
      return MicPermissionState.denied;
    }
  } on MissingPluginException {
    // 桌面平台没有 permission_handler 实现。
  } on PlatformException {
    // 同上。
  }
  return MicPermissionState.unknown;
}

/// 打开系统的麦克风权限设置页。
Future<void> openMicSettings() async {
  try {
    await _channel.invokeMethod<bool>('openMicSettings');
    return;
  } on MissingPluginException {
    // 其他平台用 permission_handler 打开 App 设置。
  } on PlatformException {
    // 落到下面的兜底。
  }
  try {
    await openAppSettings();
  } on MissingPluginException {
    // 桌面平台没有这个能力。
  } on PlatformException {
    // 打不开就算了，不阻断。
  }
}

/// 探测本地网络是否可用。
///
/// macOS 的本地网络授权没有查询 API，只能真的连一次 brain 地址：
/// 连上了说明授权和网络都通；连不上就统一报"未允许或不可达"。
/// 这个探测同时会把系统的本地网络授权框逼出来。
Future<LocalNetworkState> checkLocalNetwork(String baseUrl) async {
  final uri = Uri.tryParse(baseUrl.trim());
  if (uri == null || uri.host.isEmpty) return LocalNetworkState.notConfigured;
  final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);

  try {
    final status = await _channel.invokeMethod<String>('probeLocalNetwork', {
      'host': uri.host,
      'port': port,
      'timeoutMs': 5000,
    });
    return status == 'ready'
        ? LocalNetworkState.ready
        : LocalNetworkState.unavailable;
  } on MissingPluginException {
    // 这个平台没有本地网络权限（Android/iOS 不需要，Windows/Linux 也还没实现）。
    return LocalNetworkState.unsupported;
  } on PlatformException {
    return LocalNetworkState.unavailable;
  }
}

/// 打开系统的本地网络设置页（macOS）。
Future<void> openLocalNetworkSettings() async {
  try {
    await _channel.invokeMethod<bool>('openLocalNetworkSettings');
  } on MissingPluginException {
    // 非 macOS 没有这个页面。
  } on PlatformException {
    // 打不开就算了。
  }
}

/// 通知权限只有 Android/iOS 需要。
///
/// 不支持的平台上 `permission_handler` 会抛 `MissingPluginException`，
/// 这里吞掉即可 —— 前台服务本来就不是这些平台的概念。
Future<void> requestNotificationPermissionIfSupported() async {
  try {
    await Permission.notification.request();
  } on MissingPluginException {
    // macOS/Linux/Windows 没有这个插件。
  } on PlatformException {
    // 系统不支持就算了，不阻断会话。
  }
}

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// 和语音引擎共用一条 MethodChannel；macOS 原生侧实现了 `requestMicPermission`。
const MethodChannel _channel = MethodChannel('pp_friend/voice_engine');

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

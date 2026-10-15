import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'src/conversation/conversation_controller.dart';
import 'src/ui/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PpFriendApp());
}

class PpFriendApp extends StatefulWidget {
  const PpFriendApp({super.key});

  @override
  State<PpFriendApp> createState() => _PpFriendAppState();
}

class _PpFriendAppState extends State<PpFriendApp> {
  late final ConversationController _controller;

  static const _seed = Color(0xFF5B6ABF);

  @override
  void initState() {
    super.initState();
    _controller = ConversationController()..permissionGate = _requestPermissions;
    // 配置是异步读的，先渲染再补上，避免卡在启动画面
    _controller.loadConfig();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 麦克风必须给；通知在 Android 13+ 决定前台服务那条常驻通知能否显示，
  /// 被拒绝也不阻断 —— 服务照样跑，只是通知栏看不到。
  Future<bool> _requestPermissions() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) return false;

    await Permission.notification.request();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PP Friend',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: _seed, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: _seed,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: HomePage(controller: _controller),
    );
  }
}

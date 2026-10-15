import 'dart:io';

import 'package:pp_friend/src/storage/avatar_store.dart';

/// 记流水账的假头像存储，**不碰磁盘**（同步的那几下除外）。
///
/// 界面测试必须用它：`testWidgets` 把测试体跑在一个假时钟里，真实的异步
/// 文件 IO 在那里**永远不会完成** —— 测试会直接挂住，连超时都报不出来
/// （超时是靠定时器实现的，而定时的东西也在那个假时钟里）。
///
/// 用它同时也让断言更好写：直接看它删过哪些文件名，比去翻临时目录清楚。
class FakeAvatarStore extends AvatarStore {
  FakeAvatarStore() : super(Directory('/假的/应用目录'));

  /// 文件名 → 内容。只有同步读写，够这套用例用。
  final Map<String, String> files = {};

  /// 被拷进来过几次新的，值是档案 id。
  final List<String> imported = [];

  /// 被删过的文件名，按先后顺序。没设头像时的 null 也记一笔。
  final List<String?> removed = [];

  int _seq = 0;

  @override
  String? pathOf(String? fileName) =>
      fileName == null || fileName.isEmpty ? null : '${dir.path}/$fileName';

  @override
  Future<String> import(String profileId, String sourcePath) async {
    // 源文件读不到就得抛 —— 这是 AvatarStore 的契约，假实现也得守
    if (!File(sourcePath).existsSync()) {
      throw FileSystemException('选中的图片读不到', sourcePath);
    }
    final name = '${profileId}_${_seq++}.png';
    files[name] = File(sourcePath).readAsStringSync();
    imported.add(profileId);
    return name;
  }

  @override
  Future<void> remove(String? fileName) async {
    removed.add(fileName);
    if (fileName != null) files.remove(fileName);
  }
}

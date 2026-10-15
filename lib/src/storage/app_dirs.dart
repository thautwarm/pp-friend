import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 拿应用私有目录。**失败返回 null**，不抛。
///
/// 返回 null 是一个正常的可能结果：非 Android 平台上这个仓库还没有原生实现，
/// `flutter test` 里没有平台通道，都会走到这里。调用方必须处理它 ——
/// 退化到内存存储，并且**在界面上说出来**，不能让用户以为历史存下来了。
typedef AppDirResolver = Future<Directory?> Function();

/// 默认实现：应用文档目录下的 `pp_friend` 子目录。
///
/// 用文档目录（Android 上就是 `filesDir`），不用外部存储 —— 外部存储要权限、
/// 别的 App 能看见，还要处理分区存储那一堆。这个目录随卸载一起清掉，正合适。
Future<Directory?> resolveAppDir() async {
  try {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/pp_friend');
  } catch (_) {
    return null;
  }
}

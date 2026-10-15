import 'dart:io';

/// 档案头像的落地位置：`<应用目录>/avatars/<档案id>_<时间戳>.<扩展名>`。
///
/// **拷副本进来，不存相册路径。** 相册给的 `content://` 授权会过期、会被
/// 系统回收，存路径的话过一阵子头像就变成一块空白，而且用户完全不知道为什么。
/// 代价是每个头像多占一份空间（一般几十 KB），相比"永久保留历史"这个取舍
/// 不值一提。
///
/// 文件名里带时间戳，是为了让**换头像时路径一定变**。界面按路径缓存
/// [ImageProvider]，路径不变的话换了图还会显示旧的那张（Flutter 的图片缓存
/// 只在撑爆时淘汰，不会因为磁盘上的文件被覆盖就失效）。
class AvatarStore {
  const AvatarStore(this.root);

  /// 应用目录。和消息历史同一个根。
  final Directory root;

  Directory get dir => Directory('${root.path}/avatars');

  /// 只认这几个扩展名，别的一律当 png。
  ///
  /// 相册回来的路径理论上带正确扩展名，但 `Image` 靠扩展名判断解码器（
  /// 其实靠文件头，但错误提示和调试信息都按扩展名走）。写死一个白名单，
  /// 免得用户挑一个 `.heic` 之后一路查不出为什么显示不出来。
  static const Set<String> _allowedExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
    '.gif',
    '.bmp',
  };

  /// 头像文件的绝对路径。**不检查文件在不在** —— 这个方法会在每帧 build 里
  /// 被调用，同步 `stat` 一次盘不值得。文件真丢了由 `Image` 的 errorBuilder
  /// 兜底退回图标。
  String? pathOf(String? fileName) {
    if (fileName == null || fileName.isEmpty) return null;
    return '${dir.path}/$fileName';
  }

  /// 把选中的图片拷进来，返回新文件名。
  ///
  /// 拷贝失败会抛 —— 调用方必须让用户知道"头像没换成"，静默失败比不换更糟。
  Future<String> import(String profileId, String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('选中的图片读不到', sourcePath);
    }

    final extension = _extensionOf(sourcePath);
    final name = '${profileId}_${DateTime.now().millisecondsSinceEpoch}$extension';
    await dir.create(recursive: true);
    await source.copy('${dir.path}/$name');
    return name;
  }

  /// 删掉一个头像文件。文件本来就不在也算成功 —— 目标状态已经达到了。
  Future<void> remove(String? fileName) async {
    if (fileName == null || fileName.isEmpty) return;
    try {
      final file = File('${dir.path}/$fileName');
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // 删不掉就算了。为了一个孤儿文件把"删档案"整个操作搞失败不值得，
      // 用户看到的是"删不掉"，而不是"头像清不掉"。
    }
  }

  static String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return '.png';
    final extension = path.substring(dot).toLowerCase();
    return _allowedExtensions.contains(extension) ? extension : '.png';
  }
}

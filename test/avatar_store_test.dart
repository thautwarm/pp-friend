import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:pp_friend/src/storage/avatar_store.dart';

/// 一个临时应用目录。每个用例一个，互不干扰。
Directory _root() {
  final dir = Directory.systemTemp.createTempSync('pp_avatar_test');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// 造一张"图"。内容随便，这里不验解码，只验文件有没有被搬过去。
File _source(Directory dir, String name, String content) =>
    File('${dir.path}/$name')..writeAsStringSync(content);

void main() {
  group('路径', () {
    test('没设头像时给 null', () {
      final store = AvatarStore(_root());
      expect(store.pathOf(null), isNull);
      expect(store.pathOf(''), isNull);
    });

    test('给了文件名就拼在 avatars 目录下', () {
      final root = _root();
      final store = AvatarStore(root);
      expect(store.pathOf('p_a_1.png'), '${root.path}/avatars/p_a_1.png');
    });
  });

  group('拷进来', () {
    test('拷一份副本，原图不用动', () async {
      final root = _root();
      final store = AvatarStore(root);
      final source = _source(root, 'from_gallery.png', '假装是图片');

      final name = await store.import('p_a', source.path);

      expect(name, startsWith('p_a_'), reason: '文件名带档案 id，一眼能看出是谁的');
      expect(name, endsWith('.png'));
      final copied = File('${store.dir.path}/$name');
      expect(await copied.readAsString(), '假装是图片');
      // 原图还在 —— 拷的是副本，不是搬走
      expect(source.existsSync(), isTrue);
    });

    test('目录不存在会自己建出来', () async {
      final root = _root();
      final store = AvatarStore(root);
      expect(store.dir.existsSync(), isFalse);

      await store.import('p_a', _source(root, 'a.png', 'x').path);

      expect(store.dir.existsSync(), isTrue);
    });

    test('认不出的扩展名一律当 png', () async {
      final root = _root();
      final store = AvatarStore(root);

      expect(
        await store.import('p_a', _source(root, 'a.heic', 'x').path),
        endsWith('.png'),
      );
      expect(
        await store.import('p_b', _source(root, 'noext', 'x').path),
        endsWith('.png'),
      );
      // 大小写归一，别出现 .PNG 和 .png 两种
      expect(
        await store.import('p_c', _source(root, 'c.JPG', 'x').path),
        endsWith('.jpg'),
      );
    });

    test('原图读不到要抛 —— 静默失败会让用户以为头像换了', () async {
      final store = AvatarStore(_root());
      await expectLater(
        store.import('p_a', '${_root().path}/根本没有这个文件.png'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('换第二次的路径和第一次不同', () async {
      final root = _root();
      final store = AvatarStore(root);

      final first = await store.import(
        'p_a',
        _source(root, 'a.png', '第一张').path,
      );
      // 文件名带毫秒时间戳。隔开一点，别赌两次调用落在同一毫秒 ——
      // 真撞上了也不会出错（同名覆盖，内容是新那张），只是这个断言会假红。
      await Future<void>.delayed(const Duration(milliseconds: 3));
      final second = await store.import(
        'p_a',
        _source(root, 'b.png', '第二张').path,
      );

      // 界面按路径缓存 ImageProvider：路径不变的话，换了图还会显示旧的那张
      expect(second, isNot(first));
      expect(await File(store.pathOf(second)!).readAsString(), '第二张');
    });
  });

  group('删掉', () {
    test('删掉指定文件', () async {
      final root = _root();
      final store = AvatarStore(root);
      final name = await store.import('p_a', _source(root, 'a.png', 'x').path);

      await store.remove(name);

      expect(File(store.pathOf(name)!).existsSync(), isFalse);
    });

    test('文件本来就不在也算成功', () async {
      final store = AvatarStore(_root());
      await store.remove('p_a_1.png');
      await store.remove(null);
      await store.remove('');
    });
  });
}

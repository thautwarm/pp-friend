import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pp_friend/src/brain/brain_client.dart';
import 'package:pp_friend/src/config/assistant_config.dart';
import 'package:pp_friend/src/conversation/conversation_controller.dart';

import 'support/voice_fakes.dart';

/// 真的拿一个临时目录当应用目录。头像这块全是文件操作，假不了。
Directory _appRoot() {
  final dir = Directory.systemTemp.createTempSync('pp_profile_avatar');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// 一张假的"图片"。
File _image(Directory dir, String name, String content) =>
    File('${dir.path}/$name')..writeAsStringSync(content);

AssistantConfig _twoProfiles() => const AssistantConfig(
  profiles: [
    Profile(
      id: 'p_a',
      name: 'A',
      brain: BrainConfig(baseUrl: 'http://test.local:8000', brainId: 'a'),
    ),
    Profile(
      id: 'p_b',
      name: 'B',
      brain: BrainConfig(baseUrl: 'http://test.local:8000', brainId: 'b'),
    ),
  ],
  focusedProfileId: 'p_a',
);

Future<ConversationController> _boot({Directory? root}) async {
  final temp = root ?? _appRoot();
  final engine = FakeVoiceEngine();
  final controller = ConversationController(
    engine: engine,
    // 每个档案一个客户端，所以给工厂。这里只验证档案增删改，不发请求。
    brainFactory: () =>
        BrainClient(client: MockClient((_) async => throw StateError('不该发请求'))),
    appDir: () async => temp,
    segmenterFactory: ({
      required int sampleRate,
      required AssistantConfig config,
    }) async => FakeSegmenter(),
  );
  // 不注入 history，让它真的走一遍目录解析 —— _appRoot 就是这么来的
  await controller.updateConfig(_twoProfiles());
  return controller;
}

Profile _profile(ConversationController c, String id) =>
    c.config.profiles.firstWhere((p) => p.id == id);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('设置头像', () {
    test('拷进应用目录，配置里记的是文件名', () async {
      final root = _appRoot();
      final controller = await _boot(root: root);
      addTearDown(controller.dispose);
      final source = _image(root, '来自相册.png', '图的内容');

      await controller.setAvatar('p_a', source.path);

      final profile = _profile(controller, 'p_a');
      expect(profile.avatarFile, isNotNull);
      expect(
        profile.avatarFile,
        isNot(contains('/')),
        reason: '存的是文件名不是路径：路径里的目录名以后可能变',
      );
      final path = controller.avatarPathOf(profile)!;
      expect(path, startsWith('${root.path}/avatars/'));
      expect(File(path).readAsStringSync(), '图的内容');
      // 原图还在（相册那份不该被我们动）
      expect(source.existsSync(), isTrue);
    });

    test('换一张会把旧的删掉，不留孤儿文件', () async {
      final root = _appRoot();
      final controller = await _boot(root: root);
      addTearDown(controller.dispose);

      await controller.setAvatar('p_a', _image(root, '一.png', '第一张').path);
      final first = controller.avatarPathOf(_profile(controller, 'p_a'))!;
      await Future<void>.delayed(const Duration(milliseconds: 3));
      await controller.setAvatar('p_a', _image(root, '二.png', '第二张').path);
      final second = controller.avatarPathOf(_profile(controller, 'p_a'))!;

      expect(second, isNot(first));
      expect(File(second).readAsStringSync(), '第二张');
      expect(
        File(first).existsSync(),
        isFalse,
        reason: '换了头像旧文件要收掉，不然每换一次就多一份永久垃圾',
      );
    });

    test('传 null 就是去掉头像，文件也删掉', () async {
      final root = _appRoot();
      final controller = await _boot(root: root);
      addTearDown(controller.dispose);

      await controller.setAvatar('p_a', _image(root, '一.png', '第一张').path);
      final path = controller.avatarPathOf(_profile(controller, 'p_a'))!;

      await controller.setAvatar('p_a', null);

      expect(_profile(controller, 'p_a').avatarFile, isNull);
      expect(controller.avatarPathOf(_profile(controller, 'p_a')), isNull);
      expect(File(path).existsSync(), isFalse);
    });

    test('只动指定的那个档案', () async {
      final root = _appRoot();
      final controller = await _boot(root: root);
      addTearDown(controller.dispose);

      await controller.setAvatar('p_b', _image(root, '一.png', '图').path);

      expect(_profile(controller, 'p_b').avatarFile, isNotNull);
      expect(_profile(controller, 'p_a').avatarFile, isNull);
    });

    test('图读不到要抛 —— 静默失败会让用户以为换好了', () async {
      final root = _appRoot();
      final controller = await _boot(root: root);
      addTearDown(controller.dispose);

      await expectLater(
        controller.setAvatar('p_a', '${root.path}/没有这个文件.png'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        _profile(controller, 'p_a').avatarFile,
        isNull,
        reason: '拷贝失败不该在配置里留下一个指向不存在文件的引用',
      );
    });

    test('档案 id 不存在就什么也不做', () async {
      final controller = await _boot();
      addTearDown(controller.dispose);
      await controller.setAvatar('p_不存在', null);
    });
  });

  group('删档案', () {
    test('删配置和头像文件，但历史留着', () async {
      final root = _appRoot();
      final controller = await _boot(root: root);
      addTearDown(controller.dispose);

      await controller.setAvatar('p_b', _image(root, '一.png', '图').path);
      final avatar = controller.avatarPathOf(_profile(controller, 'p_b'))!;
      // 造一份历史，确认删档案不碰它
      final history = File('${root.path}/history/p_b/000001.jsonl')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '{"v":1,"n":1,"r":"u","t":"留着我","a":"2026-10-15T00:00:00.000Z"}\n',
        );

      await controller.removeProfile('p_b');

      expect(
        controller.config.profiles.map((p) => p.id),
        isNot(contains('p_b')),
      );
      expect(File(avatar).existsSync(), isFalse);
      expect(
        history.readAsStringSync(),
        contains('留着我'),
        reason: '删一个配置项不该顺手把用户的话删掉',
      );
    });
  });

  group('拿不到应用目录', () {
    test('setAvatar 明确报错，而不是假装存上了', () async {
      final controller = ConversationController(
        engine: FakeVoiceEngine(),
        brainFactory: () => BrainClient(
          client: MockClient((_) async => throw StateError('不该发请求')),
        ),
        // 拿不到目录（模拟降级到内存存储）
        appDir: () async => null,
      );
      addTearDown(controller.dispose);
      await controller.updateConfig(_twoProfiles());

      expect(controller.historyDegraded, isTrue);
      expect(
        controller.avatarPathOf(_profile(controller, 'p_a')),
        isNull,
        reason: '没有目录就没有头像路径，不能拼出一个假路径去读盘',
      );
      await expectLater(
        controller.setAvatar('p_a', '/tmp/随便.png'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}

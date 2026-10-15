import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:pp_friend/src/conversation/message.dart';
import 'package:pp_friend/src/storage/file_message_store.dart';
import 'package:pp_friend/src/storage/memory_message_store.dart';
import 'package:pp_friend/src/storage/message_store.dart';

/// 某个档案最新的那个片子文件。
File _segmentOf(Directory root, String profileId) {
  final files = Directory('${root.path}/history/$profileId')
      .listSync()
      .whereType<File>()
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return files.last;
}

/// 落盘这一层**必须碰真实文件系统**才有意义 —— 全是路径、拼接、编码的活，
/// 用假的文件系统测等于测自己写的假货。所以圈在临时目录里，
/// 绝不碰用户的应用目录。
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pp_friend_history_test');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  FileMessageStore store({int segmentMaxBytes = 1 << 20}) =>
      FileMessageStore(root: root, segmentMaxBytes: segmentMaxBytes);

  group('FileMessageStore 基本读写', () {
    test('追加之后读得回来，seq 从 1 开始连续', () async {
      final s = store();
      await s.append('p1', role: MessageRole.user, text: '你好');
      await s.append('p1', role: MessageRole.assistant, text: '在的');

      final recent = await s.loadRecent('p1');
      expect(recent.map((m) => m.seq), [1, 2]);
      expect(recent.map((m) => m.text), ['你好', '在的']);
      expect(recent.map((m) => m.role), [MessageRole.user, MessageRole.assistant]);
    });

    test('档案之间互不可见', () async {
      final s = store();
      await s.append('p1', role: MessageRole.user, text: '给 p1 的');
      await s.append('p2', role: MessageRole.user, text: '给 p2 的');

      expect((await s.loadRecent('p1')).single.text, '给 p1 的');
      expect((await s.loadRecent('p2')).single.text, '给 p2 的');
      // 新档案从 1 开始，不接着别的档案的号往下发
      expect((await s.loadRecent('p2')).single.seq, 1);
    });

    test('没有历史时返回空列表，不抛异常', () async {
      final s = store();
      expect(await s.loadRecent('never_used'), isEmpty);
      expect(await s.loadOlder('never_used', beforeSeq: 10), isEmpty);
      expect(await s.lastSeq('never_used'), 0);
      expect(await s.sizeBytes('never_used'), 0);
    });

    test('重启之后接着发号，不从头开始', () async {
      await store().append('p1', role: MessageRole.user, text: '第一句');

      // 换一个实例读同一个目录，模拟 App 重启
      final again = store();
      final second = await again.append('p1', role: MessageRole.user, text: '第二句');
      expect(second.seq, 2);
    });

    test('清空之后 seq 重新从 1 开始，别的档案不受影响', () async {
      final s = store();
      await s.append('p1', role: MessageRole.user, text: 'a');
      await s.append('p2', role: MessageRole.user, text: 'b');

      await s.clear('p1');
      expect(await s.loadRecent('p1'), isEmpty);
      expect((await s.loadRecent('p2')).single.text, 'b');
      expect(await s.lastSeq('p1'), 0);
    });
  });

  group('FileMessageStore 文本', () {
    test('换行、引号、emoji、中文逐字往返', () async {
      const nasty = '第一行\n第二行 "引号" 和反斜杠 \\ 还有 emoji 🎤🐷 和制表符\t结尾';
      final s = store();
      await s.append('p1', role: MessageRole.assistant, text: nasty);

      expect((await s.loadRecent('p1')).single.text, nasty);
    });

    test('一万个汉字的长文本字节级往返不乱码', () async {
      // 一条就 30KB，远超任何读缓冲。多字节字符一旦在切分处被劈开就会
      // 变成替换字符，长度对不上。
      final long = '汉' * 10000;
      final s = store();
      await s.append('p1', role: MessageRole.assistant, text: long);

      final back = (await s.loadRecent('p1')).single.text;
      expect(back.length, long.length);
      expect(back, long);
    });
  });

  group('FileMessageStore 分页', () {
    test('loadRecent 只取最近的 limit 条，且保持升序', () async {
      final s = store();
      for (var i = 1; i <= 20; i++) {
        await s.append('p1', role: MessageRole.user, text: '第 $i 句');
      }

      final recent = await s.loadRecent('p1', limit: 5);
      expect(recent.map((m) => m.seq), [16, 17, 18, 19, 20]);
    });

    test('loadOlder 不重不漏，一路翻到底', () async {
      final s = store();
      for (var i = 1; i <= 25; i++) {
        await s.append('p1', role: MessageRole.user, text: '第 $i 句');
      }

      final seen = <int>[];
      var cursor = 26;
      while (true) {
        final page = await s.loadOlder('p1', beforeSeq: cursor, limit: 10);
        if (page.isEmpty) break;
        seen.insertAll(0, page.map((m) => m.seq));
        cursor = page.first.seq;
      }

      expect(seen, List.generate(25, (i) => i + 1));
    });

    test('跨片子翻页也对', () async {
      // 把片子调得很小，强制切出好几个文件来。
      final s = store(segmentMaxBytes: 200);
      for (var i = 1; i <= 30; i++) {
        await s.append('p1', role: MessageRole.user, text: '第 $i 句，凑点长度');
      }

      final files = Directory('${root.path}/history/p1')
          .listSync()
          .whereType<File>()
          .toList();
      expect(files.length, greaterThan(1), reason: '应该切出了多个片子');

      final recent = await s.loadRecent('p1', limit: 100);
      expect(recent.map((m) => m.seq), List.generate(30, (i) => i + 1));

      final older = await s.loadOlder('p1', beforeSeq: 6, limit: 5);
      expect(older.map((m) => m.seq), [1, 2, 3, 4, 5]);
    });

    test('beforeSeq 之前没有东西了就返回空', () async {
      final s = store();
      await s.append('p1', role: MessageRole.user, text: '唯一一句');
      expect(await s.loadOlder('p1', beforeSeq: 1), isEmpty);
    });
  });

  group('FileMessageStore 坏数据', () {
    test('最后一行是半截 JSON 时，前面的照样读得出来', () async {
      final s = store();
      await s.append('p1', role: MessageRole.user, text: '完整的一句');

      // 模拟进程被杀：最后一行只写了一半
      final file = Directory('${root.path}/history/p1')
          .listSync()
          .whereType<File>()
          .single;
      await file.writeAsString('{"v":1,"n":2,"r":"u","t":"写到一半就',
          mode: FileMode.append);

      final recent = await s.loadRecent('p1');
      expect(recent.length, 1);
      expect(recent.single.text, '完整的一句');
    });

    test('中间夹了坏行也继续往下读', () async {
      final s = store();
      for (var i = 1; i <= 3; i++) {
        await s.append('p1', role: MessageRole.user, text: '第 $i 句');
      }

      final file = Directory('${root.path}/history/p1')
          .listSync()
          .whereType<File>()
          .single;
      final lines = await file.readAsLines();
      lines.insert(2, '这不是 JSON');
      lines.insert(3, '[1,2,3]');
      await file.writeAsString('${lines.join('\n')}\n');

      // 坏行跳过，好的三条一条不少
      expect((await s.loadRecent('p1')).map((m) => m.text),
          ['第 1 句', '第 2 句', '第 3 句']);
    });

    test('崩溃留下半行之后接着写，新的一条照样读得出来', () async {
      final s = store();
      await s.append('p1', role: MessageRole.user, text: '完整的一句');

      // 模拟进程被杀：最后一行只写了一半，**而且没有结尾换行**
      final file = _segmentOf(root, 'p1');
      await file.writeAsString('{"v":1,"n":2,"r":"u","t":"写到一半就',
          mode: FileMode.append);

      // 重启之后接着写
      final s2 = store();
      await s2.append('p1', role: MessageRole.user, text: '崩溃之后写的一句');

      final texts = (await s2.loadRecent('p1')).map((m) => m.text).toList();
      expect(
        texts,
        contains('崩溃之后写的一句'),
        reason: '半行没有结尾换行时，新写的这条会被接在同一物理行上一起被丢掉',
      );
      expect(texts, contains('完整的一句'));
      expect(texts, isNot(contains('写到一半就')));
    });

    test('同一个进程里出现半行，下一条也照样读得出来', () async {
      final s = store();
      await s.append('p1', role: MessageRole.user, text: '完整的一句');

      // 上一次写只落了一半（磁盘满、被中断）—— 没有人重启进程
      final file = _segmentOf(root, 'p1');
      await file.writeAsString('{"v":1,"n":2,"r":"u","t":"写到一半就',
          mode: FileMode.append);

      await s.append('p1', role: MessageRole.user, text: '接着写的一句');

      final texts = (await s.loadRecent('p1')).map((m) => m.text).toList();
      expect(
        texts,
        contains('接着写的一句'),
        reason: '不能因为"这次会话里已经检查过尾巴了"就不再看 —— '
            '半行恰恰是上一次失败的写留下的',
      );
      expect(texts, contains('完整的一句'));
    });

    test('段内出现非法 UTF-8 时只丢那一行，不丢整个片子', () async {
      final s = store();
      for (var i = 1; i <= 3; i++) {
        await s.append('p1', role: MessageRole.user, text: '第 $i 句');
      }

      // 崩溃恰好把一条含中文的消息截断在字符中间：
      // "汉" 是 E6 B1 89，留下 E6 B1 就是非法字节序列。
      final file = _segmentOf(root, 'p1');
      final bytes = await file.readAsBytes();
      await file.writeAsBytes([
        ...bytes,
        ...'{"v":1,"n":4,"r":"u","t":"'.codeUnits,
        0xE6, 0xB1,
        ...'\n'.codeUnits,
      ]);

      final recent = await s.loadRecent('p1');
      expect(
        recent.map((m) => m.text),
        ['第 1 句', '第 2 句', '第 3 句'],
        reason: '一行非法字节不该让整个片子读不出来',
      );
    });

    test('读不出来的行会出声，不会悄悄少几条', () async {
      final warnings = <String>[];
      final s = FileMessageStore(root: root, onWarn: warnings.add);
      await s.append('p1', role: MessageRole.user, text: '好的');

      final file = Directory('${root.path}/history/p1')
          .listSync()
          .whereType<File>()
          .single;
      await file.writeAsString('坏行\n', mode: FileMode.append);

      await s.loadRecent('p1');
      expect(warnings, isNotEmpty);
    });
  });

  group('FileMessageStore 并发与占用', () {
    test('并发追加不会把两行插在一起', () async {
      final s = store();
      // 上行回调和轮询回调会同时调 append，故意不 await 就发一堆
      await Future.wait([
        for (var i = 1; i <= 50; i++)
          s.append('p1', role: MessageRole.user, text: '并发 $i'),
      ]);

      final all = await s.loadRecent('p1', limit: 1000);
      expect(all.length, 50);
      expect(all.map((m) => m.seq).toSet().length, 50, reason: 'seq 不能重复');
      expect(all.map((m) => m.seq), List.generate(50, (i) => i + 1));
    });

    test('末尾片子是空的时，发号不回退到 1', () async {
      // 崩溃恰好发生在"片子写满 → 轮转到新片子 → 刚开始写第一条"之间，
      // 会留下一个空片子。此时只看最后一个片子会得到 0，
      // 重启后新消息从 1 开始发号，和第一个片子里的 1 撞号。
      final s = store(segmentMaxBytes: 1);
      for (var i = 1; i <= 3; i++) {
        await s.append('p1', role: MessageRole.user, text: '第 $i 句');
      }
      expect(await s.lastSeq('p1'), 3);

      await File('${root.path}/history/p1/000009.jsonl').writeAsString('');

      final s2 = store(segmentMaxBytes: 1);
      expect(await s2.lastSeq('p1'), 3);
      final next = await s2.append('p1', role: MessageRole.user, text: '崩溃之后');
      expect(next.seq, 4);
    });

    test('sizeBytes 反映实际占用', () async {
      final s = store();
      expect(await s.sizeBytes('p1'), 0);
      for (var i = 1; i <= 10; i++) {
        await s.append('p1', role: MessageRole.user, text: '第 $i 句');
      }
      expect(await s.sizeBytes('p1'), greaterThan(0));
      // 数的是**字节**不是码元：一个汉字在 UTF-8 里占三个字节，
      // 用 String.length 去对会少算三分之二。
      expect(
        await s.sizeBytes('p1'),
        (await s.loadRecent('p1', limit: 100)).fold<int>(
          0,
          (sum, m) => sum + utf8.encode('${jsonEncode(m.toJson())}\n').length,
        ),
      );
    });

    test('档案 id 带斜杠会被挡住，不能写到别处去', () async {
      final s = store();
      expect(
        () => s.append('../跑出去', role: MessageRole.user, text: 'x'),
        throwsArgumentError,
      );
    });
  });

  group('MemoryMessageStore', () {
    test('分页语义和落盘版一致', () async {
      final MessageStore s = MemoryMessageStore();
      for (var i = 1; i <= 25; i++) {
        await s.append('p1', role: MessageRole.user, text: '第 $i 句');
      }

      expect((await s.loadRecent('p1', limit: 5)).map((m) => m.seq),
          [21, 22, 23, 24, 25]);
      expect((await s.loadOlder('p1', beforeSeq: 21, limit: 3)).map((m) => m.seq),
          [18, 19, 20]);
      expect(await s.lastSeq('p1'), 25);

      await s.clear('p1');
      expect(await s.lastSeq('p1'), 0);
      expect(await s.loadRecent('p1'), isEmpty);
    });
  });

  group('ConversationMessage 序列化', () {
    test('往返之后字段不变', () {
      final at = DateTime(2026, 10, 15, 18, 23, 16, 482);
      final message = ConversationMessage(
        role: MessageRole.assistant,
        text: '带换行\n和 "引号"',
        at: at,
        seq: 42,
      );

      final back = ConversationMessage.fromJson(
        (jsonDecode(jsonEncode(message.toJson())) as Map)
            .cast<String, dynamic>(),
      )!;

      expect(back.seq, 42);
      expect(back.role, MessageRole.assistant);
      expect(back.text, message.text);
      expect(back.at.millisecondsSinceEpoch, at.millisecondsSinceEpoch);
      expect(back.at.isUtc, isFalse, reason: '读回来应该是本地时间');
    });

    test('认不出的 role 降级成 note，文字保住', () {
      final back = ConversationMessage.fromJson(const {
        'v': 1,
        'n': 1,
        'r': '未来才有的角色',
        't': '别丢了我',
      })!;
      expect(back.role, MessageRole.note);
      expect(back.text, '别丢了我');
    });

    test('未来版本的行跳过，不按老规矩硬解', () {
      expect(
        ConversationMessage.fromJson(const {
          'v': 99,
          'n': 1,
          'r': 'u',
          't': '未来格式',
        }),
        isNull,
      );
    });

    test('缺 text 的行跳过', () {
      expect(ConversationMessage.fromJson(const {'v': 1, 'n': 1}), isNull);
    });
  });
}

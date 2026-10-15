import 'dart:convert';
import 'dart:io';

import '../conversation/message.dart';
import 'message_store.dart';

/// 一行一条 JSON 的追加写历史。
///
/// ```
/// <root>/history/<profileId>/000001.jsonl
///                          000002.jsonl
/// ```
///
/// 按**大小**切片，不按天。加载最近的历史只需要读最后一个文件；按天的话
/// 单天可能很大，还得再切一层。一个片子 1MB 约合四五千条消息。
///
/// **往上翻一页没有索引可跳**：`loadOlder` 从最新的片子往回逐片读、逐行解析，
/// 才筛得出 `beforeSeq` 之前那几十条。翻得越深，要重解析的片子越多 ——
/// 30 万条量级、往上翻几百页之后，一页是几十毫秒级的同步解析。要优化的话
/// 是"按 seq 猜片子再二分"，现在没做。显示最近一屏（`loadRecent`）和
/// "还有没有更早的"（`ProfileRuntime` 里按 seq 判断）都不受这个影响。
///
/// 片子名零填充递增，所以"最新的那个"就是名字最大的那个，不需要额外的
/// 元数据文件来记 —— 元数据文件自己也会损坏、也会和实际文件对不上。
class FileMessageStore implements MessageStore {
  FileMessageStore({
    required this.root,
    this.segmentMaxBytes = 1 << 20,
    this.onWarn,
  });

  /// 应用私有目录下的子目录，历史都放在它里面。
  final Directory root;

  /// 一个片子多大就换下一个。
  final int segmentMaxBytes;

  /// 读到坏数据时的提示。半截的行是崩溃之后的正常现象，
  /// 但**读不出来这件事本身要能被看见**，不能悄悄少几条。
  final void Function(String message)? onWarn;

  static final RegExp _segmentName = RegExp(r'^(\d{6})\.jsonl$');

  final Map<String, _Profile> _profiles = {};

  _Profile _profile(String id) {
    // id 会直接当目录名用，带斜杠或者 .. 就会写到别处去。
    // 配置那边生成和校验 id，这里是最后一道闸。
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
      throw ArgumentError.value(id, 'profileId', '只允许字母数字和 - _');
    }
    return _profiles.putIfAbsent(
      id,
      () => _Profile(Directory('${root.path}/history/$id')),
    );
  }

  @override
  Future<List<ConversationMessage>> loadRecent(
    String profileId, {
    int limit = 300,
  }) async {
    final collected = <ConversationMessage>[];
    for (final segment in (await _segments(_profile(profileId).dir)).reversed) {
      // 从最新的一片往回攒，攒够就停。片内是升序的，所以往前面插。
      collected.insertAll(0, await _read(segment));
      if (collected.length >= limit) break;
    }
    if (collected.length <= limit) return collected;
    return collected.sublist(collected.length - limit);
  }

  @override
  Future<List<ConversationMessage>> loadOlder(
    String profileId, {
    required int beforeSeq,
    int limit = 50,
  }) async {
    final out = <ConversationMessage>[];
    for (final segment in (await _segments(_profile(profileId).dir)).reversed) {
      final messages = await _read(segment);
      // 片内升序，从尾巴往前走就是 seq 从大到小，正好是要的先后。
      for (var i = messages.length - 1; i >= 0; i--) {
        if (messages[i].seq >= beforeSeq) continue;
        out.add(messages[i]);
        if (out.length >= limit) break;
      }
      if (out.length >= limit) break;
    }
    return out.reversed.toList();
  }

  @override
  Future<ConversationMessage> append(
    String profileId, {
    required MessageRole role,
    required String text,
    DateTime? at,
  }) {
    final profile = _profile(profileId);
    // 同一个档案的写必须串行：上行回调和轮询回调是两条并发的线，
    // 同时追加会把两行插在一起，那个文件以后就再也读不出来了。
    final result = profile.chain.then((_) => _appendNow(profile, role, text, at));
    profile.chain = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<ConversationMessage> _appendNow(
    _Profile profile,
    MessageRole role,
    String text,
    DateTime? at,
  ) async {
    profile.seq ??= await _scanLastSeq(profile);
    final message = ConversationMessage(
      role: role,
      text: text,
      at: at,
      seq: profile.seq! + 1,
    );

    await profile.dir.create(recursive: true);
    final file = await _writableSegment(profile);

    var line = '${jsonEncode(message.toJson())}\n';
    // 文件末尾可能是**没有结尾换行的半行**：上次进程被杀、或者上一次写
    // 只落了一半（磁盘满、被中断）。直接追加会把新的一条接在那个半行屁股
    // 后面，两者合成同一个物理行，于是新写的这条也永远读不出来了 ——
    // 一条残渣带走后面一条好数据。
    //
    // 所以每次都看一眼尾巴。**不看缓存**：缓存指的是"上一次写成功了"，而
    // 半行恰恰是被一次失败的写留下的 —— 缓存刚好会在最需要它的那次说谎。
    // 代价是每次追加多读一个字节，相比写入本身可以忽略。
    if (await _endsWithoutNewline(file)) line = '\n$line';

    // flush 不能省。不 flush 的话进程被杀会丢掉最后几 KB，
    // 而最近几条恰恰是用户最想看的。
    await file.writeAsString(line, mode: FileMode.append, flush: true);
    profile.seq = message.seq;
    return message;
  }

  @override
  Future<int> lastSeq(String profileId) async {
    final profile = _profile(profileId);
    profile.seq ??= await _scanLastSeq(profile);
    return profile.seq!;
  }

  @override
  Future<void> clear(String profileId) {
    final profile = _profile(profileId);
    final result = profile.chain.then((_) async {
      if (await profile.dir.exists()) {
        await profile.dir.delete(recursive: true);
      }
      profile.seq = 0;
    });
    profile.chain = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<int> sizeBytes(String profileId) async {
    var total = 0;
    for (final segment in await _segments(_profile(profileId).dir)) {
      try {
        total += await segment.length();
      } on FileSystemException {
        // 统计占用而已，个别文件读不到就当它不存在，没必要因此报错。
      }
    }
    return total;
  }

  /// 当前该往哪个片子里写。
  ///
  /// 满了就开下一个，没满就接着写最后一个。判断放在写之前而不是写之后，
  /// 所以每个片子的实际大小会在阈值和"阈值加一条"之间，不影响读取。
  Future<File> _writableSegment(_Profile profile) async {
    final segments = await _segments(profile.dir);
    if (segments.isNotEmpty) {
      final last = segments.last;
      if (await last.length() < segmentMaxBytes) return last;
    }
    final next = segments.isEmpty ? 1 : _indexOf(segments.last) + 1;
    return File('${profile.dir.path}/${next.toString().padLeft(6, '0')}.jsonl');
  }

  Future<List<File>> _segments(Directory dir) async {
    if (!await dir.exists()) return const [];
    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is File && _segmentName.hasMatch(_nameOf(entity))) {
        files.add(entity);
      }
    }
    // 零填充固定六位，所以字典序就是数字序。
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  String _nameOf(File file) => file.uri.pathSegments.last;

  int _indexOf(File file) =>
      int.parse(_segmentName.firstMatch(_nameOf(file))!.group(1)!);

  /// 整片读进来逐行解析。
  ///
  /// **不能直接 `readAsLines()`。** 它用严格的 UTF-8 解码，而崩溃在写一条
  /// 含多字节字符（中文、emoji）的消息中途时，文件里会留下被截断的半个字
  /// —— 那可是非法字节，`readAsLines` 会**抛异常**。整片读失败就等于把
  /// 一个片子里几千条历史全丢光，只因为最后那半行。这和"一行坏数据不能把
  /// 整个历史废掉"正好相反，而且中文项目里一定会撞上。
  ///
  /// 所以先读字节、按 `allowMalformed` 解码（坏字节变成替换字符，只毁掉它
  /// 所在的那一行），再按行切。整片读也顺带绕开了另一个坑：按字节窗口反着
  /// 扫会在窗口边界把多字节字符劈开，只在特定长度下出现，极难复现。
  /// 一片最大 1MB，一次读完的代价可以忽略。
  Future<List<ConversationMessage>> _read(File file) async {
    List<String> lines;
    try {
      final bytes = await file.readAsBytes();
      lines = const LineSplitter().convert(utf8.decode(bytes, allowMalformed: true));
    } on FileSystemException catch (e) {
      onWarn?.call('读不了历史文件 ${file.path}：$e');
      return const [];
    }

    final out = <ConversationMessage>[];
    for (final line in lines) {
      if (line.isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map) continue;
        final message =
            ConversationMessage.fromJson(decoded.cast<String, dynamic>());
        if (message != null) out.add(message);
      } catch (_) {
        // 崩溃过一次之后最后一行多半是半截的，这行注定解析不出来。
        // 跳过它继续读后面 —— 一行坏数据不能把整个历史废掉。
        onWarn?.call('历史里有一行读不出来，已跳过');
      }
    }
    return out;
  }

  /// 盘上最后一条的 seq。
  ///
  /// **不能只看最后一个片子。** 崩溃可能恰好发生在"片子写满 → 轮转到新片子
  /// → 刚开始写第一条"之间，留下一个空文件或者只有半行的文件。此时只看它
  /// 会得到 0，重启后新消息就从 1 开始发号，和第一个片子里的 1 撞号 ——
  /// 之后分页和去重全乱。所以要往前找，直到找到真正有数据的那个片子。
  Future<int> _scanLastSeq(_Profile profile) async {
    final segments = await _segments(profile.dir);
    for (final segment in segments.reversed) {
      var max = 0;
      for (final message in await _read(segment)) {
        if (message.seq > max) max = message.seq;
      }
      if (max > 0) return max;
    }
    return 0;
  }
}

/// 一个档案的落盘状态。`chain` 是那把串行写锁。
class _Profile {
  _Profile(this.dir);

  final Directory dir;

  /// 串行写的链子。每次读写都挂在它后面，保证同一个档案不会并发写。
  Future<void> chain = Future<void>.value();

  /// 盘上最后一条的 seq。null 表示还没扫过。
  int? seq;
}

/// 文件末尾是不是一个"没写完的半行"（没有结尾换行）。
///
/// 只读最后一个字节。空文件（或者刚好以换行结尾）都算尾巴干净。
Future<bool> _endsWithoutNewline(File file) async {
  // 第一个片子的第一次追加时文件还不存在（append 模式会把它建出来）
  if (!await file.exists()) return false;
  final raf = await file.open();
  try {
    final length = await raf.length();
    if (length == 0) return false;
    await raf.setPosition(length - 1);
    final last = await raf.read(1);
    return last.isNotEmpty && last[0] != 0x0A;
  } finally {
    await raf.close();
  }
}

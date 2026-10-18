import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;

/// `/human-to-brain` 的返回：人说的话的文本。
class HumanToBrainResult {
  const HumanToBrainResult(this.text);
  final String text;
}

/// `/brain-to-human` 一次响应的前导部分。
sealed class BrainReplyEvent {
  const BrainReplyEvent();
}

/// 这次请求没有真正要说的回复。调用方应当**立刻再发一次**，不停不等。
///
/// [skippedText] 是这条响应排掉的那一条旧消息原文。按契约为空时表示
/// "暂时没内容"；非空表示"这条旧消息已经跳过"——两者都要立刻重发，
/// 区别只在于前者没有账要记。
class BrainEmpty extends BrainReplyEvent {
  const BrainEmpty({this.skippedText});

  final String? skippedText;
}

/// 一条真正要说的回复的前导。
///
/// 前导里**没有音频**：文字先到齐，用户可以先看到；音频是响应 body 里
/// 前导之后的一条**连续 Ogg Opus 流**，由 [BrainReplyStream.audio] 一块
/// 一块给出。
///
/// [text] 是这条回复的完整原文，`<!-- disable voice -->` 段原样保留。
class BrainReplyStart extends BrainReplyEvent {
  const BrainReplyStart({required this.text});

  final String text;
}

/// 一次 `/brain-to-human` 长轮询的句柄。
///
/// [first] 已经到手（empty、一条 skipped 旧消息、或一条真正的回复）。
/// 真正的回复后面跟 [audio]：连续的原始 Ogg Opus 字节，直接喂流式解码器。
/// body 正常结束就是这条回复说完了；没有结束标记。
class BrainReplyStream {
  BrainReplyStream._(this.first, this.audio, this._cancel, this._wasCancelled);

  final BrainReplyEvent first;

  /// 前导之后的原始 Ogg Opus 字节流。只能监听一次；不监听也不会自动
  /// 关闭底层连接，所以调用方要么消费它，要么 [cancel]。
  final Stream<Uint8List> audio;

  final Future<void> Function() _cancel;
  final bool Function() _wasCancelled;

  bool get isEmpty => first is BrainEmpty;

  /// 是不是客户端主动取消的。取消不是网络错误，调用方不要退避。
  bool get wasCancelled => _wasCancelled();

  Future<void> cancel() => _cancel();
}

enum BrainErrorKind {
  /// 401 / 403。**不要重试** —— 那是配置错误，重试只会把它变成持续请求。
  auth,

  /// 网络问题或超时。可以退避重试。
  network,

  /// 5xx。可以退避重试。
  server,

  /// 服务端返回的东西不符合协议。重试大概率还是错。
  protocol,

  /// body 在帧中间断掉，或者长度越界。重新发一次请求即可。
  truncated,
}

class BrainException implements Exception {
  BrainException(this.kind, this.message);

  final BrainErrorKind kind;
  final String message;

  bool get retryable =>
      kind == BrainErrorKind.network ||
      kind == BrainErrorKind.server ||
      kind == BrainErrorKind.truncated;

  @override
  String toString() => 'BrainException(${kind.name}): $message';
}

/// brain API 客户端。
///
/// 我们只用两个端点，语义完全不同：
///  - `/human-to-brain`   有请求才发，一问一答（人说的话 → 文本）
///  - `/brain-to-human` **持续轮询**的分帧流，和前者没有关系
///
/// 服务端还有 `/agent-to-brain` 和 `/brain-to-agent`，那是给 agent 用的，
/// 客户端**没有使用**，所以这里不实现。
///
/// 请求载荷一律是 MessagePack；两个端点的响应形态不同：
///
/// ```
/// /human-to-brain   req { brain_id: string, audio: bin }   // Ogg Opus 16kHz
///                   ret MessagePack { kind: "text", text: string }
/// /brain-to-human   req { brain_id: string, skip_before?: int }
///                   ret [u32 大端文本长度][UTF-8 文本][1 字节 flags][Ogg Opus 流…]
/// ```
///
/// 这个类只负责协议，不管并发、排队和重试 —— 那是调用方的事。
class BrainClient {
  BrainClient({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  /// 这个 client 是不是我们自己造的。
  ///
  /// **注入进来的不能 close**：调用方可能还在别处用它，而且我们也没法
  /// 再造一个一样的。以前这里把注入的实例塞进工厂，abort 之后又"造"出
  /// 同一个已经 close 的对象，后续每个请求都会报 Client is already closed。
  final bool _ownsClient;

  http.Client _client;

  /// 还没结束的 `/brain-to-human` 连接。abort() 要逐个取消。
  final Set<_ReplyConnection> _activeConnections = <_ReplyConnection>{};

  /// 服务端规范没写明 Content-Type。多数实现用 `application/msgpack`，
  /// 少数用 `application/x-msgpack`。**如果对面不认，改这一处即可。**
  static const String msgpackContentType = 'application/msgpack';

  static const Duration _defaultTimeout = Duration(seconds: 120);

  // ---------------------------------------------------------------- /human-to-brain

  /// 上传一段语音，换回文本。
  ///
  /// [oggBytes] 必须是 **Ogg Opus 16kHz**（规范只收这一种）。
  ///
  /// [heardMs] 是**上一段 AI 语音用户实际听到了多少毫秒**（从那一段的开头算），
  /// [unheardText] 是**没被听到的那部分文字**。
  ///
  /// 两个都只在上一段是被打断或被手动清空时才带 —— 它们告诉 brain
  /// 「你哪一段我没听到」。不带的话 brain 会以为自己的话已经讲完，下一轮
  /// 接着「刚才说的那个」讲下去，双方对"已经说过什么"的认知就岔开了 ——
  /// 而用户只能装懂。
  Future<HumanToBrainResult> humanToBrain({
    required String baseUrl,
    required String brainId,
    required Uint8List oggBytes,
    String? token,
    int? heardMs,
    String? unheardText,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final payload = msgpack.serialize(<String, dynamic>{
      'brain_id': brainId,
      'audio': oggBytes,
      // 没被打断就不带这两个键 —— "没值"和"听到了 0ms"是两件事
      'heard_ms': ?heardMs,
      'unheard_text': ?unheardText,
    });

    final map = await _postForMap(
      endpoint: '/human-to-brain',
      baseUrl: baseUrl,
      payload: payload,
      token: token,
      timeout: timeout,
    );

    final kind = map['kind']?.toString();
    if (kind != 'text') {
      throw BrainException(
        BrainErrorKind.protocol,
        '/human-to-brain 期望 kind="text"，收到 ${_describeKind(kind)}',
      );
    }

    return HumanToBrainResult(map['text']?.toString() ?? '');
  }

  // ---------------------------------------------------------------- /brain-to-human

  /// 发起一次长轮询，读完前导后返回句柄。
  ///
  /// **一条响应只回答一件事**：要么是"没内容"（文本长度 0），要么是一条
  /// 被 `skip_before` 跳过的旧消息（flags bit0 = 1，没有音频），要么是
  /// 一条真正要说的回复（后面跟着连续的 Ogg Opus 流）。
  ///
  /// [timeout] **只约束前导**（连接、响应头、文本和 flags 合在一起算）。
  /// 前导到手之后，这条连接可以一直挂到 body 正常结束 —— 回复有多长，
  /// 流就开多久，不再受这个超时影响。
  ///
  /// 前导超时等价于"没内容"：这不是错误，调用方立刻重发即可。
  ///
  /// [skipBefore] 是 UTC epoch 毫秒。早于这个时刻入队的 agent 消息不会
  /// 合成语音，而是带 flags bit0 返回。调用方一直重发，直到拿到真回复。
  Future<BrainReplyStream> brainToHuman({
    required String baseUrl,
    required String brainId,
    String? token,
    int? skipBefore,
    Duration timeout = _defaultTimeout,
  }) async {
    final uri = _resolve(baseUrl, '/brain-to-human');

    final headers = <String, String>{
      'Content-Type': msgpackContentType,
      'Accept': msgpackContentType,
    };
    _applyAuth(headers, token);

    final payload = msgpack.serialize(<String, dynamic>{
      'brain_id': brainId,
      'skip_before': ?skipBefore,
    });

    final conn = _ReplyConnection(onFinished: _finishConnection);
    _activeConnections.add(conn);

    final request =
        http.AbortableStreamedRequest(
            'POST',
            uri,
            abortTrigger: conn.abort.future,
          )
          ..headers.addAll(headers)
          ..contentLength = payload.length;
    request.sink.add(payload);
    unawaited(request.sink.close());

    final deadline = DateTime.now().add(timeout);

    try {
      // 用 Completer 包一层：超时之后底层 send 的迟到错误不能变成
      // unhandled exception。
      final send = Completer<http.StreamedResponse>();
      _client.send(request).then(send.complete).catchError((
        Object error,
        StackTrace stack,
      ) {
        if (!send.isCompleted) send.completeError(error, stack);
      });

      final response = await send.future.timeout(_remaining(deadline));
      await _throwForStatusStreamed('/brain-to-human', response);

      conn.attach(response.stream);

      final open = await conn.openReply(deadline);
      if (open is BrainEmpty) {
        // 没内容 / skipped 旧消息：body 已经没有后续，收掉连接。
        await conn.cancel();
      }
      return conn.toStream(open);
    } on TimeoutException {
      // 前导超时不是错误：和"没内容"一样，立刻重发。
      await conn.cancel();
      return conn.toStream(const BrainEmpty());
    } on http.RequestAbortedException {
      await conn.cancel();
      return conn.toStream(const BrainEmpty());
    } on BrainException {
      await conn.cancel();
      rethrow;
    } catch (e) {
      await conn.cancel();
      throw BrainException(BrainErrorKind.network, '/brain-to-human 网络失败：$e');
    }
  }

  // ---------------------------------------------------------------- 内部

  Future<Map<String, dynamic>> _postForMap({
    required String endpoint,
    required String baseUrl,
    required Uint8List payload,
    String? token,
    required Duration timeout,
  }) async {
    final uri = _resolve(baseUrl, endpoint);

    final headers = <String, String>{
      'Content-Type': msgpackContentType,
      'Accept': msgpackContentType,
    };
    _applyAuth(headers, token);

    final http.Response response;
    try {
      response = await _client
          .post(uri, headers: headers, body: payload)
          .timeout(timeout);
    } on TimeoutException {
      throw BrainException(
        BrainErrorKind.network,
        '$endpoint 超时（${timeout.inSeconds}s）',
      );
    } catch (e) {
      throw BrainException(BrainErrorKind.network, '$endpoint 网络失败：$e');
    }

    _throwForStatus(endpoint, response);

    return _decodeMap(response.bodyBytes, endpoint);
  }

  static Map<String, dynamic> _decodeMap(Uint8List bytes, String endpoint) {
    if (bytes.isEmpty) {
      throw BrainException(BrainErrorKind.protocol, '$endpoint 返回了空 body');
    }

    final Object? decoded;
    try {
      decoded = msgpack.deserialize(bytes);
    } catch (e) {
      throw BrainException(
        BrainErrorKind.protocol,
        '$endpoint 返回的不是合法 MessagePack：$e',
      );
    }

    if (decoded is! Map) {
      throw BrainException(
        BrainErrorKind.protocol,
        '$endpoint 期望一个 map，收到 ${decoded.runtimeType}',
      );
    }

    return decoded.cast<String, dynamic>();
  }

  /// token 为空时**不发** Authorization 头。
  ///
  /// 发一个空的 `Bearer ` 很容易被服务端判成格式错误，
  /// 而"没启用鉴权"本来就不该带这个头。
  static void _applyAuth(Map<String, String> headers, String? token) {
    final trimmed = token?.trim() ?? '';
    if (trimmed.isNotEmpty) {
      headers['Authorization'] = 'Bearer $trimmed';
    }
  }

  static void _throwForStatus(String endpoint, http.Response response) {
    final code = response.statusCode;
    if (code == 200) return;

    if (code == 401 || code == 403) {
      throw BrainException(
        BrainErrorKind.auth,
        '$endpoint 鉴权失败（HTTP $code）：token 无效或缺失',
      );
    }
    if (code >= 500) {
      throw BrainException(
        BrainErrorKind.server,
        '$endpoint 服务端错误（HTTP $code）：${_snippet(response.bodyBytes)}',
      );
    }
    throw BrainException(
      BrainErrorKind.protocol,
      '$endpoint 返回 HTTP $code：${_snippet(response.bodyBytes)}',
    );
  }

  /// 流式响应的非 200 处理。只读前 160 字节做错误提示，然后取消 body。
  static Future<void> _throwForStatusStreamed(
    String endpoint,
    http.StreamedResponse response,
  ) async {
    final code = response.statusCode;
    if (code == 200) return;

    final snippet = await _readSnippet(response.stream);
    if (code == 401 || code == 403) {
      throw BrainException(
        BrainErrorKind.auth,
        '$endpoint 鉴权失败（HTTP $code）：token 无效或缺失',
      );
    }
    if (code >= 500) {
      throw BrainException(
        BrainErrorKind.server,
        '$endpoint 服务端错误（HTTP $code）：$snippet',
      );
    }
    throw BrainException(
      BrainErrorKind.protocol,
      '$endpoint 返回 HTTP $code：$snippet',
    );
  }

  static Future<String> _readSnippet(Stream<List<int>> stream) async {
    // 错误 body 只是给日志用的，不能让它把轮询挂死：代理返回 502 却
    // 一直不写完 body 的情况真的存在。
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    final bytes = <int>[];
    final iterator = StreamIterator<List<int>>(stream);
    try {
      while (true) {
        final hasNext = await iterator.moveNext().timeout(_remaining(deadline));
        if (!hasNext) break;
        bytes.addAll(iterator.current);
        if (bytes.length >= 160) break;
      }
    } catch (_) {
      // 错误 body 读不出来就算了，反正只是给日志用的
    } finally {
      try {
        await iterator.cancel();
      } catch (_) {
        // 已经断了
      }
    }
    return _snippet(Uint8List.fromList(bytes));
  }

  static Uri _resolve(String baseUrl, String path) {
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) {
      throw BrainException(BrainErrorKind.protocol, 'brain 地址为空，先去配置页填');
    }
    return Uri.parse('$base$path');
  }

  static Duration _remaining(DateTime deadline) {
    final left = deadline.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// 错误里带一小段原文。非 200 时 body 可能是 JSON 也可能是纯文本，
  /// 所以只做"能读就读"的宽松解码，不假设格式。
  static String _snippet(Uint8List bytes) {
    if (bytes.isEmpty) return '(空)';
    final text = String.fromCharCodes(bytes.take(160))
        .replaceAll(RegExp(r'[\x00-\x1f]'), '·');
    return bytes.length > 160 ? '$text…' : text;
  }

  static String _describeKind(String? kind) =>
      kind == null ? 'null' : '"$kind"';

  void _finishConnection(_ReplyConnection conn) {
    _activeConnections.remove(conn);
  }

  /// 还有没有在途的请求。打断时用来判断需不需要主动掐断。
  bool get hasPendingRequests => _activeConnections.isNotEmpty;

  /// 中断所有在途请求。
  ///
  /// 服务端的 handler 接口带 `options: { signal: AbortSignal }` ——
  /// 客户端一断开，它就会停止正在合成的内容。不主动断的话，那条流会一直
  /// 挂在服务端，直到它自己超时。
  ///
  /// ⚠️ `Future.timeout()` **做不到这件事**：它只是停止等待，底层请求照跑。
  /// 真正中断只能取消每条连接，再把 client 关掉换一个新的。
  void abort() {
    final active = _activeConnections.toList();
    _activeConnections.clear();
    for (final conn in active) {
      unawaited(conn.cancel());
    }

    if (_ownsClient) {
      try {
        _client.close();
      } catch (_) {
        // 已经关了就算了
      }
      _client = http.Client();
    }
  }

  void dispose() {
    final active = _activeConnections.toList();
    _activeConnections.clear();
    for (final conn in active) {
      unawaited(conn.cancel());
    }
    if (_ownsClient) _client.close();
  }
}

/// 一次 `/brain-to-human` 响应的读取状态。
///
/// 前导格式：`[u32 大端文本长度][UTF-8 文本][1 字节 flags]`，后面直接跟
/// 连续的 Ogg Opus 流。文本长度 0 = 这一轮没内容；flags bit0 = 1 表示
/// 这条是被 `skip_before` 跳过的旧消息，body 里没有音频。
class _ReplyConnection {
  _ReplyConnection({required this.onFinished});

  final void Function(_ReplyConnection conn) onFinished;

  final Completer<void> abort = Completer<void>();
  final _ByteReader _reader = _ByteReader();

  StreamIterator<List<int>>? _iterator;
  bool _cancelled = false;
  bool _finished = false;

  bool get wasCancelled => _cancelled;

  /// 前导里文本的上限。服务端的回复都是短文本；给 8 MiB 已经非常宽松。
  static const int maxTextBytes = 8 * 1024 * 1024;

  void attach(Stream<List<int>> stream) {
    _iterator = StreamIterator<List<int>>(stream);
  }

  /// 读前导，决定这一条响应是什么。
  Future<BrainReplyEvent> openReply(DateTime deadline) async {
    try {
      final head = await _readExact(4, deadline, allowEof: true);
      if (head == null) return const BrainEmpty();

      final length = ByteData.sublistView(head).getUint32(0, Endian.big);
      if (length > maxTextBytes) {
        throw BrainException(
          BrainErrorKind.protocol,
          '前导声称文本有 $length 字节，超过上限 $maxTextBytes',
        );
      }

      final textBytes = length == 0
          ? Uint8List(0)
          : await _readExact(length, deadline);
      if (textBytes == null) {
        throw BrainException(BrainErrorKind.truncated, '前导在文本中间结束');
      }

      final flagsBytes = await _readExact(1, deadline);
      if (flagsBytes == null) {
        throw BrainException(BrainErrorKind.truncated, '前导在 flags 之前结束');
      }

      if (length == 0) return const BrainEmpty();

      final text = utf8.decode(textBytes, allowMalformed: true);
      if ((flagsBytes[0] & 1) != 0) return BrainEmpty(skippedText: text);
      return BrainReplyStart(text: text);
    } on TimeoutException {
      // 前导超时不是错误；调用方当空响应处理并继续轮询。
      return const BrainEmpty();
    }
  }

  /// 读完 [count] 字节。正常 EOF 且一个字节都没读到、并且 [allowEof] 为真
  /// 时返回 null；读到一半断掉算截断。
  Future<Uint8List?> _readExact(
    int count,
    DateTime deadline, {
    bool allowEof = false,
  }) async {
    while (_reader.length < count) {
      final iterator = _iterator;
      if (iterator == null) break;

      final bool hasNext;
      try {
        hasNext = await iterator.moveNext().timeout(
          BrainClient._remaining(deadline),
        );
      } on http.RequestAbortedException {
        if (_cancelled) return null;
        rethrow;
      }

      if (!hasNext) break;
      _reader.add(iterator.current);
    }

    if (_reader.length >= count) return _reader.take(count);
    if (_reader.length == 0 && allowEof) return null;
    throw BrainException(BrainErrorKind.truncated, '响应 body 在前导中间结束');
  }

  /// 前导之后的连续 Ogg Opus 字节。body 结束就是这条回复说完。
  Stream<Uint8List> _audio() async* {
    try {
      final rest = _reader.takeAll();
      if (rest.isNotEmpty) yield rest;

      final iterator = _iterator;
      if (iterator == null) return;

      while (!_cancelled) {
        final bool hasNext;
        try {
          hasNext = await iterator.moveNext();
        } on http.RequestAbortedException {
          if (!_cancelled) rethrow;
          return;
        }
        if (!hasNext) return;

        final chunk = iterator.current;
        if (chunk.isNotEmpty) yield Uint8List.fromList(chunk);
      }
    } finally {
      // 消费方取消、协议错误、解码抛异常都会走到这里。只移除连接不够：
      // StreamIterator 会把底层 HTTP 响应停在"暂停订阅"状态，服务端
      // 还占着连接继续合成。必须显式 cancel 掉它。
      await _releaseIterator();
      _finish();
    }
  }

  BrainReplyStream toStream(BrainReplyEvent first) {
    final audio = first is BrainReplyStart
        ? _audio()
        : const Stream<Uint8List>.empty();
    return BrainReplyStream._(first, audio, cancel, () => _cancelled);
  }

  Future<void> _releaseIterator() async {
    final iterator = _iterator;
    _iterator = null;
    try {
      await iterator?.cancel();
    } catch (_) {
      // 已经断了就算了
    }
  }

  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    if (!abort.isCompleted) abort.complete();
    await _releaseIterator();
    _finish();
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    onFinished(this);
  }
}

/// 一个可以按网络分块追加的字节缓冲。
class _ByteReader {
  final List<int> _buffer = <int>[];

  int get length => _buffer.length;

  void add(List<int> data) {
    if (data.isNotEmpty) _buffer.addAll(data);
  }

  /// 取走前 [count] 字节（调用方保证够）。
  Uint8List take(int count) {
    final out = Uint8List.fromList(_buffer.sublist(0, count));
    _buffer.removeRange(0, count);
    return out;
  }

  /// 把剩下的全部取走并清空。
  Uint8List takeAll() {
    if (_buffer.isEmpty) return Uint8List(0);
    final out = Uint8List.fromList(_buffer);
    _buffer.clear();
    return out;
  }
}

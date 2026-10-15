import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;

/// `/human-to-brain` 的返回：人说的话的文本。
class HumanToBrainResult {
  const HumanToBrainResult(this.text);
  final String text;
}

/// `/brain-to-human` 的返回。
sealed class BrainResponse {
  const BrainResponse();
}

/// 暂时没有可说的。调用方应当**立刻再发一次**，不停不等。
class BrainEmpty extends BrainResponse {
  const BrainEmpty();
}

/// 回复里的一小段：文字 + 它在音频里占多长时间。
///
/// brain 按句给一份这样的账，客户端才能把"播到第几毫秒"翻成"哪几个字
/// 没被听到" —— 客户端手里没有文本与音频的对应关系，光有时间点切不出字。
class BrainSpan {
  const BrainSpan({required this.text, required this.ms});

  final String text;

  /// 这一小段在 [BrainReply.audio] 里占的毫秒数。
  /// 顺序拼起来就是整条音频，**句间不许有没记账的静音**，否则切点会漂。
  final int ms;
}

/// 有内容了：文本进消息流，音频交给原生解码后播放。
class BrainReply extends BrainResponse {
  const BrainReply({
    required this.text,
    required this.audio,
    this.spans = const <BrainSpan>[],
  });

  final String text;

  /// 原始 Ogg Opus 字节。**不在这里解码** ——
  /// 手机上没有纯 Dart 的 Opus 解码器，交给原生 MediaCodec。
  final Uint8List audio;

  /// 按句的时间账。**可选** —— brain 没给就退化成只报 [heardMs]，
  /// 那时客户端说不出"哪几个字"，只能给一个时间点。
  final List<BrainSpan> spans;
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
}

class BrainException implements Exception {
  BrainException(this.kind, this.message);

  final BrainErrorKind kind;
  final String message;

  bool get retryable =>
      kind == BrainErrorKind.network || kind == BrainErrorKind.server;

  @override
  String toString() => 'BrainException(${kind.name}): $message';
}

/// brain API 客户端。
///
/// 我们只用两个端点，语义完全不同：
///  - `/human-to-brain`   有请求才发，一问一答（人说的话 → 文本）
///  - `/brain-to-human` **持续轮询**的阻塞请求，和前者没有关系
///
/// 服务端还有 `/agent-to-brain` 和 `/brain-to-agent`，那是给 agent 用的，
/// 客户端**没有使用**，所以这里不实现。
///
/// **载荷一律是 MessagePack**，不是 JSON、也不是 multipart：
///
/// ```
/// /human-to-brain   req { brain_id: string, audio: bin }   // Ogg Opus 16kHz
///                   ret { kind: "text", text: string }
/// /brain-to-human   req { brain_id: string }
///                   ret { kind: "empty" }
///                     | { kind: "text", text: string, audio: bin }  // 24kHz
/// ```
///
/// 这个类只负责协议，不管并发、排队和重试 —— 那是调用方的事。
class BrainClient {
  BrainClient({http.Client? client})
      : _clientFactory = client == null ? http.Client.new : (() => client),
        _client = client ?? http.Client();

  /// abort() 之后要换一个干净的 client，所以得留着"怎么造"。
  final http.Client Function() _clientFactory;

  http.Client _client;

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
  ///
  /// [unheardText] 要有意义，得 brain 在回复里给了 `spans`：客户端手里
  /// 没有文本与音频的对应关系，光凭 [heardMs] 切不出字来。brain 没给就
  /// 只发 [heardMs]，让服务端自己对。
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

  /// 轮询一次。服务端会阻塞到有内容、或者超时返回 empty。
  Future<BrainResponse> brainToHuman({
    required String baseUrl,
    required String brainId,
    String? token,
    Duration timeout = _defaultTimeout,
  }) async {
    final payload = msgpack.serialize(<String, dynamic>{'brain_id': brainId});

    final map = await _postForMap(
      endpoint: '/brain-to-human',
      baseUrl: baseUrl,
      payload: payload,
      token: token,
      timeout: timeout,
    );

    return parsePayload(map);
  }

  /// 解析 `/brain-to-human` 的载荷。公开出来是为了能单独测。
  static BrainResponse parsePayload(Map<String, dynamic> map) {
    final kind = map['kind']?.toString();

    if (kind == 'empty' || kind == null) return const BrainEmpty();

    if (kind == 'text') {
      final raw = map['audio'];
      return BrainReply(
        text: map['text']?.toString() ?? '',
        // 复制成普通 Uint8List：msgpack 解出来的是内部 view，
        // 跨平台通道传之前统一一下类型，省得踩到实现细节。
        audio: raw is Uint8List ? Uint8List.fromList(raw) : Uint8List(0),
        spans: _parseSpans(map['spans']),
      );
    }

    throw BrainException(
      BrainErrorKind.protocol,
      '未知的 kind：${_describeKind(kind)}（规范里是 empty / text）',
    );
  }

  /// 解析按句的时间账。**宽容处理**：缺了、格式不对就当作没给 ——
  /// 这只是"能报得更细"的加分项，不该因为它让整条回复播不出来。
  static List<BrainSpan> _parseSpans(Object? raw) {
    if (raw is! List) return const <BrainSpan>[];

    final spans = <BrainSpan>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final text = item['text']?.toString();
      final ms = item['ms'];
      if (text == null || text.isEmpty || ms is! num || ms <= 0) continue;
      spans.add(BrainSpan(text: text, ms: ms.toInt()));
    }
    return spans;
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
      // 长轮询超时不是错误，等价于"这次没内容"
      if (endpoint == '/brain-to-human') return <String, dynamic>{'kind': 'empty'};
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

  static Uri _resolve(String baseUrl, String path) {
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) {
      throw BrainException(BrainErrorKind.protocol, 'brain 地址为空，先去配置页填');
    }
    return Uri.parse('$base$path');
  }

  /// 错误里带一小段原文。非 200 时 body 可能是 JSON 也可能是纯文本，
  /// 所以只做"能读就读"的宽松解码，不假设格式。
  static String _snippet(Uint8List bytes) {
    if (bytes.isEmpty) return '(空)';
    final text = String.fromCharCodes(
      bytes.take(160),
    ).replaceAll(RegExp(r'[\x00-\x1f]'), '·');
    return bytes.length > 160 ? '$text…' : text;
  }

  static String _describeKind(String? kind) => kind == null ? 'null' : '"$kind"';

  /// 中断所有在途请求。
  ///
  /// 服务端的 handler 接口带 `options: { signal: AbortSignal }` ——
  /// 客户端一断开，它就会取消自己的工作。不主动断的话，那个长轮询会一直
  /// 挂在服务端，直到它自己超时。
  ///
  /// ⚠️ `Future.timeout()` **做不到这件事**：它只是停止等待，底层请求照跑。
  /// 真正中断只能把 client 关掉，所以这里顺手换一个新的。
  void abort() {
    try {
      _client.close();
    } catch (_) {
      // 已经关了就算了
    }
    _client = _clientFactory();
  }

  void dispose() => _client.close();
}

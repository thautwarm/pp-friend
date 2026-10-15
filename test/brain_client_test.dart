import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;
import 'package:pp_friend/src/brain/brain_client.dart';

/// 构造一个返回 MessagePack 的假客户端。
BrainClient clientReturning(
  Uint8List body, {
  int status = 200,
  String contentType = 'application/msgpack',
  void Function(http.BaseRequest request, List<int> body)? onRequest,
}) {
  return BrainClient(
    client: MockClient.streaming((request, bodyStream) async {
      final requestBody = await bodyStream.toBytes();
      onRequest?.call(request, requestBody);
      return http.StreamedResponse(
        Stream.value(body),
        status,
        headers: {'content-type': contentType},
      );
    }),
  );
}

Uint8List packMap(Map<String, dynamic> map) => msgpack.serialize(map);

void main() {
  // ---------------------------------------------------------------- 字节格式
  //
  // 这组向量和 tools/mock_brain.py --selftest 用的是同一批。
  // Dart 侧用的是第三方 msgpack_dart，Python 侧是手写的 ——
  // **两个独立实现都同意**，才说明字节格式真没写错。
  group('MessagePack 字节格式（与 Python 侧同一组向量）', () {
    const vectors = <Object?, String>{
      null: 'c0',
      true: 'c3',
      false: 'c2',
      0: '00',
      127: '7f',
      128: 'cc80',
      255: 'ccff',
      256: 'cd0100',
      -1: 'ff',
      -32: 'e0',
      -33: 'd0df',
      '': 'a0',
      'a': 'a161',
      '你好': 'a6e4bda0e5a5bd',
      'kind': 'a46b696e64',
    };

    vectors.forEach((value, expectedHex) {
      test('$value → $expectedHex', () {
        expect(msgpack.serialize(value).map(_hex).join(), expectedHex);
      });
    });

    test('空 bin', () {
      expect(msgpack.serialize(Uint8List(0)).map(_hex).join(), 'c400');
    });

    test('{kind: "empty"} 的完整字节', () {
      expect(
        msgpack.serialize({'kind': 'empty'}).map(_hex).join(),
        '81a46b696e64a5656d707479',
      );
    });

    test('bin 解出来是 Uint8List，且字节一一对应', () {
      final raw = Uint8List.fromList(List.generate(300, (i) => (i * 7) % 256));
      final decoded = msgpack.deserialize(msgpack.serialize(raw));
      expect(decoded, isA<Uint8List>());
      expect(decoded, equals(raw));
    });
  });

  group('/brain-to-human 载荷解析', () {
    test('kind=empty → BrainEmpty', () {
      expect(
        BrainClient.parsePayload({'kind': 'empty'}),
        isA<BrainEmpty>(),
      );
    });

    test('kind=text → 文本与音频都取到', () {
      final audio = List<int>.generate(4096, (i) => (i * 31) % 256);
      final parsed = BrainClient.parsePayload({
        'kind': 'text',
        'text': '你好世界',
        'audio': Uint8List.fromList(audio),
      });

      final reply = parsed as BrainReply;
      expect(reply.text, '你好世界');
      expect(reply.audio, equals(audio));
    });

    test('缺 audio 字段时按空音频处理，不崩', () {
      final reply = BrainClient.parsePayload({'kind': 'text', 'text': '只有字'})
          as BrainReply;
      expect(reply.text, '只有字');
      expect(reply.audio, isEmpty);
    });

    test('spans 按句解出来：文字与毫秒', () {
      final reply = BrainClient.parsePayload({
        'kind': 'text',
        'text': '第一句第二句',
        'audio': Uint8List(8),
        'spans': [
          {'text': '第一句', 'ms': 1200},
          {'text': '第二句', 'ms': 900},
        ],
      }) as BrainReply;

      expect(reply.spans, hasLength(2));
      expect(reply.spans[0].text, '第一句');
      expect(reply.spans[0].ms, 1200);
      expect(reply.spans[1].ms, 900);
    });

    test('spans 缺失或残缺都只是"没给"，不该让整条回复播不出来', () {
      // 没给
      final none = BrainClient.parsePayload({
        'kind': 'text',
        'text': 'x',
      }) as BrainReply;
      expect(none.spans, isEmpty);

      // 给了但一条都不合法：没文字、时长不是数、时长为 0
      final junk = BrainClient.parsePayload({
        'kind': 'text',
        'text': 'x',
        'spans': [
          <String, dynamic>{'ms': 100},
          {'text': '没有时长'},
          {'text': '零时长', 'ms': 0},
          'not a map',
        ],
      }) as BrainReply;
      expect(junk.spans, isEmpty);
    });

    test('未知 kind → protocol 错误，信息里点明规范取值', () {
      expect(
        () => BrainClient.parsePayload({'kind': 'weird'}),
        throwsA(
          isA<BrainException>()
              .having((e) => e.kind, 'kind', BrainErrorKind.protocol)
              .having((e) => e.message, 'message', contains('empty / text')),
        ),
      );
    });
  });

  group('/brain-to-human 请求与响应', () {
    test('请求体是 msgpack{brain_id}', () async {
      late List<int> sent;
      final brain = clientReturning(
        packMap({'kind': 'empty'}),
        onRequest: (_, body) => sent = body,
      );

      await brain.brainToHuman(baseUrl: 'http://h:1', brainId: '员工3');
      expect(msgpack.deserialize(Uint8List.fromList(sent)), {'brain_id': '员工3'});
    });

    test('Content-Type / Accept 是 msgpack', () async {
      late http.BaseRequest captured;
      final brain = clientReturning(
        packMap({'kind': 'empty'}),
        onRequest: (req, _) => captured = req,
      );

      await brain.brainToHuman(baseUrl: 'http://h:1', brainId: 'b');
      final ct = captured.headers['Content-Type'] ?? captured.headers['content-type'];
      expect(ct, BrainClient.msgpackContentType);
    });

    test('text + 音频：端到端解出来', () async {
      final audio = List<int>.generate(2048, (i) => (i * 13) % 256);
      final brain = clientReturning(packMap({
        'kind': 'text',
        'text': '嗨',
        'audio': Uint8List.fromList(audio),
      }));

      final reply = await brain.brainToHuman(baseUrl: 'http://h:1', brainId: 'b')
          as BrainReply;
      expect(reply.text, '嗨');
      expect(reply.audio, equals(audio));
    });

    test('音频里含任意字节都不会被误解析', () async {
      // 塞进 CRLF、非法 UTF-8、以及像 JSON 的字节
      final audio = <int>[
        0x0D, 0x0A, 0x0D, 0x0A,
        0xFF, 0xFE, 0x80, 0x81,
        0x7B, 0x22, 0x6B, 0x22, 0x7D, // {"k"}
        0x00, 0x00,
      ];
      final brain = clientReturning(packMap({
        'kind': 'text',
        'text': 'bin',
        'audio': Uint8List.fromList(audio),
      }));

      final reply = await brain.brainToHuman(baseUrl: 'http://h:1', brainId: 'b')
          as BrainReply;
      expect(reply.audio, equals(audio));
    });

    test('非 MessagePack 的 body → protocol 错误', () async {
      final brain = clientReturning(
        Uint8List.fromList(utf8.encode('this is plain text')),
      );
      expect(
        () => brain.brainToHuman(baseUrl: 'http://h:1', brainId: 'b'),
        throwsA(
          isA<BrainException>()
              .having((e) => e.kind, 'kind', BrainErrorKind.protocol),
        ),
      );
    });

    test('空 body → protocol 错误', () async {
      final brain = clientReturning(Uint8List(0));
      expect(
        () => brain.brainToHuman(baseUrl: 'http://h:1', brainId: 'b'),
        throwsA(isA<BrainException>()),
      );
    });
  });

  group('/human-to-brain', () {
    test('请求体是 msgpack{brain_id, audio}，音频原样送出', () async {
      late http.BaseRequest captured;
      late List<int> sent;

      final brain = clientReturning(
        packMap({'kind': 'text', 'text': '你好世界'}),
        onRequest: (req, body) {
          captured = req;
          sent = body;
        },
      );

      final ogg = Uint8List.fromList(List.generate(5000, (i) => (i * 3) % 256));
      final result = await brain.humanToBrain(
        baseUrl: 'http://example.test:8099/',
        brainId: '员工3',
        oggBytes: ogg,
      );

      expect(result.text, '你好世界');
      expect(captured.method, 'POST');
      expect(captured.url.toString(), 'http://example.test:8099/human-to-brain');

      final decoded = msgpack.deserialize(Uint8List.fromList(sent)) as Map;
      expect(decoded['brain_id'], '员工3');
      expect(decoded['audio'], equals(ogg));
    });

    test('heardMs 非空时带 heard_ms，为空时整个键都不出现', () async {
      late List<int> sent;
      final brain = clientReturning(
        packMap({'kind': 'text', 'text': 'x'}),
        onRequest: (_, body) => sent = body,
      );

      await brain.humanToBrain(
        baseUrl: 'http://h:1',
        brainId: 'b',
        oggBytes: Uint8List(4),
        heardMs: 4200,
      );
      var decoded = msgpack.deserialize(Uint8List.fromList(sent)) as Map;
      expect(decoded['heard_ms'], 4200);
      expect(decoded['brain_id'], 'b');

      await brain.humanToBrain(
        baseUrl: 'http://h:1',
        brainId: 'b',
        oggBytes: Uint8List(4),
      );
      decoded = msgpack.deserialize(Uint8List.fromList(sent)) as Map;
      // "没被打断"和"听到 0ms"是两件事，别用 0 冒充缺失
      expect(decoded.containsKey('heard_ms'), isFalse);
    });

    test('unheardText 非空时带 unheard_text，为空时整个键都不出现', () async {
      late List<int> sent;
      final brain = clientReturning(
        packMap({'kind': 'text', 'text': 'x'}),
        onRequest: (_, body) => sent = body,
      );

      await brain.humanToBrain(
        baseUrl: 'http://h:1',
        brainId: 'b',
        oggBytes: Uint8List(4),
        heardMs: 4200,
        unheardText: '后面这句你白说了',
      );
      var decoded = msgpack.deserialize(Uint8List.fromList(sent)) as Map;
      expect(decoded['unheard_text'], '后面这句你白说了');
      expect(decoded['heard_ms'], 4200);

      await brain.humanToBrain(
        baseUrl: 'http://h:1',
        brainId: 'b',
        oggBytes: Uint8List(4),
      );
      decoded = msgpack.deserialize(Uint8List.fromList(sent)) as Map;
      expect(decoded.containsKey('unheard_text'), isFalse);
    });

    test('返回的 kind 不是 text → protocol 错误', () async {
      final brain = clientReturning(packMap({'kind': 'empty'}));
      expect(
        () => brain.humanToBrain(
          baseUrl: 'http://h:1',
          brainId: 'b',
          oggBytes: Uint8List(8),
        ),
        throwsA(
          isA<BrainException>()
              .having((e) => e.kind, 'kind', BrainErrorKind.protocol)
              .having((e) => e.message, 'message', contains('kind="text"')),
        ),
      );
    });

    test('baseUrl 末尾多余斜杠不会拼出双斜杠', () async {
      late http.BaseRequest captured;
      final brain = clientReturning(
        packMap({'kind': 'text', 'text': 'x'}),
        onRequest: (req, _) => captured = req,
      );

      await brain.humanToBrain(
        baseUrl: 'http://h:1///',
        brainId: 'b',
        oggBytes: Uint8List(4),
      );
      expect(captured.url.toString(), 'http://h:1/human-to-brain');
    });

    test('地址为空时立刻报错，而不是发一个畸形请求', () async {
      final brain = clientReturning(packMap({'kind': 'text', 'text': 'x'}));
      expect(
        () => brain.humanToBrain(
          baseUrl: '  ',
          brainId: 'b',
          oggBytes: Uint8List(4),
        ),
        throwsA(isA<BrainException>()),
      );
    });
  });

  group('鉴权', () {
    test('token 为空时不发 Authorization 头', () async {
      late http.BaseRequest captured;
      final brain = clientReturning(
        packMap({'kind': 'empty'}),
        onRequest: (req, _) => captured = req,
      );

      await brain.brainToHuman(baseUrl: 'http://h:1', brainId: 'b', token: '   ');
      expect(captured.headers.containsKey('authorization'), isFalse);
      expect(captured.headers.containsKey('Authorization'), isFalse);
    });

    test('token 非空时发 Bearer，且去掉首尾空白', () async {
      late http.BaseRequest captured;
      final brain = clientReturning(
        packMap({'kind': 'empty'}),
        onRequest: (req, _) => captured = req,
      );

      await brain.brainToHuman(
        baseUrl: 'http://h:1',
        brainId: 'b',
        token: ' s3cret ',
      );
      final auth = captured.headers['Authorization'] ??
          captured.headers['authorization'];
      expect(auth, 'Bearer s3cret');
    });

    test('401 → auth 错误，且不可重试', () async {
      final brain = clientReturning(
        Uint8List.fromList(utf8.encode('unauthorized')),
        status: 401,
      );
      expect(
        () => brain.brainToHuman(baseUrl: 'http://h:1', brainId: 'b'),
        throwsA(
          isA<BrainException>()
              .having((e) => e.kind, 'kind', BrainErrorKind.auth)
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
    });

    test('500 → server 错误，可重试', () async {
      final brain = clientReturning(
        Uint8List.fromList(utf8.encode('boom')),
        status: 500,
      );
      expect(
        () => brain.brainToHuman(baseUrl: 'http://h:1', brainId: 'b'),
        throwsA(
          isA<BrainException>()
              .having((e) => e.kind, 'kind', BrainErrorKind.server)
              .having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
    });
  });

  group('abort', () {
    test('abort() 会关掉底层 client', () async {
      var closeCount = 0;
      final inner = MockClient(
        (_) async => http.Response.bytes(packMap({'kind': 'empty'}), 200),
      );
      final tracking = _TrackingClient(inner, () => closeCount++);
      final brain = BrainClient(client: tracking);

      await brain.brainToHuman(baseUrl: 'http://h:1', brainId: 'b');
      expect(closeCount, 0);

      brain.abort();
      expect(closeCount, 1, reason: 'abort() 必须真的关掉 client');

      // abort 之后内部换了新 client，还能继续用
      await brain.brainToHuman(baseUrl: 'http://h:1', brainId: 'b');
    });

    test('重复 abort 不抛异常', () {
      final brain = BrainClient(
        client: MockClient((_) async => http.Response.bytes(Uint8List(0), 200)),
      );
      brain.abort();
      brain.abort();
    });
  });
}

/// 记录 close() 有没有被调用。
class _TrackingClient extends http.BaseClient {
  _TrackingClient(this._inner, this._onClose);

  final http.Client _inner;
  final void Function() _onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() {
    _onClose();
    _inner.close();
  }
}

String _hex(int b) => b.toRadixString(16).padLeft(2, '0');

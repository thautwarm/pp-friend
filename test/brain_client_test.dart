import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;
import 'package:pp_friend/src/brain/brain_client.dart';

import 'support/framed_brain.dart';

/// 构造一个返回整包 MessagePack 的假客户端（`/human-to-brain` 用）。
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

Future<Uint8List> collectAudio(BrainReplyStream stream) async {
  final out = BytesBuilder(copy: false);
  await for (final chunk in stream.audio) {
    out.add(chunk);
  }
  return out.takeBytes();
}

void main() {
  // ---------------------------------------------------------------- 字节格式
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

  group('/brain-to-human 前导 + Ogg 流', () {
    test('文本先到，后面是连续音频；前导被拆碎也能拼回来', () async {
      final ogg = Uint8List.fromList(List.generate(5000, (i) => i % 251));
      final body = speechBody('你好。', ogg: ogg);
      final chunks = <Uint8List>[
        body.sublist(0, 2),
        body.sublist(2, 5),
        body.sublist(5, 7),
        body.sublist(7, 300),
        body.sublist(300),
      ];

      final stream = await streamingBrain(
        chunks,
      ).brainToHuman(baseUrl: 'http://h:1', brainId: 'b');

      expect(stream.first, isA<BrainReplyStart>());
      expect((stream.first as BrainReplyStart).text, '你好。');
      expect(await collectAudio(stream), ogg);
    });

    test('音频和网络分块无关：所有字节按顺序交出去', () async {
      final ogg = Uint8List.fromList(List.generate(37, (i) => i));
      final body = speechBody('说点什么。', ogg: ogg);
      final stream = await streamingBrain(<Uint8List>[
        Uint8List.fromList(body.sublist(0, 9)),
        Uint8List.fromList(body.sublist(9, 10)),
        Uint8List.fromList(body.sublist(10)),
      ]).brainToHuman(baseUrl: 'http://h:1', brainId: 'b');

      expect((stream.first as BrainReplyStart).text, '说点什么。');
      expect(await collectAudio(stream), ogg);
    });

    test('文本长度为 0 → BrainEmpty，而且没有音频', () async {
      final stream = await singleBody(
        emptyBody(),
      ).brainToHuman(baseUrl: 'http://h:1', brainId: 'b');

      expect(stream.first, isA<BrainEmpty>());
      expect((stream.first as BrainEmpty).skippedText, isNull);
      expect(await collectAudio(stream), isEmpty);
    });

    test('flags bit0 → 带 skippedText 的 BrainEmpty，没有音频', () async {
      final stream = await singleBody(
        speechBody('旧消息一。', skipped: true),
      ).brainToHuman(baseUrl: 'http://h:1', brainId: 'b');

      final first = stream.first as BrainEmpty;
      expect(first.skippedText, '旧消息一。');
      expect(await collectAudio(stream), isEmpty);
    });

    test('空 body（一个字节都没有）按 BrainEmpty 处理', () async {
      final stream = await singleBody(
        Uint8List(0),
      ).brainToHuman(baseUrl: 'http://h:1', brainId: 'b');

      expect(stream.first, isA<BrainEmpty>());
      expect(await collectAudio(stream), isEmpty);
    });

    test('文本长度超过上限 → protocol 错误', () async {
      final body = Uint8List(5);
      ByteData.sublistView(
        body,
      ).setUint32(0, 9 * 1024 * 1024, Endian.big);

      await expectLater(
        singleBody(body).brainToHuman(baseUrl: 'http://h:1', brainId: 'b'),
        throwsA(
          isA<BrainException>().having(
            (e) => e.kind,
            'kind',
            BrainErrorKind.protocol,
          ),
        ),
      );
    });

    test('前导在文本中间结束 → truncated', () async {
      final body = speechBody('你好。').sublist(0, 6);
      await expectLater(
        singleBody(
          Uint8List.fromList(body),
        ).brainToHuman(baseUrl: 'http://h:1', brainId: 'b'),
        throwsA(
          isA<BrainException>().having(
            (e) => e.kind,
            'kind',
            BrainErrorKind.truncated,
          ),
        ),
      );
    });

    test('前导在 flags 之前结束 → truncated', () async {
      final body = speechBody('你好。').sublist(0, 7);
      await expectLater(
        singleBody(
          Uint8List.fromList(body),
        ).brainToHuman(baseUrl: 'http://h:1', brainId: 'b'),
        throwsA(
          isA<BrainException>().having(
            (e) => e.kind,
            'kind',
            BrainErrorKind.truncated,
          ),
        ),
      );
    });

    test('前导迟迟不来 → BrainEmpty，不是错误', () async {
      final ctrl = StreamController<List<int>>();
      addTearDown(ctrl.close);
      final brain = BrainClient(
        client: MockClient.streaming(
          (request, bodyStream) async =>
              http.StreamedResponse(ctrl.stream, 200),
        ),
      );

      final stream = await brain.brainToHuman(
        baseUrl: 'http://h:1',
        brainId: 'b',
        timeout: const Duration(milliseconds: 60),
      );

      expect(stream.first, isA<BrainEmpty>());
      expect(await collectAudio(stream), isEmpty);
    });

    test('前导到手之后不再受 timeout 约束', () async {
      final ctrl = StreamController<List<int>>();
      addTearDown(ctrl.close);
      final brain = BrainClient(
        client: MockClient.streaming(
          (request, bodyStream) async =>
              http.StreamedResponse(ctrl.stream, 200),
        ),
      );

      final future = brain.brainToHuman(
        baseUrl: 'http://h:1',
        brainId: 'b',
        timeout: const Duration(milliseconds: 60),
      );
      ctrl.add(speechBody('慢慢来。'));
      final stream = await future;
      expect((stream.first as BrainReplyStart).text, '慢慢来。');

      // 超过 timeout 之后音频还可以继续到。
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final audio = <Uint8List>[];
      final done = () async {
        await for (final chunk in stream.audio) {
          audio.add(chunk);
        }
      }();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      ctrl.add(Uint8List.fromList(const <int>[1, 2, 3]));
      await ctrl.close();
      await done;
      expect(audio, [
        Uint8List.fromList(const <int>[1, 2, 3]),
      ]);
    });

    test('cancel() 之后音频流结束，且 wasCancelled 为 true', () async {
      final ctrl = StreamController<List<int>>();
      addTearDown(ctrl.close);
      final brain = BrainClient(
        client: MockClient.streaming(
          (request, bodyStream) async =>
              http.StreamedResponse(ctrl.stream, 200),
        ),
      );

      final future = brain.brainToHuman(baseUrl: 'http://h:1', brainId: 'b');
      ctrl.add(speechBody('说一半。'));
      final stream = await future;
      expect(stream.first, isA<BrainReplyStart>());

      final collected = collectAudio(stream);
      await stream.cancel();
      expect(stream.wasCancelled, isTrue);
      expect(await collected, isEmpty);
    });

    test('skip_before 只在传入时出现', () async {
      late List<int> sent;
      final brain = singleBody(
        emptyBody(),
        onRequest: (_, body) => sent = body,
      );

      await brain.brainToHuman(
        baseUrl: 'http://h:1',
        brainId: 'b',
        skipBefore: 1234567890,
      );
      var decoded = msgpack.deserialize(Uint8List.fromList(sent)) as Map;
      expect(decoded['skip_before'], 1234567890);

      await brain.brainToHuman(baseUrl: 'http://h:1', brainId: 'b');
      decoded = msgpack.deserialize(Uint8List.fromList(sent)) as Map;
      expect(decoded.containsKey('skip_before'), isFalse);
    });
  });

  group('/brain-to-human 请求', () {
    test('请求体是 msgpack{brain_id}', () async {
      late List<int> sent;
      final brain = singleBody(
        emptyBody(),
        onRequest: (_, body) => sent = body,
      );

      await brain.brainToHuman(baseUrl: 'http://h:1', brainId: '员工3');
      expect(msgpack.deserialize(Uint8List.fromList(sent)), {
        'brain_id': '员工3',
      });
    });

    test('Content-Type / Accept 是 msgpack', () async {
      late http.BaseRequest captured;
      final brain = singleBody(
        emptyBody(),
        onRequest: (req, _) => captured = req,
      );

      await brain.brainToHuman(baseUrl: 'http://h:1', brainId: 'b');
      final ct =
          captured.headers['Content-Type'] ?? captured.headers['content-type'];
      expect(ct, BrainClient.msgpackContentType);
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
      expect(
        captured.url.toString(),
        'http://example.test:8099/human-to-brain',
      );

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
      final brain = singleBody(
        emptyBody(),
        onRequest: (req, _) => captured = req,
      );

      await brain.brainToHuman(
        baseUrl: 'http://h:1',
        brainId: 'b',
        token: '   ',
      );
      expect(captured.headers.containsKey('authorization'), isFalse);
      expect(captured.headers.containsKey('Authorization'), isFalse);
    });

    test('token 非空时发 Bearer，且去掉首尾空白', () async {
      late http.BaseRequest captured;
      final brain = singleBody(
        emptyBody(),
        onRequest: (req, _) => captured = req,
      );

      await brain.brainToHuman(
        baseUrl: 'http://h:1',
        brainId: 'b',
        token: ' s3cret ',
      );
      final auth =
          captured.headers['Authorization'] ??
          captured.headers['authorization'];
      expect(auth, 'Bearer s3cret');
    });

    test('401 → auth 错误，且不可重试', () async {
      final brain = singleBody(emptyBody(), status: 401);
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
      final brain = singleBody(emptyBody(), status: 500);
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
    test('abort() 取消在途流，但不会关掉注入的 client', () async {
      var closeCount = 0;
      final inner = MockClient(
        (_) async => http.Response.bytes(emptyBody(), 200),
      );
      final tracking = _TrackingClient(inner, () => closeCount++);
      final brain = BrainClient(client: tracking);

      final stream = await brain.brainToHuman(
        baseUrl: 'http://h:1',
        brainId: 'b',
      );
      expect(closeCount, 0);

      brain.abort();
      expect(closeCount, 0, reason: '注入的 client 归调用方所有，不能替它关');
      expect(stream.wasCancelled, isTrue);

      // client 没被关，abort 之后还能继续用
      final again = await brain.brainToHuman(
        baseUrl: 'http://h:1',
        brainId: 'b',
      );
      expect(again.first, isA<BrainEmpty>());
    });

    test('自己造的 client 重复 abort / dispose 不抛异常', () {
      final brain = BrainClient();
      brain.abort();
      brain.abort();
      brain.dispose();
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

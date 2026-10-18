import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pp_friend/src/brain/brain_client.dart';

/// `/brain-to-human` 的响应体：
/// `[u32 大端文本长度][UTF-8 文本][1 字节 flags][Ogg Opus 流…]`。
///
/// [ogg] 是前导之后的原始字节；测试里内容无所谓，BrainClient 只负责
/// 原样交出去，解码是引擎的事。
Uint8List speechBody(
  String text, {
  bool skipped = false,
  List<int> ogg = const <int>[],
}) {
  final textBytes = utf8.encode(text);
  final out = Uint8List(4 + textBytes.length + 1 + ogg.length);
  ByteData.sublistView(out).setUint32(0, textBytes.length, Endian.big);
  out.setRange(4, 4 + textBytes.length, textBytes);
  out[4 + textBytes.length] = skipped ? 1 : 0;
  out.setRange(5 + textBytes.length, out.length, ogg);
  return out;
}

/// 没内容：文本长度 0，flags 0。
Uint8List emptyBody() =>
    Uint8List.fromList(const <int>[0, 0, 0, 0, 0]);

/// 返回给定 chunk 序列的 BrainClient。
///
/// 每个 chunk 就是一个网络分块，测试可以故意把前导、文本、flags 或 Ogg
/// 流拆到不同 chunk 里。
BrainClient streamingBrain(
  List<Uint8List> chunks, {
  int status = 200,
  void Function(http.BaseRequest request, List<int> body)? onRequest,
}) {
  return BrainClient(
    client: MockClient.streaming((request, bodyStream) async {
      final body = await bodyStream.toBytes();
      onRequest?.call(request, body);
      return http.StreamedResponse(
        Stream<List<int>>.fromIterable(chunks),
        status,
        headers: {'content-type': 'application/octet-stream'},
      );
    }),
  );
}

/// 单 chunk 的响应。
BrainClient singleBody(
  Uint8List body, {
  int status = 200,
  void Function(http.BaseRequest request, List<int> body)? onRequest,
}) {
  return streamingBrain([body], status: status, onRequest: onRequest);
}

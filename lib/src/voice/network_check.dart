import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// 这个 host 是不是落在本地网络里（需要 macOS 本地网络权限的那类地址）。
///
/// 只认 IP 字面量、localhost 和 `.local`；域名解析结果这里看不到，
/// 公网域名一律当作不需要本地网络权限。
bool looksLikeLocalNetworkHost(String host) {
  final lower = host.toLowerCase();
  if (lower == 'localhost' || lower.endsWith('.local')) return true;
  final addr = InternetAddress.tryParse(host);
  if (addr == null) return false;
  if (addr.isLoopback || addr.isLinkLocal) return true;
  final b = addr.rawAddress;
  if (addr.type == InternetAddressType.IPv4) {
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168);
  }
  if (addr.type == InternetAddressType.IPv6) {
    // fc00::/7（ULA）和 fe80::/10（link-local）。
    return (b[0] & 0xfe) == 0xfc || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80);
  }
  return false;
}

/// 真的对 brain 发一次 HTTP 请求的结果。
///
/// 本地网络的 TCP 探测只能证明"能建立连接"，证明不了 Dart 这一侧的 HTTP
/// 链路是通的；上传失败但探测显示可连接，就是这两层之间的差别。
class BrainHttpCheck {
  const BrainHttpCheck.ok(this.statusCode)
    : ok = true,
      error = null,
      invalid = false,
      timedOut = false;

  const BrainHttpCheck.invalidUrl()
    : ok = false,
      statusCode = null,
      error = null,
      invalid = true,
      timedOut = false;

  const BrainHttpCheck.timeout()
    : ok = false,
      statusCode = null,
      error = null,
      invalid = false,
      timedOut = true;

  const BrainHttpCheck.failed(this.error)
    : ok = false,
      statusCode = null,
      invalid = false,
      timedOut = false;

  final bool ok;
  final int? statusCode;
  final String? error;

  /// 地址本身不合法（不是 http/https，或者没有 host）。
  final bool invalid;

  /// 请求超时。
  final bool timedOut;
}

/// 对 brain 的根路径发一个 GET。
///
/// 只要收到任何 HTTP 状态码（包括 404 —— 根路径本来就可以没有内容），
/// 就说明 Dart 的 HTTP 链路是通的。失败时把异常原文带回去，方便直接
/// 看出是 DNS、连接被拒、超时还是别的原因。
Future<BrainHttpCheck> checkBrainHttp(
  String baseUrl, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final uri = Uri.tryParse(baseUrl.trim());
  if (uri == null ||
      uri.host.isEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    return const BrainHttpCheck.invalidUrl();
  }

  try {
    final response = await http.get(uri).timeout(timeout);
    return BrainHttpCheck.ok(response.statusCode);
  } on TimeoutException {
    return const BrainHttpCheck.timeout();
  } catch (e) {
    return BrainHttpCheck.failed('$e');
  }
}

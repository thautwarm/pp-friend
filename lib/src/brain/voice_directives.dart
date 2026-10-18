/// `<!-- disable voice -->` / `<!-- enable voice -->` 之间的段不合成语音。
///
/// 服务端在合成前会用同样的规则剥掉这些段（`Format.forTts`）。客户端在
/// 上报 `unheard_text` 时也要剥：那些字用户本来就不该听到，带着标记上报
/// 等于告诉 brain「你没听到一段指令」。
///
/// 规则与服务端保持一致，尤其是坏数据：
///  - 一段里可以有多组；
///  - 开着的 disable 一直没等到 enable，剩下的全部不念；
///  - 落单的 enable 当普通标记丢掉。
String spokenText(String text) {
  const off = '<!-- disable voice -->';
  const on = '<!-- enable voice -->';

  final out = StringBuffer();
  var muted = false;
  var rest = text;

  while (true) {
    final offAt = rest.indexOf(off);
    final onAt = rest.indexOf(on);
    final cut = offAt == -1
        ? onAt
        : onAt == -1
        ? offAt
        : (offAt < onAt ? offAt : onAt);
    if (cut == -1) break;

    if (!muted) out.write(rest.substring(0, cut));
    muted = cut == offAt;
    rest = rest.substring(cut + (muted ? off.length : on.length));
  }

  if (!muted) out.write(rest);
  return out.toString();
}

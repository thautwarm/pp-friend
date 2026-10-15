import 'dart:math' as math;
import 'dart:typed_data';

/// PCM16 小端单声道的公用工具。
///
/// 全部集中在这里，是因为"字节序"和"采样率"这两个东西一旦在不同地方
/// 各写一遍，就一定会有一处写反。

const int pcm16Min = -32768;
const int pcm16Max = 32767;

/// 计算 RMS 电平（dBFS）。静默返回 -120。
double rmsDb(Uint8List pcm16le) {
  final frames = pcm16le.length ~/ 2;
  if (frames == 0) return -120;

  final data = ByteData.sublistView(pcm16le);
  var sum = 0.0;
  for (var i = 0; i < frames; i++) {
    final v = data.getInt16(i * 2, Endian.little) / 32768.0;
    sum += v * v;
  }
  final rms = math.sqrt(sum / frames);
  return rms <= 1e-7 ? -120 : 20 * (math.log(rms) / math.ln10);
}

/// 线性插值重采样。
///
/// 用途很具体：brain 返回的 OGG/Opus 解出来通常是 48kHz，
/// 而原生引擎选定的可能是 16kHz。
///
/// 线性插值不是高质量重采样（降采样前没有抗混叠低通），对语音够用；
/// 真要提升，正确做法是把重采样放进原生侧。
Uint8List resamplePcm16(
  Uint8List input, {
  required int fromRate,
  required int toRate,
}) {
  if (fromRate == toRate || input.isEmpty) return input;

  final inFrames = input.length ~/ 2;
  if (inFrames == 0) return Uint8List(0);

  final outFrames = (inFrames * toRate / fromRate).round();
  final out = Uint8List(outFrames * 2);
  final src = ByteData.sublistView(input);
  final dst = ByteData.sublistView(out);
  final step = fromRate / toRate;

  for (var i = 0; i < outFrames; i++) {
    final pos = i * step;
    final i0 = pos.floor();
    final i1 = math.min(i0 + 1, inFrames - 1);
    final frac = pos - i0;
    final s0 = src.getInt16(i0 * 2, Endian.little);
    final s1 = src.getInt16(i1 * 2, Endian.little);
    final value = (s0 + (s1 - s0) * frac).round().clamp(pcm16Min, pcm16Max);
    dst.setInt16(i * 2, value, Endian.little);
  }

  return out;
}

/// 多声道交织 → 单声道（取平均）。原生引擎只吃单声道。
Uint8List downmixToMono(Uint8List pcm16le, int channels) {
  if (channels <= 1) return pcm16le;
  final frames = pcm16le.length ~/ (2 * channels);
  if (frames == 0) return Uint8List(0);

  final src = ByteData.sublistView(pcm16le);
  final out = Uint8List(frames * 2);
  final dst = ByteData.sublistView(out);

  for (var i = 0; i < frames; i++) {
    var sum = 0;
    for (var c = 0; c < channels; c++) {
      sum += src.getInt16((i * channels + c) * 2, Endian.little);
    }
    dst.setInt16(
      i * 2,
      (sum ~/ channels).clamp(pcm16Min, pcm16Max),
      Endian.little,
    );
  }
  return out;
}

/// 把原生解码出来的音频转成播放引擎要的格式：单声道、引擎采样率。
///
/// 服务端返回的 OGG/Opus 解出来通常是 48kHz，而引擎选定的是 16kHz；
/// 不转直接推过去会**变速**（音调偏低、语速变慢），是个很隐蔽的坑。
Uint8List toPlaybackPcm(
  Uint8List pcm16le, {
  required int sourceRate,
  required int sourceChannels,
  required int targetRate,
}) {
  var pcm = downmixToMono(pcm16le, sourceChannels);
  if (sourceRate != targetRate) {
    pcm = resamplePcm16(pcm, fromRate: sourceRate, toRate: targetRate);
  }
  return pcm;
}

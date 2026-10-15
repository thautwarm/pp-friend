import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pp_friend/src/audio/pcm_utils.dart';

Uint8List sine({
  required int sampleRate,
  required int frames,
  double hz = 440,
  double amplitude = 0.5,
}) {
  final bytes = Uint8List(frames * 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < frames; i++) {
    final v = math.sin(2 * math.pi * hz * i / sampleRate) * amplitude;
    data.setInt16(i * 2, (v * 32767).round(), Endian.little);
  }
  return bytes;
}

void main() {
  group('rmsDb', () {
    test('静默是 -120', () {
      expect(rmsDb(Uint8List(200)), -120);
    });

    test('满幅正弦约 -9dBFS', () {
      // 正弦波 RMS = 幅度/√2 → 20*log10(0.5/1.414) ≈ -9.03
      final db = rmsDb(sine(sampleRate: 16000, frames: 1600, amplitude: 0.5));
      expect(db, closeTo(-9.0, 0.5));
    });
  });

  group('resamplePcm16', () {
    test('24000 → 16000 帧数按比例缩小', () {
      final input = sine(sampleRate: 24000, frames: 2400); // 100ms
      final output = resamplePcm16(input, fromRate: 24000, toRate: 16000);
      expect(output.length ~/ 2, 1600); // 100ms @ 16k
    });

    test('相同采样率原样返回', () {
      final input = sine(sampleRate: 16000, frames: 320);
      expect(identical(resamplePcm16(input, fromRate: 16000, toRate: 16000), input), isTrue);
    });

    test('空输入不炸', () {
      expect(resamplePcm16(Uint8List(0), fromRate: 24000, toRate: 16000).length, 0);
    });

    test('幅度基本保持（不引入增益）', () {
      final input = sine(sampleRate: 24000, frames: 2400, amplitude: 0.5);
      final output = resamplePcm16(input, fromRate: 24000, toRate: 16000);
      expect(rmsDb(output), closeTo(rmsDb(input), 1.0));
    });
  });

  group('downmixToMono', () {
    test('左右声道取平均', () {
      // 两帧：L=1000,R=2000 / L=-4000,R=-2000
      final stereo = Uint8List(8);
      final view = ByteData.sublistView(stereo);
      view.setInt16(0, 1000, Endian.little);
      view.setInt16(2, 2000, Endian.little);
      view.setInt16(4, -4000, Endian.little);
      view.setInt16(6, -2000, Endian.little);

      final mono = downmixToMono(stereo, 2);
      final out = ByteData.sublistView(mono);
      expect(mono.length, 4);
      expect(out.getInt16(0, Endian.little), 1500);
      expect(out.getInt16(2, Endian.little), -3000);
    });
  });
}

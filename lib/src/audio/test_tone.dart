import 'dart:math' as math;
import 'dart:typed_data';

/// "类语音"测试音生成器。
///
/// 波形是基频 + 两次谐波 + 4.2Hz 调幅，比纯正弦更接近人声的频谱包络，
/// 对回声消除器更有代表性。听着像风琴，但这正是它有用的地方：
/// 频谱能量集中、稳定，AEC 该消掉的东西一目了然。
///
/// 两个地方用它：
///  - mock TTS —— 没有真实 TTS 时让链路能跑通
///  - AEC 自测按钮 —— 不依赖 STT，直接循环播放，用于对比调试面板里的各项开关
class TestToneGenerator {
  const TestToneGenerator({
    this.fundamentalHz = 165,
    this.amplitude = 0.30,
    this.fadeMs = 50,
  });

  final double fundamentalHz;
  final double amplitude;
  final int fadeMs;

  /// 渲染 `[startFrame, startFrame + frames)` 区间。
  ///
  /// [totalFrames] 是整段的长度，只用于计算首尾淡入淡出；
  /// 分段渲染时传同一个值就能保证接缝处没有爆音。
  Uint8List render({
    required int sampleRate,
    required int startFrame,
    required int frames,
    required int totalFrames,
  }) {
    final bytes = Uint8List(frames * 2);
    final data = ByteData.sublistView(bytes);
    final fadeFrames = math.max(1, sampleRate * fadeMs ~/ 1000);

    for (var i = 0; i < frames; i++) {
      final index = startFrame + i;
      final t = index / sampleRate;

      // 4.2Hz 调幅 —— 音节感
      final envelope = 0.55 + 0.45 * math.sin(2 * math.pi * 4.2 * t);

      // 基频 + 谐波
      final wave = math.sin(2 * math.pi * fundamentalHz * t) +
          0.40 * math.sin(2 * math.pi * fundamentalHz * 2 * t) +
          0.20 * math.sin(2 * math.pi * fundamentalHz * 3 * t);

      var fade = 1.0;
      if (index < fadeFrames) {
        fade = index / fadeFrames;
      } else if (index > totalFrames - fadeFrames) {
        fade = math.max(0, (totalFrames - index) / fadeFrames);
      }

      final value = (wave * envelope * fade * amplitude * 32767)
          .clamp(-32768.0, 32767.0)
          .toInt();
      data.setInt16(i * 2, value, Endian.little);
    }

    return bytes;
  }
}

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../voice/voice_engine.dart';

/// 双电平条。
///
/// 上面一条是 AEC 之后的麦克风电平，下面一条是**当前正在播放的电平**。
/// 两条一起看才能判断 AEC 有没有生效：
/// 播测试音时麦克风条应该接近静默；你一说话它应该明显抬升。
class LevelMeter extends StatelessWidget {
  const LevelMeter({
    super.key,
    required this.levels,
    this.thresholdDb,
  });

  final ValueListenable<AudioLevels> levels;

  /// 可选的门槛线。不做自动打断之后主界面不再传它，
  /// 留着是为了以后调试别的判据时还能画一条参考线。
  final double? thresholdDb;

  static const double _floorDb = -80;

  double _normalize(double db) => ((db - _floorDb) / -_floorDb).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AudioLevels>(
      valueListenable: levels,
      builder: (context, value, _) {
        final theme = Theme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _bar(
              context: context,
              label: '麦克风 (AEC 后)',
              db: value.micDb,
              color: theme.colorScheme.primary,
              showThreshold: thresholdDb != null,
            ),
            const SizedBox(height: 12),
            _bar(
              context: context,
              label: '播放输出',
              db: value.playbackDb,
              color: theme.colorScheme.tertiary,
              showThreshold: false,
            ),
          ],
        );
      },
    );
  }

  Widget _bar({
    required BuildContext context,
    required String label,
    required double db,
    required Color color,
    required bool showThreshold,
  }) {
    final theme = Theme.of(context);
    final value = _normalize(db);
    final silent = db <= _floorDb + 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: theme.textTheme.labelMedium),
            Text(
              silent ? '静默' : '${db.toStringAsFixed(1)} dBFS',
              style: theme.textTheme.labelMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                color: silent ? theme.colorScheme.outline : theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return SizedBox(
              height: 14,
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                  Container(
                    width: width * value,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                  if (showThreshold)
                    Positioned(
                      left: (width * _normalize(thresholdDb!)).clamp(0.0, width - 2),
                      child: Container(
                        width: 2,
                        height: 14,
                        color: theme.colorScheme.error,
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

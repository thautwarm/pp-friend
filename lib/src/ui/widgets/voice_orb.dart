import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../voice/voice_engine.dart';

/// 主界面唯一的那个按钮。
///
/// 它同时承担三件事：开关、状态指示、电平反馈。所以不需要在旁边再摆
/// 一堆文字和仪表 —— 用户看一眼圆环的呼吸就知道麦克风有没有在工作。
enum OrbState { idle, listening, speaking }

class VoiceOrb extends StatefulWidget {
  const VoiceOrb({
    super.key,
    required this.levels,
    required this.state,
    required this.onTap,
    this.enabled = true,
    this.scale = 1.0,
  });

  final ValueListenable<AudioLevels> levels;
  final OrbState state;
  final VoidCallback onTap;
  final bool enabled;

  /// 整体缩放。主界面要把它放到顶部，得比全屏版小一圈。
  final double scale;

  /// 主圆直径（scale = 1 时）。外层留出的空间是给脉冲环用的。
  static const double baseCoreSize = 176;
  static const double baseCanvasSize = 320;

  double get coreSize => baseCoreSize * scale;
  double get canvasSize => baseCanvasSize * scale;

  static const double _floorDb = -70;

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<VoiceOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _breath;

  @override
  void initState() {
    super.initState();
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ValueListenableBuilder<AudioLevels>(
      valueListenable: widget.levels,
      builder: (context, value, _) {
        return AnimatedBuilder(
          animation: _breath,
          builder: (context, _) {
            final micLevel =
                ((value.micDb - VoiceOrb._floorDb) / -VoiceOrb._floorDb)
                    .clamp(0.0, 1.0);

            // 静音时也要有一点动静，否则用户分不清"在听"和"麦克风死了"。
            // 所以取电平与呼吸包络的较大者：有声音就跟着声音动，
            // 没声音就慢慢起伏。麦克风真失效时圆环会完全静止不动。
            final breath = 0.5 + 0.5 * math.sin(_breath.value * 2 * math.pi);
            final drive = math.max(micLevel, 0.22 * breath);

            final active = widget.state != OrbState.idle;

            final coreColor = switch (widget.state) {
              OrbState.idle => theme.colorScheme.surfaceContainerHighest,
              OrbState.listening => theme.colorScheme.primary,
              OrbState.speaking => theme.colorScheme.tertiary,
            };
            final iconColor = switch (widget.state) {
              OrbState.idle => theme.colorScheme.onSurfaceVariant,
              OrbState.listening => theme.colorScheme.onPrimary,
              OrbState.speaking => theme.colorScheme.onTertiary,
            };

            return Semantics(
              button: true,
              label: switch (widget.state) {
                OrbState.idle => '开始对话',
                OrbState.listening => '结束对话',
                OrbState.speaking => '结束对话',
              },
              child: GestureDetector(
                onTap: widget.enabled ? widget.onTap : null,
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: widget.canvasSize,
                  height: widget.canvasSize,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (active) ...[
                        _ring(coreColor, drive, 0.22, 52),
                        _ring(coreColor, drive, 0.34, 26),
                      ],
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                        width: widget.coreSize,
                        height: widget.coreSize,
                        // 显式居中。不写的话 Container 会把 Icon 拉伸到整块，
                        // 实际位置依赖 Icon 内部实现，不该赌。
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: coreColor,
                          boxShadow: active
                              ? [
                                  BoxShadow(
                                    color: coreColor.withValues(
                                      alpha: 0.30 + 0.18 * drive,
                                    ),
                                    blurRadius: 28 + 18 * drive,
                                    spreadRadius: 2,
                                  ),
                                ]
                              : null,
                        ),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: Transform.translate(
                            key: ValueKey(widget.state),
                            // 光学补偿：mic 字形的墨迹中心比包围盒中心偏上
                            // （上方是粗胶囊，下方只有细弧和细杆），
                            // 单纯居中看起来仍然偏上。graphic_eq 是上下对称的，不用补。
                            offset: Offset(
                              0,
                              widget.state == OrbState.speaking ? 0 : 2.0 * widget.scale,
                            ),
                            child: Icon(
                              switch (widget.state) {
                                OrbState.idle => Icons.mic_none_rounded,
                                OrbState.listening => Icons.mic_rounded,
                                OrbState.speaking => Icons.graphic_eq_rounded,
                              },
                              size: 72 * widget.scale,
                              color: iconColor,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _ring(Color color, double drive, double opacity, double maxGrowth) {
    return Container(
      width: widget.coreSize + maxGrowth * drive,
      height: widget.coreSize + maxGrowth * drive,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: color.withValues(alpha: opacity * (0.45 + 0.55 * drive)),
          width: 2,
        ),
      ),
    );
  }
}

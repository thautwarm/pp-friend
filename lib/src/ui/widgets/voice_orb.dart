import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../voice/voice_engine.dart';

/// 主界面唯一的那个按钮。
///
/// 它同时承担三件事：开关、状态指示、电平反馈。所以不需要在旁边再摆
/// 一堆文字和仪表 —— 用户看一眼圆环的呼吸就知道麦克风有没有在工作。
/// [starting] 是单独一个状态，因为它不是"开着"也不是"没开"：
/// 按下去之后要起前台服务、开音频链路、加载 1.26MB 的断句模型，
/// 这期间 `active` 还是 false —— 不把它单独画出来，用户按下去只会看到
/// 按钮毫无反应，然后怀疑自己是不是没按上。
enum OrbState { idle, starting, listening, speaking }

class VoiceOrb extends StatefulWidget {
  const VoiceOrb({
    super.key,
    required this.levels,
    required this.state,
    required this.onTap,
    this.enabled = true,
    this.scale = 1.0,
    this.accent,
    this.avatar,
    this.semanticLabel,
  });

  final ValueListenable<AudioLevels> levels;
  final OrbState state;
  final VoidCallback onTap;
  final bool enabled;

  /// 整体缩放。主界面要把它放到顶部，得比全屏版小一圈。
  final double scale;

  /// 这个档案的主题色。空着就用主题里默认的那两个色。
  final Color? accent;

  /// 档案头像。**图本身不裁**（等比缩放到放得下），但**显示时被裁在那个圆
  /// 里** —— 头像不许越过说话按钮的边界，也不该是一个方形的贴纸。
  ///
  /// 它是**半透明**压上去的，透出底下的主题色；而且**开没开始对话，它自己
  /// 会变**：没开始就压暗成黑白。头像占了圆里大半面积，光靠底色那点变化
  /// 是分不出状态的 —— 这是踩过的坑。
  ///
  /// 有头像的时候就不再画那个麦克风图标了：两者叠在一起会糊成一团，
  /// 而且状态本来就还有呼吸环和上面那行字在表达。
  final ImageProvider? avatar;

  /// 无障碍标签。默认按 [state] 说（"开始对话" / "结束对话"）。
  ///
  /// 旁边那半个圆指的是**另一个档案**，点它是"切过去"而不是开关 ——
  /// 不自己说清楚，读屏用户会听到"开始对话"，一按却把档案切走了。
  final String? semanticLabel;

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

            // "已经在跑"才上色、才有呼吸环。启动中还没跑起来，先按"没开"
            // 的样子画，另外给一圈转动的弧。
            final active = switch (widget.state) {
              OrbState.idle || OrbState.starting => false,
              OrbState.listening || OrbState.speaking => true,
            };

            final accent = widget.accent;

            final coreColor = switch (widget.state) {
              // 没开始对话时不带彩头：那时它是一个"待按"的按钮，
              // 不是某个身份的标志。启动中同理 —— 还没开始跑。
              OrbState.idle ||
              OrbState.starting =>
                theme.colorScheme.surfaceContainerHighest,
              OrbState.listening => accent ?? theme.colorScheme.primary,
              // 和"正在听"拉开距离，否则两个状态一个色，看不出在动。
              OrbState.speaking => accent == null
                  ? theme.colorScheme.tertiary
                  : Color.lerp(accent, theme.colorScheme.tertiary, 0.45)!,
            };
            final iconColor = switch (widget.state) {
              OrbState.idle => theme.colorScheme.onSurfaceVariant,
              // 用背景色的明暗反推前景色。用户挑一个浅黄主题色时，
              // 写死的白图标会直接看不见。
              _ => _onColor(coreColor),
            };

            return Semantics(
              button: true,
              label: widget.semanticLabel ??
                  switch (widget.state) {
                    OrbState.idle => '开始对话',
                    OrbState.starting => '正在启动',
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
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            if (widget.avatar != null)
                              Positioned.fill(
                                child: Padding(
                                  // 让出一圈底色，头像和按钮边缘之间留一条分界。
                                  padding: EdgeInsets.all(4 * widget.scale),
                                  // 遮罩：头像被裁在圆里，绝不越过说话按钮的
                                  // 边界。所以裁的是**这张图**，而不是给外面那
                                  // 个圆加 clipBehavior —— 后者会把圈外那层呼吸
                                  // 光晕一起剪掉，那是平时最显眼的反馈。
                                  child: ClipOval(
                                    // 头像盖住了大半个圆，底下那点状态色被挡得
                                    // 看不出来 —— "开着"和"关着"就分不清了。
                                    // 所以头像自己得跟着状态变：关着的时候又暗
                                    // 又灰（一眼是灭的），开着才是正常的彩色。
                                    child: AnimatedOpacity(
                                      duration: const Duration(milliseconds: 220),
                                      opacity: active ? 0.85 : 0.3,
                                      child: active
                                          ? _avatar(iconColor)
                                          : ColorFiltered(
                                              colorFilter: _greyscale,
                                              child: _avatar(iconColor),
                                            ),
                                    ),
                                  ),
                                ),
                              )
                            else
                              _icon(iconColor),
                          ],
                        ),
                      ),
                      // 启动中：贴着按钮边缘转一圈弧。比"底色微微变了一下"
                      // 显眼得多 —— 按下去之后必须马上看到有反应，否则用户
                      // 会以为没按上，接着再按第二下。
                      if (widget.state == OrbState.starting)
                        SizedBox(
                          width: widget.coreSize + 8,
                          height: widget.coreSize + 8,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            valueColor: AlwaysStoppedAnimation(
                              accent ?? theme.colorScheme.primary,
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

  /// 亮度加权的灰度矩阵。
  ///
  /// 没开始对话时用它把头像变成黑白。只压暗是不够的 —— 压到 0.3 仍然认得出
  /// 是谁，而"它是黑白的"这件事没法被误读成"开着"。
  static const ColorFilter _greyscale = ColorFilter.matrix(<double>[
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);

  /// 圆里那张头像。`contain`：图本身不裁，等比缩放到放得下，切边交给
  /// 外面那层 `ClipOval`。
  Widget _avatar(Color iconColor) {
    return Image(
      image: widget.avatar!,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      // 图被删了、拷坏了、或者干脆不是图片时退回图标。不兜的话 Image 会抛
      // 异常，整个说话按钮变成一个红框报错块 —— 一个头像的问题不该把主界面
      // 搞瘫。
      errorBuilder: (context, error, stack) => _icon(iconColor),
    );
  }

  /// 没有头像时（或者头像加载失败时）圆里画的那个图标。
  Widget _icon(Color iconColor) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: Transform.translate(
        key: ValueKey(widget.state),
        // 光学补偿：mic 字形的墨迹中心比包围盒中心偏上
        // （上方是粗胶囊，下方只有细弧和细杆），单纯居中看起来仍然偏上。
        // graphic_eq 是上下对称的，不用补。
        offset: Offset(
          0,
          widget.state == OrbState.speaking ? 0 : 2.0 * widget.scale,
        ),
        child: Icon(
          switch (widget.state) {
            OrbState.idle || OrbState.starting => Icons.mic_none_rounded,
            OrbState.listening => Icons.mic_rounded,
            OrbState.speaking => Icons.graphic_eq_rounded,
          },
          size: 72 * widget.scale,
          color: iconColor,
        ),
      ),
    );
  }

  /// 按背景色的明暗挑前景色，保证图标在任何主题色下都看得见。
  static Color _onColor(Color background) =>
      ThemeData.estimateBrightnessForColor(background) == Brightness.dark
          ? Colors.white
          : Colors.black87;

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

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../config/profile.dart';
import '../../voice/voice_engine.dart';
import 'voice_orb.dart';

/// 说话按钮那一行：左右滑动切换档案。
///
/// **只有中间那一页是活的。** 旁边露出来的半个圆不给它真实的麦克风电平，
/// 也不让它跟着呼吸 —— 电平是全局唯一的采集信号，让旁边的圆跟着动，
/// 用户会以为那个档案也在听。旁边那半个圆的点击语义只有"切过去"。
///
/// 用 [PageView] 而不是自己写 `GestureDetector(onHorizontalDragEnd)`：
/// 跟手拖动和松手回弹这两件事 PageView 白送，自己写要重造一遍。
class ProfileSwipeBand extends StatefulWidget {
  const ProfileSwipeBand({
    super.key,
    required this.profiles,
    required this.focusedId,
    required this.levels,
    required this.state,
    required this.enabled,
    required this.onTap,
    required this.onFocus,
    required this.avatarOf,
    this.scale = 0.62,
  });

  final List<Profile> profiles;
  final String focusedId;

  /// 聚焦档案的麦克风电平。旁边的档案用静默值。
  final ValueListenable<AudioLevels> levels;

  /// 聚焦档案的状态。
  final OrbState state;

  /// 聚焦档案能不能点（会话启动中要禁用）。
  final bool enabled;

  final VoidCallback onTap;

  /// 切到某个档案。被拒绝（档案已关闭）时这个 widget 会自己弹回原位。
  final void Function(String profileId) onFocus;

  final ImageProvider? Function(Profile profile) avatarOf;

  final double scale;

  static const double _dimScale = 0.72;
  static const int _settleMs = 240;

  @override
  State<ProfileSwipeBand> createState() => _ProfileSwipeBandState();
}

class _ProfileSwipeBandState extends State<ProfileSwipeBand> {
  late final PageController _page;
  late int _index;

  /// 旁边那些圆用的静默电平。复用一个，别在 build 里现造。
  final ValueNotifier<AudioLevels> _idle = ValueNotifier(
    const AudioLevels(micDb: -120, playbackDb: -120),
  );

  /// 正在按 widget 的焦点被动翻页，目标是这一页。null 表示没在被动翻页。
  ///
  /// 被动翻页会**路过**中间那几页，而 PageView 对路过的每一页都报一次
  /// `onPageChanged`。不认出来的话，把焦点从第 3 个档案挪到第 1 个的时候，
  /// 路过第 2 个会被当成"用户选了第 2 个"，焦点自己蹦回去 —— 而且每蹦一次
  /// 都要停一次播放、留一行痕。
  int? _syncTarget;

  @override
  void initState() {
    super.initState();
    _index = _indexOfFocused();
    _page = PageController(initialPage: _index, viewportFraction: 0.62);
  }

  @override
  void dispose() {
    _page.dispose();
    _idle.dispose();
    super.dispose();
  }

  int _indexOfFocused() {
    final index = widget.profiles.indexWhere((p) => p.id == widget.focusedId);
    return index < 0 ? 0 : index;
  }

  /// 焦点也可能被这条滑动带之外的路径改掉：关掉正在聚焦的档案、删档案、
  /// 设置页改配置。那些时候页面得跟上，否则显示的和实际聚焦的不是同一个。
  @override
  void didUpdateWidget(covariant ProfileSwipeBand oldWidget) {
    super.didUpdateWidget(oldWidget);

    // `_index` 是下标，列表却会整个换掉（档案全关掉 → 只剩一个开回来）。
    // 这时它可能落在列表外面：唯一那个档案会被当成"旁边的圆"来画（暗的、
    // 点不动），而它看起来正是那个"点击开始对话"的主按钮。
    //
    // **这一条不能等 `hasClients`**：PageView 刚被重建的那一帧还没挂上
    // controller，而 `_index` 必须当场就纠正过来。
    if (_index >= widget.profiles.length) _index = _indexOfFocused();

    // 焦点被拒绝了（切到一个已关闭的档案），或者被别的路径改掉了
    // （关档案、删档案、设置页保存），就跟着挪过去。
    final target = _indexOfFocused();
    if (target == _index) return;
    _index = target;

    if (_page.hasClients) {
      _syncTarget = target;
      _page.animateToPage(
        target,
        duration: const Duration(milliseconds: ProfileSwipeBand._settleMs),
        curve: Curves.easeOut,
      );
      return;
    }
    // PageView 是这一帧才重新长出来的（在那之前一个档案都没有）。等它挂上
    // controller 再跳 —— 不然它自己会停在 PageStorage 记着的那一页上，
    // 和 `_index` 对不上，高亮就又错了。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_page.hasClients) return;
      if (_page.page?.round() != _index) _page.jumpToPage(_index);
    });
  }

  void _go(int delta) {
    final target = (_index + delta).clamp(0, widget.profiles.length - 1);
    if (target == _index) return;
    _page.animateToPage(
      target,
      duration: const Duration(milliseconds: ProfileSwipeBand._settleMs),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final height = VoiceOrb.baseCanvasSize * widget.scale;
    // 档案全被关掉的时候这里**不能什么都不画**：屏幕上会空出一块，
    // 标题行还写着"点击开始对话"，而根本没有可以点的东西。
    if (widget.profiles.isEmpty) return _empty(context);

    return SizedBox(
      height: height,
      child: Stack(
        alignment: Alignment.center,
        children: [
          NotificationListener<ScrollStartNotification>(
            // 手指一碰就说明用户接手了，被动翻页作废。
            //
            // 不清的话：动画被拖拽打断之后到不了目标页，_syncTarget 就
            // 一直挂着，之后**怎么滑都不再切换档案** —— 静默死掉，
            // 界面上看不出任何异常。
            onNotification: (notification) {
              if (notification.dragDetails != null) _syncTarget = null;
              return false;
            },
            child: PageView.builder(
              controller: _page,
              // 只有一个档案时不该能滑 —— 滑了也没有下一页，白折腾。
              physics: widget.profiles.length < 2
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              itemCount: widget.profiles.length,
              onPageChanged: (index) {
                _index = index;
                final target = _syncTarget;
                if (target != null) {
                  // 被动翻页：只有真到了目标页才算走完，路过的不算数
                  if (index == target) _syncTarget = null;
                  return;
                }
                final id = widget.profiles[index].id;
                // 已经和权威焦点一致（用户又滑回当前聚焦的那一页）就不用通知
                if (id == widget.focusedId) return;
                widget.onFocus(id);
              },
              itemBuilder: (context, index) => _orb(
                context,
                widget.profiles[index],
                isFocused: index == _index,
              ),
            ),
          ),
          if (widget.profiles.length > 1) ...[
            _arrow(
              context,
              Icons.chevron_left_rounded,
              atStart: true,
              shown: _index > 0,
              onTap: () => _go(-1),
            ),
            _arrow(
              context,
              Icons.chevron_right_rounded,
              atStart: false,
              shown: _index < widget.profiles.length - 1,
              onTap: () => _go(1),
            ),
          ],
        ],
      ),
    );
  }

  /// 一个开着的档案都没有时的样子。
  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: VoiceOrb.baseCanvasSize * widget.scale,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.person_off_outlined,
              size: 40 * widget.scale + 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.of(context).noEnabledProfiles,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              AppLocalizations.of(context).noEnabledProfilesBody,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _orb(
    BuildContext context,
    Profile profile, {
    required bool isFocused,
  }) {
    return Center(
      child: Opacity(
        opacity: isFocused ? 1 : 0.55,
        child: VoiceOrb(
          // 旁边的圆给静默电平：它没在听，不该跟着麦克风动。
          levels: isFocused ? widget.levels : _idle,
          state: isFocused ? widget.state : OrbState.idle,
          // 旁边的圆只保留"点击切过去"这一个动作。
          enabled: isFocused ? widget.enabled : true,
          scale: widget.scale * (isFocused ? 1 : ProfileSwipeBand._dimScale),
          accent: Color(profile.accentColor),
          avatar: widget.avatarOf(profile),
          // 旁边的圆的动作是"切过去"，不是开始对话。交给 VoiceOrb 默认那套
          // （按 state 念）会说成"开始对话，按钮"—— 读屏用户按下去，
          // 档案被切走了，而它以为刚开始说话。
          semanticLabel: isFocused
              ? null
              : AppLocalizations.of(context)
                    .switchToProfile(profile.displayName),
          onTap: isFocused ? widget.onTap : () => widget.onFocus(profile.id),
        ),
      ),
    );
  }

  /// 左右边缘的箭头。到头了就淡出，提示"这边没有了"。
  Widget _arrow(
    BuildContext context,
    IconData icon, {
    required bool atStart,
    required bool shown,
    required VoidCallback onTap,
  }) {
    return Align(
      alignment: atStart ? Alignment.centerLeft : Alignment.centerRight,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: shown ? 0.7 : 0,
        child: IconButton(
          // 淡出之后还要能接收点击的话，用户会点到看不见的东西
          onPressed: shown ? onTap : null,
          icon: Icon(icon),
          tooltip: atStart
              ? AppLocalizations.of(context).previousProfile
              : AppLocalizations.of(context).nextProfile,
        ),
      ),
    );
  }
}

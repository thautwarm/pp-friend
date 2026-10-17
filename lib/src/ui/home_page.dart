import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../config/profile.dart';
import '../conversation/conversation_controller.dart';
import '../conversation/message.dart';
import 'debug_page.dart';
import 'settings_page.dart';
import 'widgets/profile_swipe_band.dart';
import 'widgets/voice_orb.dart';

/// 主界面。
///
/// 结构：**顶部一个按钮 + 下面是消息流**。
/// 按钮放在上面而不是常见的底部，是因为消息流要占满剩下的空间、
/// 并且从下往上生长 —— 按钮压在上面既不会挡到最新消息，
/// 也始终在拇指够得着的地方。
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});

  final ConversationController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _scroll = ScrollController();

  /// 上一次见到的 [ConversationController.lastSeq]。判断"是不是来了新消息"。
  ///
  /// **不能用消息条数代替。** 内存窗口满了之后条数就不再增长（自动滚动会
  /// 静默失效）；反过来，往上翻历史会让条数变大，被误判成新消息，把正在
  /// 看历史的用户拽回底部。seq 是单调的，两个毛病都没有。
  int _seenLastSeq = 0;

  /// 上一次聚焦的档案。换了档案就把 [_seenLastSeq] 归零并滚到底 ——
  /// 换的是另一屏历史，和上一个档案的 seq 没有可比性。
  String? _lastFocusedId;

  /// 正在往前面插更早的历史。这期间**绝对不能**自动滚到底，
  /// 否则"用户正在往上翻，后台档案来了条消息"就会把人弹回去。
  bool _loadingEarlier = false;

  /// 离顶部多近就去加载更早的。
  static const double _loadEarlierThreshold = 200;

  /// 判定"用户贴着底部"的容差（逻辑像素）。
  static const double _stickToBottomThreshold = 120;

  /// 头像的 [ImageProvider] 缓存。
  ///
  /// 这个页面每 500ms 就因为电平刷新重建一次，每次 build 都现造
  /// `FileImage` 的话会一直new 对象。按路径缓存，换头像时路径会变
  /// （文件名带时间戳），自然就换了。
  final Map<String, ImageProvider> _avatars = {};

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_loadingEarlier) return;
    if (_scroll.position.pixels > _loadEarlierThreshold) return;
    if (!widget.controller.hasMoreBefore) return;
    unawaited(_loadEarlier());
  }

  /// 往上翻一页，并且**把滚动位置补回来**。
  ///
  /// 往前面插 N 条会让内容变高。不补偿的话，`pixels` 没变而内容长了，
  /// 用户视野里的东西会瞬间跳走 —— 翻得越多跳得越狠。
  ///
  /// **已知的残余误差**：补偿量取的是"总高度长了多少"，而这段读盘时间里
  /// 新到的消息也会让总高度变长，于是你会被多推下去约一条消息的高度。
  /// 要彻底消掉得把读盘和插入拆成两步（在插入那一瞬间同步量高度），
  /// 但那会让"往哪个档案里插"变成跨 await 的判断 —— 串档的风险比这点
  /// 抖动大得多，所以留着。
  Future<void> _loadEarlier() async {
    if (_loadingEarlier) return;
    setState(() => _loadingEarlier = true);

    final focused = _lastFocusedId;
    final before = _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
    try {
      await widget.controller.loadOlder();
    } catch (e) {
      // 读失败也要放开标志。留在 true 上的话 `_onScroll` 和
      // `_maybeAutoScroll` 就双双短路了：往上翻不动、新消息也不自动滚到
      // 底，而且界面上一点提示都没有 —— 静默失灵是最难查的那种。
      if (mounted) setState(() => _loadingEarlier = false);
      return;
    }
    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 读盘期间换了档案 —— 这时 before 是上一个档案的量，差值毫无意义，
      // 跳过去只会把人甩到一个莫名其妙的位置。新档案那边
      // _syncFocusedProfile 会负责滚到底。
      if (_scroll.hasClients && _lastFocusedId == focused) {
        final delta = _scroll.position.maxScrollExtent - before;
        _scroll.jumpTo(
          (_scroll.position.pixels + delta).clamp(
            0.0,
            _scroll.position.maxScrollExtent,
          ),
        );
      }
      setState(() => _loadingEarlier = false);
    });
  }

  /// 来了新消息才自动滚到底，而且**只在用户本来就贴着底部时**。
  ///
  /// 两个条件缺一不可：
  ///  - 不判 seq 的话，`_refreshStats` 每 500ms 一次的 notifyListeners
  ///    会把列表死死钉在底部，用户根本滚不上去看历史
  ///  - 不判位置的话，你正在往上翻，一条新消息就把你拽回去了
  void _maybeAutoScroll(int lastSeq) {
    final grew = lastSeq > _seenLastSeq;
    _seenLastSeq = lastSeq;

    if (_loadingEarlier || !grew) return;

    // 必须在**插入新消息之前**判断位置 —— 插完之后 maxScrollExtent 就变了
    var wasAtBottom = true;
    if (_scroll.hasClients) {
      final position = _scroll.position;
      wasAtBottom =
          (position.maxScrollExtent - position.pixels) <
          _stickToBottomThreshold;
    }
    if (!wasAtBottom) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    });
  }

  /// 换档案时跳到新那屏的底部。
  void _syncFocusedProfile(String id) {
    if (id == _lastFocusedId) return;
    _lastFocusedId = id;
    _seenLastSeq = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  ImageProvider? _avatarFor(Profile profile) {
    final path = widget.controller.avatarPathOf(profile);
    if (path == null) return null;
    return _avatars.putIfAbsent(path, () => FileImage(File(path)));
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context);
        _maybeAutoScroll(controller.lastSeq);
        _syncFocusedProfile(controller.config.focusedProfileId);
        return Scaffold(
          appBar: AppBar(
            title: const Text('PP Friend'),
            centerTitle: false,
            actions: [
              IconButton(
                tooltip: l10n.debugPanelTooltip,
                icon: const Icon(Icons.tune_rounded),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => DebugPage(controller: controller),
                  ),
                ),
              ),
              IconButton(
                tooltip: l10n.brainConfigTooltip,
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SettingsPage(controller: controller),
                  ),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 8),
                ProfileSwipeBand(
                  // 只放开着的档案。关掉的档案不轮询、不能聚焦，
                  // 放进滑动带里就是几页怎么点都点不动的死页 ——
                  // 那些在设置页里管。
                  profiles: [
                    for (final profile in controller.config.profiles)
                      if (profile.enabled) profile,
                  ],
                  focusedId: controller.config.focusedProfileId,
                  levels: controller.levelsNotifier,
                  state: _state(),
                  enabled: !controller.busy,
                  scale: 0.62,
                  onTap: controller.toggle,
                  onFocus: controller.switchProfile,
                  avatarOf: _avatarFor,
                ),
                const SizedBox(height: 4),
                _toggles(context),
                const SizedBox(height: 6),
                _headline(context),
                const SizedBox(height: 12),
                Expanded(child: _messageStream(context)),
              ],
            ),
          ),
        );
      },
    );
  }

  OrbState _state() {
    if (!widget.controller.active) {
      // 启动要好几步（前台服务、音频链路、1.26MB 的断句模型），这期间
      // `active` 还是 false。不单独报一个"启动中"，用户按下去只会看到
      // 按钮和没按之前一模一样 —— 于是再按第二下。
      return widget.controller.busy ? OrbState.starting : OrbState.idle;
    }
    return widget.controller.speaking ? OrbState.speaking : OrbState.listening;
  }

  Widget _headline(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final controller = widget.controller;

    final String text;
    if (controller.busy) {
      text = l10n.starting;
    } else if (!controller.active) {
      text = l10n.tapToStart;
    } else if (controller.segmenterError != null) {
      // 断了就没法切句，比 brain 连不上更致命 —— 用户说话将毫无反应
      text = l10n.segmenterUnavailable;
    } else if (controller.authFailed) {
      text = l10n.tokenInvalid;
    } else if (controller.brainError != null) {
      // brain 连不上时，光显示"正在听你说"是骗人的
      text = l10n.brainUnresponsive;
    } else if (controller.micMuted) {
      // 压在"正在说话/正在听"前面：麦克风关着是这一屏最重要的事实
      text = l10n.mutedUploadingOff;
    } else if (controller.speaking) {
      // 关掉那个开关之后音量减就只是调音量了，再写着"可以清空"是骗人
      text = controller.config.volumeKeyClearsQueue
          ? l10n.speakingCanClear
          : l10n.speaking;
    } else if (controller.userSpeaking) {
      text = l10n.listening;
    } else if (controller.queuedUtterances > 0) {
      text = l10n.queuedUtterances(controller.queuedUtterances);
    } else {
      text = l10n.listening;
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: Text(
        text,
        key: ValueKey(text),
        style: theme.textTheme.titleMedium?.copyWith(
          color: controller.active
              ? theme.colorScheme.onSurface
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _messageStream(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final controller = widget.controller;
    final messages = controller.messages;

    // 历史还没从盘上读出来（冷启动的头一两帧）时**什么都别说**。
    // 不区分的话会先闪一句"直接说话就行"，下一帧历史才冒出来 ——
    // 对用户来说就是"它说没有记录，然后又有了"。
    if (messages.isEmpty && !controller.historyLoaded) {
      return const SizedBox.shrink();
    }

    if (messages.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        children: [
          if (controller.segmenterError != null) _segmenterBanner(context),
          if (!controller.config.brain.isUsable) _configBanner(context),
          const SizedBox(height: 24),
          Text(
            controller.active ? l10n.idleHint : l10n.emptyHint,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      controller: _scroll,
      // 允许回看历史：新消息不会把正在往上翻的用户拽回底部
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        // 往上翻会把更早的消息**插到前面**，没有 key 的话 Flutter 会按位置
        // 复用列表项，整屏内容会错位一帧。seq 是盘上发的号，唯一且单调。
        //
        // 落盘失败的那几条没有号（seq == 0），退回对象身份 —— 两个 seq 0
        // 的消息共用一个 key 会让列表项张冠李戴。
        return _bubble(
          context,
          message,
          key: message.seq > 0
              ? ValueKey<int>(message.seq)
              : ObjectKey(message),
        );
      },
    );
  }

  /// 断句引擎加载失败时的提示。
  ///
  /// 这一条比"还没配置 brain"更严重：没有 segmenter 就永远不会切出一句话，
  /// 你说什么都毫无反应。能量 VAD 已经删掉，没有能够顶上来的备胎，
  /// 所以必须在主界面正面说出来，而不是只写进调试日志。
  Widget _segmenterBanner(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.error_outline,
                size: 18,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Text(
                l10n.segmenterLoadFailed,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${widget.controller.segmenterError}\n\n'
            '${l10n.segmenterLoadFailedBody}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
        ],
      ),
    );
  }

  /// 未配置 brain 时的提示。
  ///
  /// 没有它的话，用户点按钮会毫无反应 —— 因为 start() 提前返回了，
  /// 而原因只写在调试日志里。那是最糟糕的一种失败：静默。
  Widget _configBanner(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.error_outline,
                size: 18,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Text(
                l10n.noBrain,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            l10n.noBrainBody,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonal(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsPage(controller: widget.controller),
                ),
              ),
              child: Text(l10n.goToSettings),
            ),
          ),
        ],
      ),
    );
  }

  /// 两个开关：闭麦 / 打断。
  ///
  /// 放在 orb 下面而不是塞进设置页：闭麦是"我现在要跟旁边人说句话"这种
  /// 临时动作，点进设置页再退出来，话都说完了。
  Widget _toggles(BuildContext context) {
    final controller = widget.controller;
    final l10n = AppLocalizations.of(context);
    // 没开始对话时它没有意义（本来就没在采音频）。置灰但**不隐藏** ——
    // 否则开始/结束的一瞬间按钮会跳一下。
    final enabled = controller.active && !controller.busy;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _toggleChip(
          icon: controller.micMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
          label: controller.micMuted ? l10n.muted : l10n.mute,
          on: controller.micMuted,
          enabled: enabled,
          onTap: controller.toggleMicMuted,
        ),
        const SizedBox(width: 10),
        _toggleChip(
          icon: Icons.front_hand_rounded,
          label: l10n.bargeIn,
          on: controller.bargeIn,
          // 闭麦时打断天然失效（音频根本没上去），灰掉而不是假装能用
          enabled: enabled && !controller.micMuted,
          onTap: () => controller.updateConfig(
            controller.config.copyWith(bargeIn: !controller.bargeIn),
          ),
        ),
      ],
    );
  }

  Widget _toggleChip({
    required IconData icon,
    required String label,
    required bool on,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return FilterChip(
      avatar: Icon(icon, size: 16),
      label: Text(label),
      selected: on,
      // 选中已经有了底色，再打一个勾反而看不清图标
      showCheckmark: false,
      onSelected: enabled ? (_) => onTap() : null,
    );
  }

  Widget _bubble(
    BuildContext context,
    ConversationMessage message, {
    Key? key,
  }) {
    final theme = Theme.of(context);

    // 客户端自己写的一行提示（目前只有闭麦留痕）。不套气泡 —— 它不是谁说的话。
    if (message.role == MessageRole.note) {
      return Padding(
        key: key,
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          message.text,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final fromUser = message.role == MessageRole.user;

    final background = fromUser
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final foreground = fromUser
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;

    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: fromUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!fromUser) _avatar(theme, Icons.graphic_eq_rounded, foreground),
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.72,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(fromUser ? 18 : 4),
                  bottomRight: Radius.circular(fromUser ? 4 : 18),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message.text,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: foreground,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    message.time,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: foreground.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (fromUser) _avatar(theme, Icons.person_rounded, foreground),
        ],
      ),
    );
  }

  Widget _avatar(ThemeData theme, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: CircleAvatar(
        radius: 14,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        child: Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../conversation/conversation_controller.dart';
import '../conversation/message.dart';
import 'debug_page.dart';
import 'settings_page.dart';
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

  /// 上一次见到的消息条数。用来判断"是不是来了新消息"。
  int _seenMessageCount = 0;

  /// 判定"用户贴着底部"的容差（逻辑像素）。
  static const double _stickToBottomThreshold = 120;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 来了新消息才自动滚到底，而且**只在用户本来就贴着底部时**。
  ///
  /// 两个条件缺一不可：
  ///  - 不判条数的话，`_refreshStats` 每 500ms 一次的 notifyListeners
  ///    会把列表死死钉在底部，用户根本滚不上去看历史
  ///  - 不判位置的话，你正在往上翻，一条新消息就把你拽回去了
  void _maybeAutoScroll(int messageCount) {
    final grew = messageCount > _seenMessageCount;
    _seenMessageCount = messageCount;

    if (!grew || messageCount == 0) return;

    // 必须在**插入新消息之前**判断位置 —— 插完之后 maxScrollExtent 就变了
    var wasAtBottom = true;
    if (_scroll.hasClients) {
      final position = _scroll.position;
      wasAtBottom =
          (position.maxScrollExtent - position.pixels) < _stickToBottomThreshold;
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

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        _maybeAutoScroll(controller.messages.length);
        return Scaffold(
          appBar: AppBar(
            title: const Text('PP Friend'),
            centerTitle: false,
            actions: [
              IconButton(
                tooltip: '调试面板',
                icon: const Icon(Icons.tune_rounded),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => DebugPage(controller: controller),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'brain 配置',
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
                VoiceOrb(
                  levels: controller.levelsNotifier,
                  state: _state(),
                  enabled: !controller.busy,
                  scale: 0.62,
                  onTap: controller.toggle,
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
    if (!widget.controller.active) return OrbState.idle;
    return widget.controller.speaking ? OrbState.speaking : OrbState.listening;
  }

  Widget _headline(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;

    final String text;
    if (controller.busy) {
      text = '请稍候…';
    } else if (!controller.active) {
      text = '点击开始对话';
    } else if (controller.segmenterError != null) {
      // 断了就没法切句，比 brain 连不上更致命 —— 用户说话将毫无反应
      text = '⚠️ 断句引擎不可用';
    } else if (controller.authFailed) {
      text = '⚠️ token 无效';
    } else if (controller.brainError != null) {
      // brain 连不上时，光显示"正在听你说"是骗人的
      text = '⚠️ brain 无响应';
    } else if (controller.micMuted) {
      // 压在"正在说话/正在听"前面：麦克风关着是这一屏最重要的事实
      text = '闭麦中 · 说的话不会上传';
    } else if (controller.speaking) {
      text = '正在说话 · 音量减可以清空';
    } else if (controller.userSpeaking) {
      text = '正在听你说';
    } else if (controller.queuedUtterances > 0) {
      text = '还有 ${controller.queuedUtterances} 句在上传';
    } else {
      text = '正在听你说';
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
    final messages = widget.controller.messages;

    if (messages.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        children: [
          if (widget.controller.segmenterError != null)
            _segmenterBanner(context),
          if (!widget.controller.config.brain.isUsable) _configBanner(context),
          const SizedBox(height: 24),
          Text(
            widget.controller.active
                ? '直接说话就行'
                : '开始之后，你和它说的话都会出现在这里',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
      itemBuilder: (context, index) => _bubble(context, messages[index]),
    );
  }

  /// 断句引擎加载失败时的提示。
  ///
  /// 这一条比"还没配置 brain"更严重：没有 segmenter 就永远不会切出一句话，
  /// 你说什么都毫无反应。能量 VAD 已经删掉，没有能够顶上来的备胎，
  /// 所以必须在主界面正面说出来，而不是只写进调试日志。
  Widget _segmenterBanner(BuildContext context) {
    final theme = Theme.of(context);
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
              Icon(Icons.error_outline,
                  size: 18, color: theme.colorScheme.onErrorContainer),
              const SizedBox(width: 8),
              Text(
                '本地断句引擎加载失败',
                style: theme.textTheme.titleSmall
                    ?.copyWith(color: theme.colorScheme.onErrorContainer),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${widget.controller.segmenterError}\n\n'
            '多半是 Rust 动态库（librust_lib_pp_friend.so）没打进 APK，'
            '或 ABI 对不上。重跑 tools/build_rust_android.sh 再装一次。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onErrorContainer),
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
              Icon(Icons.error_outline,
                  size: 18, color: theme.colorScheme.onErrorContainer),
              const SizedBox(width: 8),
              Text(
                '还没配置 brain',
                style: theme.textTheme.titleSmall
                    ?.copyWith(color: theme.colorScheme.onErrorContainer),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '填好 Base URL 和 brain_id 才能开始对话。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onErrorContainer),
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
              child: const Text('去配置'),
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
    // 没开始对话时它没有意义（本来就没在采音频）。置灰但**不隐藏** ——
    // 否则开始/结束的一瞬间按钮会跳一下。
    final enabled = controller.active && !controller.busy;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _toggleChip(
          icon: controller.micMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
          label: controller.micMuted ? '闭麦中' : '闭麦',
          on: controller.micMuted,
          enabled: enabled,
          onTap: controller.toggleMicMuted,
        ),
        const SizedBox(width: 10),
        _toggleChip(
          icon: Icons.front_hand_rounded,
          label: '打断',
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

  Widget _bubble(BuildContext context, ConversationMessage message) {
    final theme = Theme.of(context);

    // 客户端自己写的一行提示（目前只有闭麦留痕）。不套气泡 —— 它不是谁说的话。
    if (message.role == MessageRole.note) {
      return Padding(
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
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment:
            fromUser ? MainAxisAlignment.end : MainAxisAlignment.start,
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
                    style: theme.textTheme.bodyLarge?.copyWith(color: foreground),
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

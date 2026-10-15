import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../config/assistant_config.dart';
import '../conversation/conversation_controller.dart';
import 'profile_editor.dart';
import 'widgets/settings_widgets.dart';

/// 配置页。
///
/// 顶层两个 tab：**档案**和**断句参数**。前者里面再横着排一条档案 tab，
/// 末尾一个加号 —— 档案之间就地切，不用反复进出二级页。
///
/// 断句参数是**全局的**，不跟档案走：每个档案一套的话，切档案就得重建
/// 那个 1.26MB 的 ONNX 断句器，而切换必须是立刻的。所以它是单独一个 tab，
/// 而不是塞在档案编辑里。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final ConversationController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  /// 正在编辑哪个档案。**记 id，不记下标。**
  ///
  /// 下标会在档案被删掉之后整体前移：正编辑着第 2 个，把第 1 个删了，
  /// 同一个下标就指向了另一个档案；更糟的是把正在编辑的那个删掉之后，
  /// 下标还指着一个已经不存在的档案，编辑器会绑在一份幽灵配置上 ——
  /// 按"保存"看起来成功了，实际上 `_current()` 返回 null，什么都没写。
  String? _selectedId;

  /// 竖着的一排 chip 里的那个，用它把选中的滚进视野。
  final GlobalKey _chipKey = GlobalKey();
  final ScrollController _chipScroll = ScrollController();

  /// 用它去调编辑器的落盘。切档案之前先让它把手上的改动写下去 ——
  /// 不写的话，切走一次就把没保存的编辑丢了，而且丢得毫无提示。
  final GlobalKey<ProfileEditorState> _editor = GlobalKey<ProfileEditorState>();

  late final TextEditingController _vadMinSilenceMs;
  late final TextEditingController _vadThreshold;
  late final TextEditingController _vadSpeechPadMs;
  late final TextEditingController _vadMinSpeechMs;
  late final TextEditingController _vadMaxSpeechS;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    final config = widget.controller.config;
    _vadMinSilenceMs =
        TextEditingController(text: config.vadMinSilenceMs.toString());
    _vadThreshold = TextEditingController(text: config.vadThreshold.toString());
    _vadSpeechPadMs =
        TextEditingController(text: config.vadSpeechPadMs.toString());
    _vadMinSpeechMs =
        TextEditingController(text: config.vadMinSpeechMs.toString());
    _vadMaxSpeechS = TextEditingController(text: config.vadMaxSpeechS.toString());
    _selectedId = config.focusedProfileId;
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealSelected());
  }

  @override
  void dispose() {
    _tabs.dispose();
    _chipScroll.dispose();
    _vadMinSilenceMs.dispose();
    _vadThreshold.dispose();
    _vadSpeechPadMs.dispose();
    _vadMinSpeechMs.dispose();
    _vadMaxSpeechS.dispose();
    super.dispose();
  }

  List<Profile> get _profiles => widget.controller.config.profiles;

  int _indexOfFocused() {
    final index =
        _profiles.indexWhere((p) => p.id == widget.controller.config.focusedProfileId);
    return index < 0 ? 0 : index;
  }

  /// 正在编辑的那一个在下标几。id 已经不在列表里了（被删了）就落在聚焦的那个
  /// 档案上 —— 绝不返回一个悬空的下标。
  int get _index {
    final index = _profiles.indexWhere((p) => p.id == _selectedId);
    return index < 0 ? _indexOfFocused() : index;
  }

  /// 把选中的那个 chip 滚进视野。
  ///
  /// 不滚的话，档案一多（或者主界面上滑到了最后一个再进来），选中的那个
  /// 在屏幕右边外面 —— 一眼看不出正在编辑谁，新建的也看不见。
  void _revealSelected() {
    final context = _chipKey.currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(
      context,
      alignment: 0.5,
      duration: const Duration(milliseconds: 200),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 解析失败一律回落到默认值 —— 不该因为一个手滑的输入就保存不了。
  int _int(TextEditingController c, int fallback) =>
      int.tryParse(c.text.trim()) ?? fallback;

  double _double(TextEditingController c, double fallback) =>
      double.tryParse(c.text.trim()) ?? fallback;

  Future<void> _save() async {
    final bool written;
    try {
      written = await _editor.currentState?.commit() ?? true;
      await _saveVad();
    } catch (e) {
      _toast('没保存成功：$e');
      return;
    }
    // 编辑器的档案已经被删掉时它什么都不写。这时候弹"已保存"就是骗人：
    // 用户改的名字、填的地址一起没了，而他以为存住了。
    _toast(written ? '已保存' : '这个档案已经不在了，改动没有保存');
  }

  Future<void> _saveVad() async {
    final base = widget.controller.config;
    // 只写全局参数。`copyWith` 不带 brain，档案一个都不会被动到。
    await widget.controller.updateConfig(base.copyWith(
      vadMinSilenceMs: _int(_vadMinSilenceMs, base.vadMinSilenceMs),
      vadThreshold: _double(_vadThreshold, base.vadThreshold).clamp(0.01, 0.99),
      vadSpeechPadMs: _int(_vadSpeechPadMs, base.vadSpeechPadMs),
      vadMinSpeechMs: _int(_vadMinSpeechMs, base.vadMinSpeechMs),
      vadMaxSpeechS: _int(_vadMaxSpeechS, base.vadMaxSpeechS).clamp(1, 600),
    ));
  }

  /// 换到另一个档案：先把当前的改动落盘，再切。
  Future<void> _select(Profile profile) async {
    if (profile.id == _selectedId) return;
    // 先落盘再切。落不了就别切 —— 切过去会把这些改动无声无息地冲掉。
    try {
      await _editor.currentState?.commit();
    } catch (e) {
      _toast('没保存成功，先别切：$e');
      return;
    }
    if (!mounted) return;
    setState(() => _selectedId = profile.id);
    _revealSelected();
  }

  /// 新建一个档案，并且立刻选中它让人接着填。
  ///
  /// 是先落盘再编辑（不是先编辑再落盘）：tab 上得马上出现这一项。
  /// 代价是半途放弃会留下一个空档案 —— 所以它带着一个显眼的"删除"。
  Future<void> _add() async {
    try {
      await _editor.currentState?.commit();
    } catch (e) {
      _toast('没保存成功，先别新建：$e');
      return;
    }
    final profile = Profile(id: Profile.newId(), name: '新档案');
    await widget.controller.saveProfile(profile);
    if (!mounted) return;
    // 新建的那个在列表末尾，往往在屏幕外面 —— 不滚过去的话，编辑器
    // 已经切到"新档案"了，上面那排 chip 里却看不出选中了谁。
    setState(() => _selectedId = profile.id);
    _revealSelected();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // **整页跟着 controller 重建。** 保存之后名字、开关、头像都变了，
    // 而 `showSnackBar` 不会重建页面 —— 不订阅的话，改完名字按保存，
    // 下面那排 chip 还写着旧名字，看着就像没保存成功。
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('配置'),
          actions: [TextButton(onPressed: _save, child: const Text('保存'))],
          bottom: TabBar(
            controller: _tabs,
            tabs: const [
              Tab(text: '档案'),
              Tab(text: '断句参数'),
            ],
          ),
        ),
        // 不用管"一个档案都没有"：`normalized()` 保证至少留一个（删光了它会
        // 补一个空的回来），所以下面那个下标一定落在列表里面。
        body: TabBarView(
          controller: _tabs,
          children: [
            _profileTab(),
            _vadTab(theme),
          ],
        ),
      ),
    );
  }

  Widget _profileTab() {
    final profile = _profiles[_index.clamp(0, _profiles.length - 1)];
    return Column(
      children: [
        _profileTabs(),
        const Divider(height: 1),
        Expanded(
          child: ProfileEditor(
            key: _editor,
            controller: widget.controller,
            profile: profile,
          ),
        ),
      ],
    );
  }

  /// 档案那一排 tab，末尾一个加号。
  Widget _profileTabs() {
    final selected = _index;
    return SizedBox(
      height: 56,
      child: ListView(
        controller: _chipScroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        children: [
          for (var i = 0; i < _profiles.length; i++)
            Padding(
              // 选中那个挂 key，用来把它滚进视野。同一时刻只有一个，
              // 所以这一个 key 够用。
              key: i == selected ? _chipKey : null,
              padding: const EdgeInsets.only(right: 8),
              child: _profileTabChip(
                _profiles[i],
                i == selected,
                () => _select(_profiles[i]),
              ),
            ),
          // 加号。用 OutlinedButton 而不是另一个 chip：它是动作不是"某一页"，
          // 长得一样会让人以为点了会切到一个叫"+"的档案。
          IconButton.outlined(
            onPressed: _add,
            icon: const Icon(Icons.add),
            tooltip: '新建档案',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _profileTabChip(Profile profile, bool selected, VoidCallback onTap) {
    final theme = Theme.of(context);
    final accent = Color(profile.accentColor);
    final path = widget.controller.avatarPathOf(profile);
    // 关闭的档案看起来就该是"灰的"，一眼分得出哪个开着
    final dim = !profile.enabled;

    return Material(
      color: selected ? accent : theme.colorScheme.surfaceContainerHighest,
      shape: const StadiumBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
          child: Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: selected ? accent : theme.colorScheme.surface,
                foregroundImage: path == null ? null : FileImage(File(path)),
                // 文件被删了（配置里还留着文件名）不该把整页搞成报错。
                // 吞掉之后画面就是"没有头像"的样子，那正是事实。
                onForegroundImageError: path == null ? null : (_, _) {},
                // 首字**一直挂着**，不是"没图才画"：头像是画在 child 上面的
                // 那一层（foregroundImage），图在的时候盖住它，图丢了就露出来。
                // 写成 `path == null ? Text : null` 的话，图一丢 chip 上就只剩
                // 一个空圆 —— 既没有图也没有字。
                child: Text(
                  profile.displayName.characters.first,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: selected
                        ? onAccentColor(accent)
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                profile.displayName,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: selected
                      ? onAccentColor(accent)
                      : theme.colorScheme.onSurfaceVariant,
                  // 关掉的那个整体压暗，和"开着"分开
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              if (dim) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.power_settings_new,
                  size: 14,
                  color: selected
                      ? onAccentColor(accent).withValues(alpha: 0.7)
                      : theme.colorScheme.onSurfaceVariant,
                  semanticLabel: '已关闭',
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _vadTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        SettingsSection(
          title: '本地断句',
          children: [
            Text(
              '切句必须留在本地：否则就得把整条麦克风流实时推给服务端，'
              '那是另一套协议。判据是 Rust 侧的 Silero VAD（ONNX 模型）。\n\n'
              '这一组是全局的，不跟档案走 —— 每个档案一套的话，'
              '切档案就得重建那个 1.26MB 的模型，而切换必须是立刻的。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            SettingsTextField(
              controller: _vadMinSilenceMs,
              label: '静音判定 (ms)',
              hint: '700 —— 最重要的一项。调小更跟手，太小会切断句内停顿',
              keyboardType: TextInputType.number,
            ),
            SettingsTextField(
              controller: _vadThreshold,
              label: '语音概率阈值',
              hint: '0.5 —— 0~1。调低更容易触发，调高更保守',
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
            SettingsTextField(
              controller: _vadSpeechPadMs,
              label: '前后外扩 (ms)',
              hint: '200 —— 段两端各留一点，不留会切掉第一个字',
              keyboardType: TextInputType.number,
            ),
            SettingsTextField(
              controller: _vadMinSpeechMs,
              label: '最短有效语音 (ms)',
              hint: '300 —— 比这短直接丢，咳嗽一声不触发上传',
              keyboardType: TextInputType.number,
            ),
            SettingsTextField(
              controller: _vadMaxSpeechS,
              label: '最长一句 (s)',
              hint: '60 —— 说超过就强制切开，避免一直说不完',
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        const SizedBox(height: 16),
        _notice(theme),
      ],
    );
  }

  Widget _notice(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '识别和合成都在 brain 那边，手机只负责采集、切句、上传、播放。\n'
        '/human-to-brain 把你说的话换成文本，/brain-to-human 是持续轮询的阻塞请求。\n\n'
        '对话上下文仍然只挂在 brain_id 上，删掉本机历史不影响对方记得什么。\n'
        '本机存的是「展示用的历史」（主界面上那些话），不是对话上下文。'
        '所以换一个 brain_id 也不会自动带出对方的记录 —— 那本来就是两段对话。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../config/assistant_config.dart';
import '../conversation/conversation_controller.dart';
import '../i18n/locale_controller.dart';
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
  late final TextEditingController _pvadMinCosine;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    final config = widget.controller.config;
    _vadMinSilenceMs = TextEditingController(
      text: config.vadMinSilenceMs.toString(),
    );
    _vadThreshold = TextEditingController(text: config.vadThreshold.toString());
    _vadSpeechPadMs = TextEditingController(
      text: config.vadSpeechPadMs.toString(),
    );
    _vadMinSpeechMs = TextEditingController(
      text: config.vadMinSpeechMs.toString(),
    );
    _vadMaxSpeechS = TextEditingController(
      text: config.vadMaxSpeechS.toString(),
    );
    _pvadMinCosine = TextEditingController(
      text: config.pvadMinCosine.toString(),
    );
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
    _pvadMinCosine.dispose();
    super.dispose();
  }

  List<Profile> get _profiles => widget.controller.config.profiles;

  int _indexOfFocused() {
    final index = _profiles.indexWhere(
      (p) => p.id == widget.controller.config.focusedProfileId,
    );
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

  AppLocalizations get _l10n => AppLocalizations.of(context);

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 解析失败一律回落到默认值 —— 不该因为一个手滑的输入就保存不了。
  int _int(TextEditingController c, int fallback) =>
      int.tryParse(c.text.trim()) ?? fallback;

  double _double(TextEditingController c, double fallback) =>
      double.tryParse(c.text.trim()) ?? fallback;

  Future<void> _save() async {
    final l10n = _l10n;
    final bool written;
    try {
      written = await _editor.currentState?.commit() ?? true;
      await _saveVad();
    } catch (e) {
      _toast(l10n.saveFailed('$e'));
      return;
    }
    // 编辑器的档案已经被删掉时它什么都不写。这时候弹"已保存"就是骗人：
    // 用户改的名字、填的地址一起没了，而他以为存住了。
    _toast(written ? l10n.saved : l10n.profileGoneUnsaved);
  }

  Future<void> _saveVad() async {
    final base = widget.controller.config;
    // 只写全局参数。`copyWith` 不带 brain，档案一个都不会被动到。
    await widget.controller.updateConfig(
      base.copyWith(
        vadMinSilenceMs: _int(_vadMinSilenceMs, base.vadMinSilenceMs),
        vadThreshold: _double(
          _vadThreshold,
          base.vadThreshold,
        ).clamp(0.01, 0.99),
        vadSpeechPadMs: _int(_vadSpeechPadMs, base.vadSpeechPadMs),
        vadMinSpeechMs: _int(_vadMinSpeechMs, base.vadMinSpeechMs),
        vadMaxSpeechS: _int(_vadMaxSpeechS, base.vadMaxSpeechS).clamp(1, 600),
        pvadMinCosine: _double(
          _pvadMinCosine,
          base.pvadMinCosine,
        ).clamp(0.1, 0.9),
      ),
    );
  }

  /// 创建页要在线跑 onnxruntime-web，只能开浏览器，不能内嵌。
  /// 直接落到 /enroll/，不然用户还得在主页上再点一次。
  static const _voiceprintPageUrl =
      'https://thautwarm.github.io/pp-friend/enroll/';

  Future<void> _openVoiceprintPage() async {
    final l10n = _l10n;
    try {
      final opened = await launchUrl(
        Uri.parse(_voiceprintPageUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) _toast(l10n.noAppToOpenPage);
    } catch (e) {
      _toast(l10n.openPageFailed('$e'));
    }
  }

  /// 从文件里导入声纹。只认 768 字节的 `spkemb.f32`。
  Future<void> _importVoiceprint() async {
    final l10n = _l10n;
    // 不按扩展名过滤：Android 对 `.f32` 没有标准 MIME，按 custom 过滤
    // 反而会让文件在列表里变灰。字节数校验比扩展名可靠。
    final file = await FilePicker.pickFile();
    if (file == null) return;
    final bytes = await file.readAsBytes();
    try {
      await widget.controller.importVoiceprint(bytes);
      _toast(l10n.voiceprintImported);
    } on FormatException catch (e) {
      _toast(l10n.notVoiceprint(e.message));
    } catch (e) {
      _toast(l10n.importFailed('$e'));
    }
  }

  Future<void> _removeVoiceprint() async {
    final l10n = _l10n;
    await widget.controller.removeVoiceprint();
    _toast(l10n.voiceprintRemoved);
  }

  /// 换到另一个档案：先把当前的改动落盘，再切。
  Future<void> _select(Profile profile) async {
    if (profile.id == _selectedId) return;
    final l10n = _l10n;
    // 先落盘再切。落不了就别切 —— 切过去会把这些改动无声无息地冲掉。
    try {
      await _editor.currentState?.commit();
    } catch (e) {
      _toast(l10n.saveFailedBeforeSwitch('$e'));
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
    final l10n = _l10n;
    try {
      await _editor.currentState?.commit();
    } catch (e) {
      _toast(l10n.saveFailedBeforeAdd('$e'));
      return;
    }
    final profile = Profile(id: Profile.newId(), name: l10n.newProfile);
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
    final l10n = AppLocalizations.of(context);

    // **整页跟着 controller 重建。** 保存之后名字、开关、头像都变了，
    // 而 `showSnackBar` 不会重建页面 —— 不订阅的话，改完名字按保存，
    // 下面那排 chip 还写着旧名字，看着就像没保存成功。
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(l10n.settingsTitle),
          actions: [TextButton(onPressed: _save, child: Text(l10n.save))],
          bottom: TabBar(
            controller: _tabs,
            tabs: [
              Tab(text: l10n.tabProfiles),
              Tab(text: l10n.tabGeneral),
            ],
          ),
        ),
        // 不用管"一个档案都没有"：`normalized()` 保证至少留一个（删光了它会
        // 补一个空的回来），所以下面那个下标一定落在列表里面。
        body: TabBarView(
          controller: _tabs,
          children: [_profileTab(), _vadTab(theme)],
        ),
      ),
    );
  }

  Widget _profileTab() {
    if (_profiles.isEmpty) {
      // 配置是异步读的：App 刚起来、`loadConfig()` 还没跑完时这里就是空的。
      // 旧代码直接 `_profiles[_index.clamp(0, -1)]`，release 下 build 异常
      // 只留下一个灰白页面 —— 用户看到的就是"设置打不开"。
      return Column(
        children: [
          _profileTabs(),
          const Divider(height: 1),
          Expanded(
            child: Center(
              child: Text(
                AppLocalizations.of(context).noEnabledProfiles,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        ],
      );
    }
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

  /// 档案那一排 tab，末尾一个加号。**长按可以拖动调整顺序**。
  ///
  /// 这里的顺序就是主界面滑动带上的左右顺序 —— 不是两套独立的排序。
  /// 用长按而不是直接拖：这排本身要能横向滚动，直接拖会分不清用户在
  /// 滚列表还是在换位置。
  Widget _profileTabs() {
    final l10n = AppLocalizations.of(context);
    final selected = _index;
    return SizedBox(
      height: 56,
      child: ReorderableListView.builder(
        scrollController: _chipScroll,
        scrollDirection: Axis.horizontal,
        buildDefaultDragHandles: false,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        itemCount: _profiles.length,
        // onReorderItem 已经替我们扣掉了"原项被移走"造成的下标偏移，
        // 不用再自己 `if (newIndex > oldIndex) newIndex--`。
        onReorderItem: (oldIndex, newIndex) {
          unawaited(widget.controller.moveProfile(oldIndex, newIndex));
        },
        proxyDecorator: (child, index, animation) => Material(
          color: Colors.transparent,
          elevation: 6,
          shape: const StadiumBorder(),
          child: child,
        ),
        // 加号。用 OutlinedButton 而不是另一个 chip：它是动作不是"某一页"，
        // 长得一样会让人以为点了会切到一个叫"+"的档案。
        footer: IconButton.outlined(
          onPressed: _add,
          icon: const Icon(Icons.add),
          tooltip: l10n.newProfileTooltip,
          visualDensity: VisualDensity.compact,
        ),
        itemBuilder: (context, i) {
          final profile = _profiles[i];
          return ReorderableDelayedDragStartListener(
            key: ValueKey('profile-chip-${profile.id}'),
            index: i,
            child: Padding(
              // 选中那个挂 key，用来把它滚进视野。同一时刻只有一个，
              // 所以这一个 key 够用。
              key: i == selected ? _chipKey : null,
              padding: const EdgeInsets.only(right: 8),
              child: _profileTabChip(
                profile,
                i == selected,
                () => _select(profile),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _profileTabChip(Profile profile, bool selected, VoidCallback onTap) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
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
                  semanticLabel: l10n.profileDisabled,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _vadTab(ThemeData theme) {
    final l10n = AppLocalizations.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _languageSection(l10n),
        const SizedBox(height: 16),
        SettingsSection(
          title: l10n.localSegmentation,
          children: [
            Text(
              l10n.localSegmentationBody,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            SettingsTextField(
              controller: _vadMinSilenceMs,
              label: l10n.vadMinSilenceMsLabel,
              hint: l10n.vadMinSilenceMsHint,
              keyboardType: TextInputType.number,
            ),
            SettingsTextField(
              controller: _vadThreshold,
              label: l10n.vadThresholdLabel,
              hint: l10n.vadThresholdHint,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            SettingsTextField(
              controller: _vadSpeechPadMs,
              label: l10n.vadSpeechPadMsLabel,
              hint: l10n.vadSpeechPadMsHint,
              keyboardType: TextInputType.number,
            ),
            SettingsTextField(
              controller: _vadMinSpeechMs,
              label: l10n.vadMinSpeechMsLabel,
              hint: l10n.vadMinSpeechMsHint,
              keyboardType: TextInputType.number,
            ),
            SettingsTextField(
              controller: _vadMaxSpeechS,
              label: l10n.vadMaxSpeechSLabel,
              hint: l10n.vadMaxSpeechSHint,
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        const SizedBox(height: 16),
        SettingsSection(
          title: l10n.speakerRecognition,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: widget.controller.config.pvadEnabled,
              onChanged: (enabled) => widget.controller.updateConfig(
                widget.controller.config.copyWith(pvadEnabled: enabled),
              ),
              title: Text(l10n.onlyMyVoice),
              subtitle: Text(
                widget.controller.hasVoiceprint
                    ? l10n.voiceprintImportedStatus
                    : l10n.voiceprintNeeded,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _openVoiceprintPage,
                  icon: const Icon(Icons.open_in_new),
                  label: Text(l10n.openVoiceprintPage),
                ),
                OutlinedButton.icon(
                  onPressed: _importVoiceprint,
                  icon: const Icon(Icons.file_open_outlined),
                  label: Text(
                    widget.controller.hasVoiceprint
                        ? l10n.reimportVoiceprint
                        : l10n.importVoiceprint,
                  ),
                ),
                if (widget.controller.hasVoiceprint)
                  TextButton.icon(
                    onPressed: _removeVoiceprint,
                    icon: const Icon(Icons.delete_outline),
                    label: Text(l10n.deleteVoiceprint),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l10n.voiceprintOptionalHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            // 没导入声纹时这个数没有任何意义，先不占位置。
            if (widget.controller.hasVoiceprint) ...[
              const SizedBox(height: 12),
              SettingsTextField(
                controller: _pvadMinCosine,
                label: l10n.similarityThreshold,
                hint: '0.40',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        SettingsSection(
          title: l10n.volumeKeys,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: widget.controller.config.volumeKeyClearsQueue,
              onChanged: (enabled) => widget.controller.updateConfig(
                widget.controller.config.copyWith(
                  volumeKeyClearsQueue: enabled,
                ),
              ),
              title: Text(l10n.volumeKeyClearsQueue),
              subtitle: Text(l10n.volumeKeySubtitle),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _notice(theme, l10n),
      ],
    );
  }

  Widget _languageSection(AppLocalizations l10n) {
    final locale = context.watch<LocaleController>();
    return SettingsSection(
      title: l10n.languageSection,
      children: [
        DropdownButton<String>(
          value: locale.selection,
          isExpanded: true,
          items: [
            DropdownMenuItem(
              value: LocaleController.systemValue,
              child: Text(l10n.languageFollowSystem),
            ),
            DropdownMenuItem(value: 'zh', child: Text(l10n.languageChinese)),
            DropdownMenuItem(value: 'en', child: Text(l10n.languageEnglish)),
            DropdownMenuItem(value: 'ja', child: Text(l10n.languageJapanese)),
          ],
          onChanged: (value) {
            if (value != null) locale.select(value);
          },
        ),
      ],
    );
  }

  Widget _notice(ThemeData theme, AppLocalizations l10n) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        l10n.settingsNotice,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

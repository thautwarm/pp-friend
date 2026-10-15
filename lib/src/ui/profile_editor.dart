import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../config/assistant_config.dart';
import '../conversation/conversation_controller.dart';
import 'widgets/settings_widgets.dart';

/// 一个档案的全部设置。
///
/// 它是**设置页里"档案"那个 tab 的内容**，不是独立一个页面 —— 档案之间
/// 用上面那条 tab 切换，切过来就地编辑，不用反复进出二级页。
///
/// 编辑状态（输入框里的字、挑好还没保存的头像）留在本 widget 里，落盘由
/// [ProfileEditorState.commit] 负责。父级在**切换档案之前**会调一次它 ——
/// 不然切走一次就把手上的改动丢了。
class ProfileEditor extends StatefulWidget {
  const ProfileEditor({
    super.key,
    required this.controller,
    required this.profile,
  });

  final ConversationController controller;

  /// 正在编辑的档案。**以父级从配置里现取的那一份为准**，不要缓存。
  final Profile profile;

  @override
  State<ProfileEditor> createState() => ProfileEditorState();
}

class ProfileEditorState extends State<ProfileEditor> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _brainId;
  late final TextEditingController _token;

  late int _accent;
  late bool _enabled;

  /// 新挑的头像的**临时路径**。保存时才拷进应用目录 —— 取消了直接丢掉，
  /// 不会在应用目录里留一份没人引用的图。
  String? _pickedAvatar;

  /// 用户按了"去掉头像"。
  bool _clearAvatar = false;

  int _historyBytes = 0;
  bool _busy = false;

  /// 预设主题色。用色块而不是调色盘：一眼看全、点了就跑。
  /// 第一个和全局种子色一致，默认档案看着不突兀。
  static const List<(String, int)> _presets = [
    ('靛蓝', Profile.defaultAccentColor),
    ('墨绿', 0xFF2E7D6B),
    ('陶土', 0xFF9C4B2F),
    ('紫', 0xFF7B4FA8),
    ('湖蓝', 0xFF1F6FB2),
    ('赭黄', 0xFFB0722B),
    ('玫红', 0xFFB03A5B),
    ('石板', 0xFF4A5A66),
  ];

  @override
  void initState() {
    super.initState();
    _name = TextEditingController();
    _baseUrl = TextEditingController();
    _brainId = TextEditingController();
    _token = TextEditingController();
    _load(widget.profile);
  }

  @override
  void didUpdateWidget(covariant ProfileEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只有"换了一个档案"才重填输入框。同一个档案被别处改了配置（比如
    // 主界面切了焦点）不能重填 —— 那样会把你正在敲的字冲掉。
    if (oldWidget.profile.id != widget.profile.id) _load(widget.profile);
  }

  void _load(Profile profile) {
    _name.text = profile.name;
    _baseUrl.text = profile.brain.baseUrl;
    _brainId.text = profile.brain.brainId;
    _token.text = profile.brain.token;
    _accent = profile.accentColor;
    _enabled = profile.enabled;
    _pickedAvatar = null;
    _clearAvatar = false;
    _historyBytes = 0;
    unawaited(_loadHistorySize());
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _brainId.dispose();
    _token.dispose();
    super.dispose();
  }

  /// 配置里此刻的那一份。找不到（已经被删）返回 null。
  Profile? _current() {
    final index = widget.controller.config.profiles
        .indexWhere((p) => p.id == widget.profile.id);
    return index < 0 ? null : widget.controller.config.profiles[index];
  }

  Future<void> _loadHistorySize() async {
    final bytes = await widget.controller.historyBytes(widget.profile.id);
    if (!mounted) return;
    setState(() => _historyBytes = bytes);
  }

  // ------------------------------------------------------------ 落盘

  /// 把这一屏的改动写进配置。
  ///
  /// 父级在切档案、按保存、关页面之前都会调它。**从配置里重新取一次档案
  /// 再改** —— 拿 widget 里那份快照写回会把别处刚存的字段回滚掉。
  ///
  /// 失败会抛（头像拷不进去之类），由调用方决定怎么提示。
  ///
  /// 返回**有没有真的写进去**。这个档案已经被删掉时返回 false —— 调用方
  /// 这时候不能弹"已保存"：改的名字、填的地址其实一个都没落盘。
  Future<bool> commit() async {
    if (_busy) return true; // 已经在写了，别重复写
    final current = _current();
    if (current == null) return false; // 档案已经被删了
    _busy = true;
    try {
      await widget.controller.saveProfile(current.copyWith(
        name: _name.text.trim(),
        brain: BrainConfig(
          baseUrl: _baseUrl.text.trim(),
          brainId: _brainId.text.trim(),
          token: _token.text.trim(),
        ),
        accentColor: _accent,
        enabled: _enabled,
        // 头像**不在这里清**：clearAvatar 一清，就不知道该删哪个文件了。
        // 去掉头像走 setAvatar(id, null)，它读到的还是旧文件名。
      ));

      final picked = _pickedAvatar;
      if (picked != null) {
        await widget.controller.setAvatar(widget.profile.id, picked);
      } else if (_clearAvatar) {
        await widget.controller.setAvatar(widget.profile.id, null);
      }
      _pickedAvatar = null;
      _clearAvatar = false;
    } finally {
      _busy = false;
    }
    await _loadHistorySize();
    return true;
  }

  // ------------------------------------------------------------ 头像

  Future<void> _pickAvatar() async {
    XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        // 只缩到够用的尺寸，**不裁剪**：头像原样等比铺在说话按钮上，
        // 该不该裁是显示端的事（答案是不裁，透明的地方露出底色）。
        // 缩是因为相册里的原图动辄十几 MB，拷一份进来没必要。
        maxWidth: 512,
        maxHeight: 512,
      );
    } catch (e) {
      _toast('打不开相册：$e');
      return;
    }
    if (picked == null) return; // 用户取消了

    final path = picked.path;
    setState(() {
      _pickedAvatar = path;
      _clearAvatar = false;
    });
  }

  void _dropAvatar() {
    setState(() {
      _pickedAvatar = null;
      _clearAvatar = true;
    });
  }

  /// 当前该显示哪张图。新挑的优先（想立刻看到效果），否则读盘上的。
  ImageProvider? _avatarImage() {
    if (_clearAvatar) return null;
    final picked = _pickedAvatar;
    if (picked != null) return FileImage(File(picked));
    final path = widget.controller.avatarPathOf(widget.profile);
    return path == null ? null : FileImage(File(path));
  }

  // ------------------------------------------------------------ 危险动作

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool?> _confirm({
    required String title,
    required String body,
    required String action,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('算了'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
  }

  Future<void> _clearHistory() async {
    final ok = await _confirm(
      title: '清空这个档案的历史？',
      body: '主界面上这个档案的消息会全部消失，而且找不回来。\n\n'
          'brain 那边的记忆不受影响 —— 本地存的是展示用的历史，'
          '对话上下文一直挂在 brain_id 上。',
      action: '清空',
    );
    if (ok != true) return;
    await widget.controller.clearHistory(widget.profile.id);
    await _loadHistorySize();
    _toast('已清空');
  }

  Future<void> _delete() async {
    final ok = await _confirm(
      title: '删掉「${widget.profile.displayName}」？',
      body: '这个档案的 brain 配置和主题色都会没。\n\n'
          '盘上的历史不跟着删 —— 万一删错了，那一份还在。',
      action: '删除',
    );
    if (ok != true) return;
    await widget.controller.removeProfile(widget.profile.id);
    // 删完由父级换到别的 tab，这里不自作主张 pop
  }

  // ------------------------------------------------------------ 界面

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = widget.profile;
    final focused = widget.controller.config.focusedProfileId == profile.id;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        SettingsSection(
          title: '这个档案长什么样',
          children: [
            _avatarRow(theme),
            const SizedBox(height: 14),
            SettingsTextField(
              controller: _name,
              label: '名字',
              hint: '例如 员工3 —— 留空就用 brain_id',
            ),
            const SizedBox(height: 4),
            Text(
              '主题色',
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            _swatches(theme),
          ],
        ),
        const SizedBox(height: 16),
        SettingsSection(
          title: 'Brain',
          children: [
            SettingsTextField(
              controller: _baseUrl,
              label: 'Base URL',
              hint: 'http://192.168.0.100:8000',
            ),
            SettingsTextField(
              controller: _brainId,
              label: 'brain_id',
              hint: '例如 员工3 —— 像名字一样有语义',
            ),
            SettingsTextField(
              controller: _token,
              label: 'Bearer token',
              hint: '留空表示该部署没启用鉴权，不会发这个头',
            ),
          ],
        ),
        const SizedBox(height: 16),
        SettingsSection(
          title: '状态',
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用'),
              subtitle: Text(
                _enabled
                    ? '会一直收它的消息（没聚焦时只记文字，不出声）'
                    : '不连它。历史仍然留在盘上，随时可以再打开',
                style: theme.textTheme.bodySmall,
              ),
              value: _enabled,
              onChanged: (value) => setState(() => _enabled = value),
            ),
            if (!_enabled && focused)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '它现在是主界面上选中的那个。保存之后会自动切到别的开着的档案。',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            if (_enabled && !focused) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () =>
                      widget.controller.switchProfile(profile.id),
                  icon: const Icon(Icons.swap_horiz, size: 18),
                  label: const Text('切到这个档案'),
                ),
              ),
              Text(
                '主界面上左右滑说话按钮也能切',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        SettingsSection(
          title: '历史',
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '盘上占 ${formatBytes(_historyBytes)}。\n'
                    '永久保留，没有自动清理 —— 攒到几百 MB 就自己来这里清。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                OutlinedButton(
                  onPressed: _historyBytes == 0 ? null : _clearHistory,
                  child: const Text('清空'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 24),
        Center(
          child: TextButton.icon(
            onPressed: _delete,
            icon: const Icon(Icons.delete_outline),
            label: const Text('删除这个档案'),
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
          ),
        ),
      ],
    );
  }

  Widget _avatarRow(ThemeData theme) {
    final image = _avatarImage();

    // 没头像、或者头像读不出来，就用名字的第一个字。比一个通用的小人图标
    // 好认，不同档案一眼能分开。
    Widget letter() => Text(
          widget.profile.displayName.characters.first,
          style: theme.textTheme.headlineSmall
              ?.copyWith(color: onAccentColor(Color(_accent))),
        );

    return Row(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Color(_accent),
          ),
          alignment: Alignment.center,
          clipBehavior: Clip.antiAlias,
          child: image == null
              ? letter()
              : Padding(
                  padding: const EdgeInsets.all(3),
                  child: Image(
                    image: image,
                    fit: BoxFit.contain,
                    // 文件被删了、拷坏了、或者干脆不是图片 —— 退回那个字，
                    // 别把设置页整块变成一个报错框。
                    errorBuilder: (_, _, _) => letter(),
                  ),
                ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: _pickAvatar,
                child: Text(image == null ? '选头像' : '换头像'),
              ),
              if (image != null)
                TextButton(onPressed: _dropAvatar, child: const Text('去掉')),
            ],
          ),
        ),
      ],
    );
  }

  Widget _swatches(ThemeData theme) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final (name, value) in _presets)
          Semantics(
            label: name,
            selected: value == _accent,
            child: InkWell(
              onTap: () => setState(() => _accent = value),
              customBorder: const CircleBorder(),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(value),
                  border: Border.all(
                    color: value == _accent
                        ? theme.colorScheme.onSurface
                        : Colors.transparent,
                    width: 3,
                  ),
                ),
                child: value == _accent
                    ? Icon(Icons.check, size: 18, color: onAccentColor(Color(value)))
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}

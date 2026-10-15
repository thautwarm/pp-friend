import 'package:flutter/material.dart';

import '../config/assistant_config.dart';
import '../conversation/conversation_controller.dart';

/// 配置页。
///
/// 只有 brain 相关的项 —— 识别和合成都在服务端，手机上没有任何
/// STT/TTS 参数可配。剩下一个是本地断句的静音判定时长。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final ConversationController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _brainId;
  late final TextEditingController _token;
  late final TextEditingController _vadMinSilenceMs;
  late final TextEditingController _vadThreshold;
  late final TextEditingController _vadSpeechPadMs;
  late final TextEditingController _vadMinSpeechMs;
  late final TextEditingController _vadMaxSpeechS;

  @override
  void initState() {
    super.initState();
    final config = widget.controller.config;
    _baseUrl = TextEditingController(text: config.brain.baseUrl);
    _brainId = TextEditingController(text: config.brain.brainId);
    _token = TextEditingController(text: config.brain.token);
    _vadMinSilenceMs =
        TextEditingController(text: config.vadMinSilenceMs.toString());
    _vadThreshold = TextEditingController(text: config.vadThreshold.toString());
    _vadSpeechPadMs =
        TextEditingController(text: config.vadSpeechPadMs.toString());
    _vadMinSpeechMs =
        TextEditingController(text: config.vadMinSpeechMs.toString());
    _vadMaxSpeechS = TextEditingController(text: config.vadMaxSpeechS.toString());
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _brainId.dispose();
    _token.dispose();
    _vadMinSilenceMs.dispose();
    _vadThreshold.dispose();
    _vadSpeechPadMs.dispose();
    _vadMinSpeechMs.dispose();
    _vadMaxSpeechS.dispose();
    super.dispose();
  }

  /// 解析失败一律回落到默认值 —— 这个页面不该因为一个手滑的输入而保存不了，
  /// 更不该把已经填好的 brain 配置一起丢掉。
  int _int(TextEditingController c, int fallback) =>
      int.tryParse(c.text.trim()) ?? fallback;

  double _double(TextEditingController c, double fallback) =>
      double.tryParse(c.text.trim()) ?? fallback;

  Future<void> _save() async {
    final base = widget.controller.config;
    final config = base.copyWith(
      brain: BrainConfig(
        baseUrl: _baseUrl.text.trim(),
        brainId: _brainId.text.trim(),
        token: _token.text.trim(),
      ),
      vadMinSilenceMs: _int(_vadMinSilenceMs, base.vadMinSilenceMs),
      vadThreshold: _double(_vadThreshold, base.vadThreshold).clamp(0.01, 0.99),
      vadSpeechPadMs: _int(_vadSpeechPadMs, base.vadSpeechPadMs),
      vadMinSpeechMs: _int(_vadMinSpeechMs, base.vadMinSpeechMs),
      vadMaxSpeechS: _int(_vadMaxSpeechS, base.vadMaxSpeechS).clamp(1, 600),
    );

    await widget.controller.updateConfig(config);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('配置'),
        actions: [TextButton(onPressed: _save, child: const Text('保存'))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _notice(theme),
          const SizedBox(height: 16),
          _section(
            theme,
            title: 'Brain',
            children: [
              _field(_baseUrl, 'Base URL', 'http://192.168.0.100:8000'),
              _field(_brainId, 'brain_id', '例如 员工3 —— 像名字一样有语义'),
              _field(_token, 'Bearer token', '留空表示该部署没启用鉴权，不会发这个头'),
            ],
          ),
          const SizedBox(height: 16),
          _section(
            theme,
            title: '本地断句',
            children: [
              Text(
                '切句必须留在本地：否则就得把整条麦克风流实时推给服务端，'
                '那是另一套协议。判据是 Rust 侧的 Silero VAD（ONNX 模型）。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              _field(
                _vadMinSilenceMs,
                '静音判定 (ms)',
                '700 —— 最重要的一项。调小更跟手，太小会切断句内停顿',
                keyboardType: TextInputType.number,
              ),
              _field(
                _vadThreshold,
                '语音概率阈值',
                '0.5 —— 0~1。调低更容易触发，调高更保守',
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              _field(
                _vadSpeechPadMs,
                '前后外扩 (ms)',
                '200 —— 段两端各留一点，不留会切掉第一个字',
                keyboardType: TextInputType.number,
              ),
              _field(
                _vadMinSpeechMs,
                '最短有效语音 (ms)',
                '300 —— 比这短直接丢，咳嗽一声不触发上传',
                keyboardType: TextInputType.number,
              ),
              _field(
                _vadMaxSpeechS,
                '最长一句 (s)',
                '60 —— 说超过就强制切开，避免一直说不完',
                keyboardType: TextInputType.number,
              ),
            ],
          ),
        ],
      ),
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
        '对话状态全挂在 brain_id 上，手机端不持有任何状态 —— '
        '同一个 brain_id 跨 App 重启仍是同一段对话。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }

  Widget _section(ThemeData theme,
      {required String title, required List<Widget> children}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    String hint, {
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }
}

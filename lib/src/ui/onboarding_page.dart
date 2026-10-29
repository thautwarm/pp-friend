import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../conversation/conversation_controller.dart';
import '../voice/mic_permission.dart';
import '../voice/network_check.dart';

/// 是否已经完成过首次引导。
const String onboardingDonePrefKey = 'onboarding_done_v2';

/// 读首次引导的完成标记。
Future<bool> onboardingCompleted() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(onboardingDonePrefKey) ?? false;
}

/// 权限检查 / 首次引导。
///
/// **必须全部通过才能继续**：麦克风要真的给到，brain 地址要真的能发出
/// HTTP 请求，局域网地址还要真的能连上。只探测 TCP 是不够的 —— 上传用的
/// 是 Dart 的 HTTP 栈，两层之间完全可能一层通、一层不通。
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({
    super.key,
    required this.controller,
    this.firstRun = false,
    this.onDone,
    this.micStatusLoader,
    this.localStatusLoader,
    this.httpChecker,
  });

  final ConversationController controller;

  /// 首次启动：完成后回调切到主界面；否则按普通路由返回。
  final bool firstRun;
  final VoidCallback? onDone;

  /// 测试注入点：widget 测试跑在假时钟里，真实平台消息可能永远不回来。
  final Future<MicPermissionState> Function()? micStatusLoader;
  final Future<LocalNetworkState> Function(String baseUrl)? localStatusLoader;
  final Future<BrainHttpCheck> Function(String baseUrl)? httpChecker;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final TextEditingController _url = TextEditingController();
  final TextEditingController _brainId = TextEditingController();

  MicPermissionState? _mic;
  LocalNetworkState? _local;
  BrainHttpCheck? _http;
  bool _checking = false;
  bool _requestingMic = false;
  bool _autoChecked = false;

  @override
  void initState() {
    super.initState();
    final brain = widget.controller.config.brain;
    _url.text = brain.baseUrl;
    _brainId.text = brain.brainId;
    _refreshMic();
    // 配置是异步读的：此刻拿到的可能还是空的，等 loadConfig 回来再补。
    widget.controller.addListener(_adoptLoadedConfig);
    if (brain.isUsable) {
      _autoChecked = true;
      _runChecks();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_adoptLoadedConfig);
    _url.dispose();
    _brainId.dispose();
    super.dispose();
  }

  void _adoptLoadedConfig() {
    final brain = widget.controller.config.brain;
    if (_url.text.isNotEmpty || brain.baseUrl.isEmpty) return;
    _url.text = brain.baseUrl;
    _brainId.text = brain.brainId;
    if (!_autoChecked && brain.isUsable) {
      _autoChecked = true;
      _runChecks();
    }
  }

  Future<void> _refreshMic() async {
    final state = await (widget.micStatusLoader ?? micPermissionStatus)();
    if (!mounted) return;
    setState(() => _mic = state);
  }

  Future<void> _requestMic() async {
    setState(() => _requestingMic = true);
    final granted = await requestMicPermission();
    if (!mounted) return;
    setState(() => _requestingMic = false);
    await _refreshMic();
    if (!granted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).permissionRequestFailed),
        ),
      );
    }
  }

  /// 保存地址，然后**同时**探测 TCP（本地网络权限）和 HTTP（真实链路）。
  Future<void> _runChecks() async {
    if (_checking) return;
    final url = _url.text.trim();
    final id = _brainId.text.trim();

    setState(() {
      _checking = true;
      _http = null;
      if (url.isEmpty || id.isEmpty) {
        _local = LocalNetworkState.notConfigured;
      }
    });

    if (url.isNotEmpty && id.isNotEmpty) {
      final profile = widget.controller.config.focusedProfile;
      if (profile != null &&
          (profile.brain.baseUrl != url || profile.brain.brainId != id)) {
        await widget.controller.saveProfile(
          profile.copyWith(
            brain: profile.brain.copyWith(baseUrl: url, brainId: id),
          ),
        );
        if (!mounted) return;
      }
    }

    if (url.isEmpty || id.isEmpty) {
      if (!mounted) return;
      setState(() => _checking = false);
      return;
    }

    final httpResult = await (widget.httpChecker ?? checkBrainHttp)(url);
    if (!mounted) return;

    final host = Uri.tryParse(url)?.host ?? '';
    final LocalNetworkState local;
    if (looksLikeLocalNetworkHost(host)) {
      local = await (widget.localStatusLoader ?? checkLocalNetwork)(url);
    } else {
      // 公网 brain 不需要本地网络权限，别显示一行用不上的东西。
      local = LocalNetworkState.unsupported;
    }
    if (!mounted) return;

    setState(() {
      _http = httpResult;
      _local = local;
      _checking = false;
    });
  }

  bool get _needsLocalNetwork {
    if (_local == LocalNetworkState.unsupported) return false;
    final host = Uri.tryParse(_url.text.trim())?.host ?? '';
    return looksLikeLocalNetworkHost(host);
  }

  bool get _canContinue {
    if (_checking) return false;
    if (_mic != MicPermissionState.granted) return false;
    if (_url.text.trim().isEmpty || _brainId.text.trim().isEmpty) return false;
    if (_http?.ok != true) return false;
    if (_needsLocalNetwork && _local != LocalNetworkState.ready) return false;
    return true;
  }

  Future<void> _finish() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(onboardingDonePrefKey, true);
    if (!mounted) return;
    final done = widget.onDone;
    if (done != null) {
      done();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final canContinue = _canContinue;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.onboardingTitle),
        automaticallyImplyLeading: !widget.firstRun,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          Text(
            l10n.onboardingIntro,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          _brainCard(theme, l10n),
          const SizedBox(height: 16),
          _permissionCard(
            theme: theme,
            icon: Icons.mic_none_rounded,
            title: l10n.microphonePermission,
            body: l10n.microphonePermissionBody,
            status: _micStatusText(l10n),
            statusColor: _statusColor(theme, granted: _mic == MicPermissionState.granted),
            hint: _mic == MicPermissionState.granted
                ? null
                : l10n.micSettingsPath,
            actions: _micActions(l10n),
          ),
          if (_needsLocalNetwork) ...[
            const SizedBox(height: 16),
            _permissionCard(
              theme: theme,
              icon: Icons.lan_outlined,
              title: l10n.localNetworkPermission,
              body: l10n.localNetworkPermissionBody,
              status: _localStatusText(l10n),
              statusColor: _statusColor(
                theme,
                granted: _local == LocalNetworkState.ready,
              ),
              hint: l10n.localNetworkSettingsPath,
              actions: _localActions(l10n),
            ),
          ],
          const SizedBox(height: 28),
          FilledButton(
            onPressed: canContinue ? _finish : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(l10n.onboardingStart),
            ),
          ),
          if (!canContinue) ...[
            const SizedBox(height: 10),
            Text(
              l10n.continueBlocked,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 状态文案

  String _micStatusText(AppLocalizations l10n) {
    return switch (_mic) {
      MicPermissionState.granted => l10n.permissionGranted,
      MicPermissionState.denied => l10n.permissionDenied,
      MicPermissionState.restricted => l10n.permissionRestricted,
      MicPermissionState.notDetermined => l10n.permissionNotDetermined,
      MicPermissionState.unknown || null => l10n.permissionUnknown,
    };
  }

  String _localStatusText(AppLocalizations l10n) {
    if (_checking) return l10n.checking;
    return switch (_local) {
      LocalNetworkState.ready => l10n.localNetworkReady,
      LocalNetworkState.unavailable => l10n.localNetworkUnavailable,
      LocalNetworkState.notConfigured || null => l10n.localNetworkNotConfigured,
      LocalNetworkState.unsupported => l10n.localNetworkUnsupported,
    };
  }

  String _brainStatusText(AppLocalizations l10n) {
    if (_checking) return l10n.checking;
    if (_url.text.trim().isEmpty || _brainId.text.trim().isEmpty) {
      return l10n.brainNotConfigured;
    }
    final http = _http;
    if (http == null) return l10n.notChecked;
    if (http.ok) return l10n.brainHttpOk(http.statusCode ?? 0);
    if (http.invalid) return l10n.invalidBrainUrl;
    if (http.timedOut) return l10n.brainHttpTimeout;
    return l10n.brainHttpError(http.error ?? '');
  }

  Color _statusColor(ThemeData theme, {required bool granted}) {
    if (granted) return theme.colorScheme.primary;
    return theme.colorScheme.error;
  }

  Color _brainStatusColor(ThemeData theme) {
    final http = _http;
    if (http == null) return theme.colorScheme.onSurfaceVariant;
    return http.ok ? theme.colorScheme.primary : theme.colorScheme.error;
  }

  // ---------------------------------------------------------------- 操作

  List<Widget> _micActions(AppLocalizations l10n) {
    if (_requestingMic) {
      return const [
        SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ];
    }
    if (_mic == MicPermissionState.granted) {
      return [
        TextButton(
          onPressed: openMicSettings,
          child: Text(l10n.openSystemSettings),
        ),
      ];
    }
    return [
      FilledButton(
        onPressed: _requestMic,
        child: Text(l10n.requestPermission),
      ),
      TextButton(
        onPressed: openMicSettings,
        child: Text(l10n.openSystemSettings),
      ),
    ];
  }

  List<Widget> _localActions(AppLocalizations l10n) {
    return [
      FilledButton(
        onPressed: _checking ? null : _runChecks,
        child: Text(_checking ? l10n.checking : l10n.checkNow),
      ),
      TextButton(
        onPressed: openLocalNetworkSettings,
        child: Text(l10n.openSystemSettings),
      ),
    ];
  }

  // ---------------------------------------------------------------- 组件

  Widget _brainCard(ThemeData theme, AppLocalizations l10n) {
    final canCheck = !_checking &&
        _url.text.trim().isNotEmpty &&
        _brainId.text.trim().isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.hub_outlined, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.brainEndpointTitle,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              Text(
                _brainStatusText(l10n),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: _brainStatusColor(theme),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autofillHints: const [AutofillHints.url],
            decoration: InputDecoration(
              labelText: l10n.brainBaseUrlLabel,
              hintText: 'http://192.168.0.102:18781',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => setState(() {
              _http = null;
            }),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _brainId,
            decoration: InputDecoration(
              labelText: l10n.brainIdLabel,
              hintText: 'test2',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => setState(() {
              _http = null;
            }),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonal(
                onPressed: canCheck ? _runChecks : null,
                child: Text(_checking ? l10n.checking : l10n.saveAndCheck),
              ),
            ],
          ),
          if (_http != null && !_http!.ok) ...[
            const SizedBox(height: 8),
            Text(
              _brainStatusText(l10n),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _permissionCard({
    required ThemeData theme,
    required IconData icon,
    required String title,
    required String body,
    required String status,
    required Color statusColor,
    required String? hint,
    required List<Widget> actions,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(title, style: theme.textTheme.titleMedium),
              ),
              Text(
                status,
                style: theme.textTheme.labelMedium?.copyWith(color: statusColor),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 6),
            Text(
              hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: actions),
        ],
      ),
    );
  }
}

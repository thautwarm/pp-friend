import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'assistant_config.dart';

/// 配置的本地持久化。
class ConfigStore {
  static const _key = 'assistant_config_v1';

  Future<AssistantConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const AssistantConfig();
    try {
      return AssistantConfig.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );
    } catch (_) {
      // 配置损坏时退回默认值，而不是让整个 App 起不来
      return const AssistantConfig();
    }
  }

  Future<void> save(AssistantConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(config.toJson()));
  }
}

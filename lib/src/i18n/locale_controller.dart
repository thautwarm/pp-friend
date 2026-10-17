import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 界面语言。
///
/// `null` 表示跟随系统 —— 系统是中文就用中文，其余一律英文（英文是
/// 兜底，总比显示一堆方框强）。选择单独存一个 key，不塞进
/// `assistant_config_v1`：语言是界面偏好，跟档案和 brain 配置无关，
/// 改语言也不该触发配置保存。
class LocaleController extends ChangeNotifier {
  static const _key = 'ui_locale_v1';

  /// 顺序有讲究：第一个是系统语言匹配不上时的兜底。
  static const supported = [Locale('zh'), Locale('en'), Locale('ja')];

  Locale? _locale;
  Locale? get locale => _locale;

  /// 下拉框里“跟随系统”的占位值。Locale 本身没法表达“没有偏好”。
  static const systemValue = 'system';

  String get selection => _locale?.languageCode ?? systemValue;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_key) ?? '';
    if (code == 'zh' || code == 'en' || code == 'ja') _locale = Locale(code);
    notifyListeners();
  }

  Future<void> select(String value) async {
    final next = value == systemValue ? null : Locale(value);
    if (next != null && !supported.contains(next)) return;
    if (next?.languageCode == _locale?.languageCode) return;
    _locale = next;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    if (next == null) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, next.languageCode);
    }
  }
}

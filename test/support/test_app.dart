import 'package:flutter/material.dart';
import 'package:pp_friend/l10n/app_localizations.dart';
import 'package:pp_friend/src/i18n/locale_controller.dart';
import 'package:provider/provider.dart';

/// 测试用的 MaterialApp：带上本地化代理和语言 provider。
///
/// 默认锁中文 —— 现有断言写的都是中文文案，测试机的系统语言通常是 en_US，
/// 不锁的话会解析成英文、断言全挂。
Widget testApp(Widget home, {Locale locale = const Locale('zh')}) {
  return ChangeNotifierProvider.value(
    value: LocaleController(),
    child: MaterialApp(
      locale: locale,
      supportedLocales: LocaleController.supported,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: home,
    ),
  );
}

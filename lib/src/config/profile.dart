import 'dart:math';

import 'brain_config.dart';

/// 一个档案的运行时状态。
///
/// **它是推导出来的，不落盘。** 盘上只存两样东西：一个全局的"当前聚焦是
/// 谁"，以及每个档案自己的 `enabled`。把三个状态直接存下来，迟早会出现
/// 两个档案都标着"聚焦"这种自相矛盾的数据；而推导出来的状态不可能自相
/// 矛盾。
enum ProfileState {
  /// 正在完整交互的那个：上行、播放、消息流全都归它。
  focused,

  /// 还活着，但只收 `/brain-to-human`：文字记进自己的历史，音频丢掉不播。
  active,

  /// 用户关掉了。不轮询，不记消息，历史仍然留在盘上。
  closed,
}

/// 一个档案（profile）：一套独立的 brain 配置和一份独立的历史。
///
/// 用途是"同时跟几个 brain 保持联系"。注意**同一时刻只有一个档案在真正
/// 交互** —— 麦克风和扬声器全机只有一份，这一点决定了很多设计（见
/// [ProfileState] 和 `ConversationController` 的运行模型）。
class Profile {
  const Profile({
    required this.id,
    this.name = '',
    this.brain = const BrainConfig(),
    this.accentColor = defaultAccentColor,
    this.avatarFile,
    this.enabled = true,
  });

  /// 稳定不变的本地 id，**同时当历史目录名用**。
  ///
  /// 不能拿 brainId 当 id：brainId 是用户起的名字，可以改、可以重名、
  /// 可以带中文和斜杠，做目录名一定出事。
  final String id;

  /// 显示名。留空就退回 brainId。
  final String name;

  final BrainConfig brain;

  /// 说话按钮的主题色，0xAARRGGBB。
  final int accentColor;

  /// 头像在应用目录里的**文件名**，不是相册里的原图路径。
  ///
  /// 存文件名是因为相册的权限位会失效：存着 `content://...` 那种路径的话，
  /// 过一阵子图就没了。选图的时候拷一份进来。
  final String? avatarFile;

  /// 用户是否启用。false 就是"关闭"状态。
  final bool enabled;

  /// 和 `main.dart` 里写死的那个种子色一致，默认档案看着不会突兀。
  static const int defaultAccentColor = 0xFF5B6ABF;

  /// 新建档案时用的 id 前缀。
  static const String idPrefix = 'p_';

  /// id 会直接当目录名，所以只允许这几个字符。
  ///
  /// 存储层还有一道同样的检查兜着（`FileMessageStore._profile`）——
  /// 那一道是防止配置被手工改坏之后写到目录外面去。
  static final RegExp _validId = RegExp(r'^[A-Za-z0-9_-]+$');

  static bool isValidId(String id) => _validId.hasMatch(id);

  static final Random _random = Random();

  /// 造一个新 id。
  ///
  /// **只在用户新建档案的时候调一次。** 千万别在 `fromJson` 里生成 ——
  /// 解析会被反复触发（改个配置就重新存读一遍），每次随机就等于把上一份
  /// 历史目录变成孤儿。
  static String newId() {
    final millis = DateTime.now().millisecondsSinceEpoch;
    final suffix = _random.nextInt(1 << 24).toRadixString(36);
    return '$idPrefix${millis}_$suffix';
  }

  /// 界面上显示的名字。三级回退：自定义名、brainId、兜底。
  String get displayName {
    if (name.trim().isNotEmpty) return name.trim();
    if (brain.brainId.trim().isNotEmpty) return brain.brainId.trim();
    return '未命名';
  }

  bool get isUsable => brain.isUsable;

  /// 推导这个档案当前是什么状态。
  ///
  /// **先判 `enabled` 再判聚焦。** 关掉的档案什么都不跑（不轮询、不记消息），
  /// 它不该因为"焦点恰好还指着它"就被当成聚焦态 —— 那是配置来不及归一化时
  /// 的中间状态，界面按"关闭"显示更接近事实。
  ProfileState stateIn(String focusedId) {
    if (!enabled) return ProfileState.closed;
    return id == focusedId ? ProfileState.focused : ProfileState.active;
  }

  Profile copyWith({
    String? name,
    BrainConfig? brain,
    int? accentColor,
    String? avatarFile,
    bool clearAvatar = false,
    bool? enabled,
  }) =>
      Profile(
        id: id,
        name: name ?? this.name,
        brain: brain ?? this.brain,
        accentColor: accentColor ?? this.accentColor,
        avatarFile: clearAvatar ? null : (avatarFile ?? this.avatarFile),
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'brain': brain.toJson(),
        'accentColor': accentColor,
        if (avatarFile != null) 'avatarFile': avatarFile,
        'enabled': enabled,
      };

  /// 解析一项。**数据不可用就返回 null**，由调用方跳过这一项。
  ///
  /// 尤其是 id 非法的时候必须丢掉：留着它会让历史写到意料之外的目录去。
  ///
  /// 其余字段**一律不能抛**。抛出去不是"跳过这一项"：`ConfigStore.load`
  /// 会兜住异常、返回一份默认配置 —— 于是坏了一个字段，全部档案连同
  /// 用户的 baseUrl / brain_id / token 一起归零，而且下一次保存就把这份
  /// 空的写回盘上。所以类型不对就当这个字段没填。
  static Profile? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || !isValidId(id)) return null;

    final brain = json['brain'];
    return Profile(
      id: id,
      name: _string(json['name']),
      brain: BrainConfig.fromJson(
        brain is Map ? brain.cast<String, dynamic>() : const {},
      ),
      accentColor: _int(json['accentColor'], defaultAccentColor),
      avatarFile: json['avatarFile'] is String ? json['avatarFile'] as String : null,
      enabled: _bool(json['enabled'], true),
    );
  }

  static String _string(Object? value, [String fallback = '']) =>
      value is String ? value : fallback;

  static int _int(Object? value, int fallback) =>
      value is num ? value.toInt() : fallback;

  static bool _bool(Object? value, bool fallback) =>
      value is bool ? value : fallback;
}

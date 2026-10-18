import 'package:pp_friend/src/config/assistant_config.dart';

/// 造一个**只配了一个档案**的配置。
///
/// 测试里绝大多数场景就是这个形状：一个 brain、一份历史。多档案的测试
/// 自己拼 `profiles` 列表，不用这个。
///
/// 之所以要有这个帮手，是因为 `AssistantConfig` 的 `brain` 现在是计算属性
/// 而不是构造参数 —— 直接 `AssistantConfig(brain: ...)` 会编译不过，
/// 而每处都手写三层嵌套的 profiles 列表又太吵。
AssistantConfig configWithBrain(
  BrainConfig brain, {
  bool bargeIn = false,
  String? name,
}) => AssistantConfig(
  profiles: [
    Profile(
      id: AssistantConfig.defaultProfileId,
      name: name ?? '',
      brain: brain,
    ),
  ],
  bargeIn: bargeIn,
);

/// brain API 配置。
///
/// 注意这里**没有 STT / TTS 的字段** —— 识别和合成都在 brain 那边，
/// 手机只负责采集、切句、上传、播放。
class BrainConfig {
  const BrainConfig({this.baseUrl = '', this.brainId = '', this.token = ''});

  /// 例如 http://192.168.0.100:8000。留空则无法开始对话。
  final String baseUrl;

  /// 会话句柄。**像人的名字一样有语义**，由用户起名，不是生成的。
  ///
  /// 状态按名字存在服务端，所以同一个 brain_id 跨 App 重启仍是同一段对话；
  /// 想开一段全新的对话，换个名字就行。
  final String brainId;

  /// Bearer token。**可以为空** —— 表示该部署没启用鉴权，
  /// 此时客户端不发 Authorization 头（而不是发一个空的 `Bearer `）。
  final String token;

  bool get isUsable => baseUrl.trim().isNotEmpty && brainId.trim().isNotEmpty;

  BrainConfig copyWith({String? baseUrl, String? brainId, String? token}) =>
      BrainConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        brainId: brainId ?? this.brainId,
        token: token ?? this.token,
      );

  Map<String, dynamic> toJson() => {
    'baseUrl': baseUrl,
    'brainId': brainId,
    'token': token,
  };

  /// 类型不对就当那个字段没填。**不能抛** —— 抛出去会被
  /// `ConfigStore.load` 兜成"整份配置归零"，用户填好的地址一起没。
  factory BrainConfig.fromJson(Map<String, dynamic> json) => BrainConfig(
    baseUrl: _string(json['baseUrl']),
    brainId: _string(json['brainId']),
    token: _string(json['token']),
  );

  static String _string(Object? value) => value is String ? value : '';
}

/// 消息流里的一条。
///
/// 人说的话来自 `/human-to-brain`，AI 说的话来自 `/brain-to-human`，两条来源互相独立，
/// 所以这里**只记录事实和顺序**，不假设谁一定在谁后面。
class ConversationMessage {
  ConversationMessage({
    required this.role,
    required this.text,
    DateTime? at,
    this.seq = 0,
  }) : at = at ?? DateTime.now();

  final MessageRole role;
  final String text;
  final DateTime at;

  /// 这个档案内的序号，从 1 开始连续。
  ///
  /// 落盘后它同时是两个东西：分页游标（往上翻要读 "`seq` 小于这个的那些"），
  /// 以及"是不是有新消息"的判据。**不能用列表长度代替** —— 内存窗口会裁剪，
  /// 长度会到顶不再增长；往上翻历史又会让长度变大，正好和第 5 节那两条
  /// 判断相反。内存里读回来的历史也带着盘上的 seq，所以它是跨会话稳定的。
  ///
  /// 0 表示"还没落盘"。只有落盘那一刻才由 store 赋值。
  final int seq;

  String get time {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  }

  /// 磁盘格式的版本号。
  ///
  /// 读到比这个大的版本就跳过那一行 —— 老版本遇到新版本写的文件时，
  /// 宁可少显示几条，也不要按老规矩解析出乱七八糟的东西。
  static const int schemaVersion = 1;

  Map<String, dynamic> toJson() => {
    'v': schemaVersion,
    'n': seq,
    // 单字符的 role，省体积。这是追加写的文件，键名会乘以几十万次。
    'r': _roleCode[role] ?? 'n',
    't': text,
    // 存 UTC，读的时候再转本地。存本地时间的话，跨时区或者夏令时
    // 切换之后，历史里的时间会集体偏移。
    'a': at.toUtc().toIso8601String(),
  };

  /// 解析一行。**数据不可用就返回 null**，让调用方跳过这一行继续读。
  ///
  /// 不用抛异常是为了配合"坏行跳过"：一条坏数据不该让整个历史读不出来。
  static ConversationMessage? fromJson(Map<String, dynamic> json) {
    final version = (json['v'] as num?)?.toInt() ?? schemaVersion;
    if (version > schemaVersion) return null;

    final text = json['t'];
    if (text is! String) return null;

    final rawAt = json['a'];
    final at = rawAt is String ? DateTime.tryParse(rawAt)?.toLocal() : null;

    return ConversationMessage(
      role: _roleFromCode(json['r']),
      text: text,
      at: at,
      seq: (json['n'] as num?)?.toInt() ?? 0,
    );
  }

  static const Map<MessageRole, String> _roleCode = {
    MessageRole.user: 'u',
    MessageRole.assistant: 'a',
    MessageRole.note: 'n',
  };

  /// 认不出的 role 一律当 `note`（居中灰字）。
  ///
  /// 比丢弃整行好：文字还在，只是排版降级。丢弃的话用户会以为那段话没说过。
  static MessageRole _roleFromCode(Object? code) => switch (code) {
    'u' => MessageRole.user,
    'a' => MessageRole.assistant,
    _ => MessageRole.note,
  };
}

enum MessageRole {
  user,
  assistant,

  /// 客户端自己写的一行提示，不是谁说的一句话。
  ///
  /// 目前有两种：闭麦期间积累的那几秒在界面上留个痕 —— "这句没发出去"；
  /// 以及切档案时打断了没播完的语音。
  /// 之所以要留，是因为**静默的开关最吓人**：不写一行的话，用户事后分不清
  /// 刚才那几句是闭麦期间说的，还是压根没被识别到。
  note,
}

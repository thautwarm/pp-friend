/// 消息流里的一条。
///
/// 人说的话来自 `/human-to-brain`，AI 说的话来自 `/brain-to-human`，两条来源互相独立，
/// 所以这里**只记录事实和顺序**，不假设谁一定在谁后面。
class ConversationMessage {
  ConversationMessage({
    required this.role,
    required this.text,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final MessageRole role;
  final String text;
  final DateTime at;

  String get time {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  }
}

enum MessageRole {
  user,
  assistant,

  /// 客户端自己写的一行提示，不是谁说的一句话。
  ///
  /// 目前只有一种：闭麦期间积累的那几秒在界面上留个痕 —— "这句没发出去"。
  /// 之所以要留，是因为**静默的开关最吓人**：不写一行的话，用户事后分不清
  /// 刚才那几句是闭麦期间说的，还是压根没被识别到。
  note,
}

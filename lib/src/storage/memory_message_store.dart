import '../conversation/message.dart';
import 'message_store.dart';

/// 只存在内存里的历史。
///
/// 两个用途：
///
///  - 测试。单元测试不该碰真实文件系统，注入这个就完全隔离了。
///  - **降级**。拿不到应用目录时（非 Android 平台、或者取目录本身失败）
///    退化成这个。这时候历史只在本次进程内有效，重启就没了 —— 这件事
///    必须让用户看见，不能悄悄退化成"看起来有历史其实没有"。
class MemoryMessageStore implements MessageStore {
  MemoryMessageStore({this.limit = 1000});

  /// 每个档案最多留多少条。内存版没有磁盘兜底，必须有个上限。
  final int limit;

  final Map<String, List<ConversationMessage>> _byProfile = {};

  List<ConversationMessage> _of(String profileId) =>
      _byProfile.putIfAbsent(profileId, () => []);

  @override
  Future<List<ConversationMessage>> loadRecent(
    String profileId, {
    int limit = 300,
  }) async {
    final all = _of(profileId);
    if (all.length <= limit) return List.of(all);
    return all.sublist(all.length - limit);
  }

  @override
  Future<List<ConversationMessage>> loadOlder(
    String profileId, {
    required int beforeSeq,
    int limit = 50,
  }) async {
    final older = _of(profileId).where((m) => m.seq < beforeSeq).toList();
    if (older.length <= limit) return older;
    return older.sublist(older.length - limit);
  }

  @override
  Future<ConversationMessage> append(
    String profileId, {
    required MessageRole role,
    required String text,
    DateTime? at,
  }) async {
    final all = _of(profileId);
    final message = ConversationMessage(
      role: role,
      text: text,
      at: at,
      seq: (all.isEmpty ? 0 : all.last.seq) + 1,
    );
    all.add(message);
    if (all.length > limit) all.removeRange(0, all.length - limit);
    return message;
  }

  @override
  Future<int> lastSeq(String profileId) async {
    final all = _of(profileId);
    return all.isEmpty ? 0 : all.last.seq;
  }

  @override
  Future<void> clear(String profileId) async {
    _byProfile.remove(profileId);
  }

  @override
  Future<int> sizeBytes(String profileId) async {
    // 条数是唯一的量度；内存里没有字节的概念，报条数没有意义，
    // 所以给一个粗略的估算，够设置页显示"本次会话的消息量"了。
    return _of(profileId).length * 200;
  }
}

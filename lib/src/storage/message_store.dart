import '../conversation/message.dart';

/// 消息历史的读写。
///
/// **存的只是展示历史，不是对话上下文。** brain 那边按 brain_id 维护的会话
/// 才是唯一的事实来源，这里落盘的东西从来不参与任何请求，只是让用户重开
/// App 之后还能看见以前聊过什么。清掉它不影响对话，换 brain_id 也不会
/// 自动带出一段新历史。
///
/// 一个档案一份历史，档案之间互不可见 —— 所以每个方法都带 `profileId`。
///
/// 分页一律用 `seq` 当游标，不用"已加载多少条"。理由是内存窗口会裁剪：
/// 用条数当游标的话，裁掉头部之后同一个条数会指向不同的消息，
/// 往上翻会重复或者漏。
abstract class MessageStore {
  /// 最近 `limit` 条，按时间升序（老的在前）。
  ///
  /// 盘上一条都没有时返回空列表，不抛异常 —— "没有历史"是正常状态，
  /// 第一次用这个档案就是这样的。
  Future<List<ConversationMessage>> loadRecent(String profileId, {int limit});

  /// 比 `beforeSeq` 早的 `limit` 条，同样按时间升序。
  ///
  /// 往上翻历史用。没有更早的了就返回空列表。
  Future<List<ConversationMessage>> loadOlder(
    String profileId, {
    required int beforeSeq,
    int limit,
  });

  /// 落一条。**seq 由 store 赋值**（盘上最后一条加一），返回值带着它。
  ///
  /// 让 store 发号而不是调用方自己算，是因为发号需要知道盘上的状态 ——
  /// 调用方手里的内存窗口可能已经裁剪过，算出来的号会和盘上撞。
  ///
  /// 返回的是落盘之后的那条消息，调用方直接拿它进内存窗口，不要自己再造一条。
  Future<ConversationMessage> append(
    String profileId, {
    required MessageRole role,
    required String text,
    DateTime? at,
  });

  /// 盘上最后一条的 seq，空历史是 0。
  Future<int> lastSeq(String profileId);

  /// 删掉这个档案的全部历史。头像和配置不受影响。
  Future<void> clear(String profileId);

  /// 这个档案的历史占多少字节。0 表示没有历史或者读不到。
  Future<int> sizeBytes(String profileId);
}

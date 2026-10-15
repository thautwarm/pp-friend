import 'dart:async';
import 'dart:typed_data';

/// 排队等着上传的一句话。
class QueuedUtterance {
  const QueuedUtterance({
    required this.pcm16le,
    required this.sampleRate,
    required this.durationSeconds,
  });

  final Uint8List pcm16le;
  final int sampleRate;
  final double durationSeconds;
}

/// `/human-to-brain` 的串行请求队列。
///
/// 为什么必须串行：VAD 切句和网络往返是两个速度。你连续说三句话，
/// 上传可能只完成了一句 —— 并发发出去的话，服务端拿到的顺序就乱了。
/// 排队保证**按你说的顺序**被处理。
///
/// 队列有上限：如果上传一直追不上你说话的速度，继续排队只会让延迟
/// 无限增长（而且排在前面的早就没意义了）。满了就丢最旧的。
class UtteranceQueue {
  UtteranceQueue({
    required this.onSend,
    this.maxPending = 8,
  });

  final Future<void> Function(QueuedUtterance utterance) onSend;
  final int maxPending;

  final List<QueuedUtterance> _pending = <QueuedUtterance>[];
  bool _draining = false;
  bool _disposed = false;

  /// 因为队列满而被丢弃的句子数。
  int _dropped = 0;
  int get dropped => _dropped;

  int get pendingCount => _pending.length;

  void add(QueuedUtterance utterance) {
    if (_disposed) return;
    _pending.add(utterance);
    while (_pending.length > maxPending) {
      _pending.removeAt(0);
      _dropped++;
    }
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_draining || _disposed) return;
    _draining = true;
    try {
      while (_pending.isNotEmpty && !_disposed) {
        final utterance = _pending.removeAt(0);
        try {
          await onSend(utterance);
        } catch (_) {
          // 单句失败不能卡死整个队列 —— onSend 自己负责报错，
          // 这里只保证队列继续往前走。
        }
      }
    } finally {
      _draining = false;
    }
  }

  void clear() {
    _pending.clear();
    _dropped = 0;
  }

  void dispose() {
    _disposed = true;
    _pending.clear();
  }
}

import 'package:flutter/material.dart';

import '../conversation/conversation_controller.dart';
import '../voice/voice_engine.dart';
import 'widgets/level_meter.dart';

/// 调试面板。
///
/// 主界面刻意只留一个按钮，所以电平表、AEC 实测、试听、事件日志全部搬到这里。
/// 日常不用打开，但调 AEC 的时候这里就是工作台。
class DebugPage extends StatelessWidget {
  const DebugPage({super.key, required this.controller});

  final ConversationController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('调试面板')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              _statusCard(context),
              const SizedBox(height: 16),
              _levelCard(context),
              const SizedBox(height: 16),
              _playbackControlCard(context),
              const SizedBox(height: 16),
              _aecCard(context),
              const SizedBox(height: 16),
              _logCard(context),
            ],
          ),
        );
      },
    );
  }

  // -------------------------------------------------------------- 状态

  Widget _statusCard(BuildContext context) {
    final theme = Theme.of(context);
    final format = controller.format;
    final stats = controller.segmenterStats;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _chip(context, controller.active ? '对话中' : '未开始', controller.active),
                if (format != null) _chip(context, '${format.sampleRate}Hz', true),
                if (controller.segmenterName != null)
                  _chip(context, controller.segmenterName!, true),
                _chip(context, controller.speaking ? 'AI 说话中' : 'AI 静默', controller.speaking),
                _chip(
                  context,
                  'prob ${stats.probability.toStringAsFixed(2)}',
                  stats.speaking,
                ),
                _chip(context, '闭麦', controller.micMuted),
                _chip(context, '打断', controller.bargeIn),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _stat(
                    context,
                    '丢弃采集帧',
                    '${controller.droppedMicFrames}',
                    controller.droppedMicFrames > 0
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: _stat(
                    context,
                    '播放积压帧',
                    '${controller.backlogFrames}',
                    theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _stat(
                    context,
                    '上传队列',
                    '${controller.queuedUtterances}',
                    theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: _stat(
                    context,
                    '丢弃句子',
                    '${controller.droppedUtterances}',
                    controller.droppedUtterances > 0
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: _stat(
                    context,
                    '/brain-to-human',
                    controller.polling ? '轮询中' : '停止',
                    controller.polling
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: _stat(
                    context,
                    '上行编码',
                    controller.opusUpstream ? 'Opus' : 'WAV',
                    controller.opusUpstream
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _stat(
                    context,
                    '断句缓冲',
                    '${stats.bufferedMs}ms',
                    theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: _stat(
                    context,
                    '断句丢弃',
                    '${stats.droppedMs}ms',
                    stats.droppedMs > 0
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: _stat(
                    context,
                    '强制切句',
                    '${stats.forcedCuts}',
                    theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: _stat(
                    context,
                    'feed 耗时',
                    '${stats.lastFeedMicros}µs',
                    // 单帧超过 3ms 就意味着单核 15% 被吃掉，该挪出 main isolate 了
                    stats.lastFeedMicros > 3000
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonal(
                onPressed: controller.busy ? null : controller.toggle,
                child: Text(controller.active ? '结束对话' : '开始对话'),
              ),
            ),
            if (controller.segmenterError != null) ...[
              const SizedBox(height: 8),
              Text(
                controller.segmenterError!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            if (controller.droppedMicFrames > 0) ...[
              const SizedBox(height: 8),
              Text(
                '采集帧被丢弃说明主线程没跟上。这是有意的背压策略'
                '（宁可丢帧也不让延迟累积），但持续增长要查。',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, String label, bool active) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: active
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: active
              ? theme.colorScheme.onPrimaryContainer
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _stat(BuildContext context, String label, String value, Color color) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall),
        const SizedBox(height: 2),
        Text(value, style: theme.textTheme.titleMedium?.copyWith(color: color)),
      ],
    );
  }

  // -------------------------------------------------------------- 电平 / 试听

  Widget _levelCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('实时电平', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              '播测试音时麦克风条应接近静默；你一开口应明显抬升。这就是 AEC 的判据。'
              '（不做自动打断之后这里没有阈值线了，纯看电平。）',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            LevelMeter(levels: controller.levelsNotifier),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: controller.active ? controller.toggleTestTone : null,
                icon: Icon(
                  controller.testToneOn ? Icons.stop_circle_outlined : Icons.graphic_eq,
                ),
                label: Text(controller.testToneOn ? '停止测试音' : '播放测试音（AEC 自测）'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: controller.active ? controller.sendTestUtterance : null,
                icon: const Icon(Icons.upload_outlined),
                label: const Text('发送测试语音（验证上行）'),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '测试音不经过 brain，循环播放，所以 **brain 没起也能用** —— '
              '这是唯一一个永远可用的 AEC 验证入口。'
              '「发送测试语音」则把一段测试音当成你说的话走完整条上行链路，'
              '不需要麦克风就能验证编码、multipart、鉴权和文本回流。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------- 清空播放

  Widget _playbackControlCard(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('清空 AI 语音', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text('协议上不做自动打断 —— 收到就播。要让它闭嘴得手动触发：', style: muted),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: controller.active ? controller.clearPlayback : null,
                icon: const Icon(Icons.volume_off_outlined),
                label: const Text('清空播放队列'),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '• 通知栏「停止说话」按钮 —— 后台、锁屏都能用\n'
              '• 音量减键 —— 只在 App 前台且正在播 AI 语音时拦截，'
              '其余时候放行，不影响正常调音量。'
              '拦不拦由设置页的「音量减键清空队列」决定，关了它就纯调音量\n\n'
              '两者都只清音频。文本不受影响，照样进消息流。',
              style: muted,
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------- AEC 实测

  Widget _aecCard(BuildContext context) {
    final profile = controller.debugProfile;
    final theme = Theme.of(context);

    return Card(
      child: ExpansionTile(
        shape: const Border(),
        title: const Text('AEC 实测面板'),
        subtitle: Text(
          controller.active ? '改动会立即重启音频链路' : '一次只动一个变量',
          style: theme.textTheme.bodySmall,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          _enumRow<CaptureSource>(
            context,
            label: '采集源',
            value: profile.captureSource,
            values: CaptureSource.values,
            onChanged: (v) => controller.updateDebugProfile(profile.copyWith(captureSource: v)),
          ),
          _enumRow<PlaybackUsage>(
            context,
            label: '播放属性',
            hint: 'media 会让 AEC 拿不到参考信号',
            value: profile.playbackUsage,
            values: PlaybackUsage.values,
            onChanged: (v) => controller.updateDebugProfile(profile.copyWith(playbackUsage: v)),
          ),
          _enumRow<AudioPerformanceMode>(
            context,
            label: '性能模式',
            hint: 'lowLatency 下 effects 可能失效',
            value: profile.performanceMode,
            values: AudioPerformanceMode.values,
            onChanged: (v) => controller.updateDebugProfile(profile.copyWith(performanceMode: v)),
          ),
          _enumRow<AudioManagerMode>(
            context,
            label: 'AudioManager',
            value: profile.audioManagerMode,
            values: AudioManagerMode.values,
            onChanged: (v) => controller.updateDebugProfile(profile.copyWith(audioManagerMode: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('手动 AEC'),
            subtitle: const Text('叠加 AcousticEchoCanceler，与 voiceCommunication 是两条路径'),
            value: profile.manualAec,
            onChanged: (v) => controller.updateDebugProfile(profile.copyWith(manualAec: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('扬声器'),
            subtitle: const Text('setSpeakerphoneOn —— 可热切，不必重启'),
            value: profile.speakerphone,
            onChanged: (v) => controller.updateDebugProfile(profile.copyWith(speakerphone: v)),
          ),
        ],
      ),
    );
  }

  Widget _enumRow<T extends Enum>(
    BuildContext context, {
    required String label,
    required T value,
    required List<T> values,
    required ValueChanged<T> onChanged,
    String? hint,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelLarge),
                if (hint != null)
                  Text(
                    hint,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          DropdownButton<T>(
            value: value,
            underline: const SizedBox.shrink(),
            onChanged: (v) => v == null ? null : onChanged(v),
            items: [
              for (final item in values)
                DropdownMenuItem<T>(value: item, child: Text(item.name)),
            ],
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- 事件日志

  Widget _logCard(BuildContext context) {
    final theme = Theme.of(context);
    final log = controller.log;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('事件日志', style: theme.textTheme.titleSmall),
                Text(
                  '${log.length} / ${ConversationController.logLimit}',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (log.isEmpty)
              Text(
                '还没有事件。回主界面点一下按钮，说话之后这里会有东西。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              )
            else
              // 固定高度 + 内部滚动：日志再多也不会把页面撑长
              SizedBox(
                height: 240,
                child: ListView.builder(
                  itemCount: log.length,
                  itemBuilder: (context, index) {
                    final entry = log[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.time,
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: theme.colorScheme.outline),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(entry.message, style: theme.textTheme.bodySmall),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

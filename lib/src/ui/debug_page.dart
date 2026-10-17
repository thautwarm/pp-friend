import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
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
          appBar: AppBar(title: Text(AppLocalizations.of(context).debugTitle)),
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
    final l10n = AppLocalizations.of(context);
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
                _chip(
                  context,
                  controller.active ? l10n.conversationActive : l10n.notStarted,
                  controller.active,
                ),
                if (format != null)
                  _chip(context, '${format.sampleRate}Hz', true),
                if (controller.segmenterName != null)
                  _chip(context, controller.segmenterName!, true),
                _chip(
                  context,
                  controller.speaking ? l10n.aiSpeaking : l10n.aiSilent,
                  controller.speaking,
                ),
                _chip(
                  context,
                  'prob ${stats.probability.toStringAsFixed(2)}',
                  stats.speaking,
                ),
                _chip(context, l10n.mute, controller.micMuted),
                _chip(context, l10n.bargeIn, controller.bargeIn),
                _chip(
                  context,
                  stats.speakerVerifyEnabled
                      ? (stats.speakerCos >= 0
                            ? l10n.voiceprintScore(
                                stats.speakerCos.toStringAsFixed(2),
                              )
                            : l10n.voiceprintPending)
                      : l10n.voiceprintOff,
                  stats.speakerVerifyEnabled &&
                      stats.speakerCos >= controller.config.pvadMinCosine,
                ),
                // 声纹比对挂上时 pVAD 不参与判定，也不再显示那个
                // 会让人误以为"概率低就该被丢"的数字。
                if (!stats.speakerVerifyEnabled)
                  _chip(
                    context,
                    stats.pvadEnabled
                        ? l10n.targetProbability(
                            stats.pvadProb.toStringAsFixed(2),
                          )
                        : l10n.speakerRecognitionOff,
                    stats.pvadEnabled,
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _stat(
                    context,
                    l10n.droppedMicFrames,
                    '${controller.droppedMicFrames}',
                    controller.droppedMicFrames > 0
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: _stat(
                    context,
                    l10n.playbackBacklog,
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
                    l10n.uploadQueue,
                    '${controller.queuedUtterances}',
                    theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: _stat(
                    context,
                    l10n.droppedUtterances,
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
                    controller.polling ? l10n.polling : l10n.stopped,
                    controller.polling
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: _stat(
                    context,
                    l10n.upstreamCodec,
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
                    l10n.segmentBuffer,
                    '${stats.bufferedMs}ms',
                    theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: _stat(
                    context,
                    l10n.segmentDropped,
                    '${stats.droppedMs}ms',
                    stats.droppedMs > 0
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: _stat(
                    context,
                    l10n.forcedCuts,
                    '${stats.forcedCuts}',
                    theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: _stat(
                    context,
                    l10n.feedCost,
                    '${stats.lastFeedMicros}µs',
                    // 单帧超过 3ms 就意味着单核 15% 被吃掉，该挪出 main isolate 了
                    stats.lastFeedMicros > 3000
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: _stat(
                    context,
                    l10n.filteredNonTarget,
                    '${stats.pvadFiltered}',
                    stats.pvadFiltered > 0
                        ? theme.colorScheme.primary
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
                child: Text(
                  controller.active
                      ? l10n.endConversation
                      : l10n.startConversation,
                ),
              ),
            ),
            if (controller.segmenterError != null) ...[
              const SizedBox(height: 8),
              Text(
                controller.segmenterError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (controller.droppedMicFrames > 0) ...[
              const SizedBox(height: 8),
              Text(
                l10n.droppedFramesWarning,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
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
    final l10n = AppLocalizations.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.realtimeLevel, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              l10n.levelExplanation,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            LevelMeter(levels: controller.levelsNotifier),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: controller.active ? controller.toggleTestTone : null,
                icon: Icon(
                  controller.testToneOn
                      ? Icons.stop_circle_outlined
                      : Icons.graphic_eq,
                ),
                label: Text(
                  controller.testToneOn ? l10n.stopTestTone : l10n.playTestTone,
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: controller.active
                    ? controller.sendTestUtterance
                    : null,
                icon: const Icon(Icons.upload_outlined),
                label: Text(l10n.sendTestUtterance),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.testToneExplanation,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------- 清空播放

  Widget _playbackControlCard(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.clearAiVoice, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(l10n.clearPlaybackExplanation, style: muted),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: controller.active ? controller.clearPlayback : null,
                icon: const Icon(Icons.volume_off_outlined),
                label: Text(l10n.clearPlaybackQueue),
              ),
            ),
            const SizedBox(height: 12),
            Text(l10n.clearPlaybackDetail, style: muted),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------- AEC 实测

  Widget _aecCard(BuildContext context) {
    final profile = controller.debugProfile;
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Card(
      child: ExpansionTile(
        shape: const Border(),
        title: Text(l10n.aecPanel),
        subtitle: Text(
          controller.active
              ? l10n.aecPanelActiveSubtitle
              : l10n.aecPanelSubtitle,
          style: theme.textTheme.bodySmall,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          _enumRow<CaptureSource>(
            context,
            label: l10n.captureSource,
            value: profile.captureSource,
            values: CaptureSource.values,
            onChanged: (v) => controller.updateDebugProfile(
              profile.copyWith(captureSource: v),
            ),
          ),
          _enumRow<PlaybackUsage>(
            context,
            label: l10n.playbackUsage,
            hint: l10n.playbackUsageHint,
            value: profile.playbackUsage,
            values: PlaybackUsage.values,
            onChanged: (v) => controller.updateDebugProfile(
              profile.copyWith(playbackUsage: v),
            ),
          ),
          _enumRow<AudioPerformanceMode>(
            context,
            label: l10n.performanceMode,
            hint: l10n.performanceModeHint,
            value: profile.performanceMode,
            values: AudioPerformanceMode.values,
            onChanged: (v) => controller.updateDebugProfile(
              profile.copyWith(performanceMode: v),
            ),
          ),
          _enumRow<AudioManagerMode>(
            context,
            label: 'AudioManager',
            value: profile.audioManagerMode,
            values: AudioManagerMode.values,
            onChanged: (v) => controller.updateDebugProfile(
              profile.copyWith(audioManagerMode: v),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.manualAec),
            subtitle: Text(l10n.manualAecHint),
            value: profile.manualAec,
            onChanged: (v) =>
                controller.updateDebugProfile(profile.copyWith(manualAec: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.speakerphone),
            subtitle: Text(l10n.speakerphoneHint),
            value: profile.speakerphone,
            onChanged: (v) => controller.updateDebugProfile(
              profile.copyWith(speakerphone: v),
            ),
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
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
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
    final l10n = AppLocalizations.of(context);
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
                Text(l10n.eventLog, style: theme.textTheme.titleSmall),
                Text(
                  '${log.length} / ${ConversationController.logLimit}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (log.isEmpty)
              Text(
                l10n.noEvents,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
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
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              entry.message,
                              style: theme.textTheme.bodySmall,
                            ),
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

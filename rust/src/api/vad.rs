//! frb 暴露给 Dart 的断句接口。
//!
//! 这一层只做三件事：把 Dart 发来的 PCM16 字节流重采样到 16k、喂给 Silero、
//! 把切出来的段连**音频一起**还原出来。
//!
//! 为什么音频要在这里还原：`reason-vad` 的流式接口只返回
//! `start_sample`/`end_sample` 这样的偏移量，不返回音频本身（它的离线接口
//! `detect_segments` 也是这样）。所以偏移量到音频的映射得由调用方做，而我们
//! 恰好在这里维护着环形缓冲，映射是免费的。

use flutter_rust_bridge::frb;
use reason_vad::{ReasonVad, ReasonVadConfig, SAMPLE_RATE_HZ, SpeechSegment};

use crate::detector::SpeechDetector;
use crate::dsp::{LinearResampler, SampleRing};

/// Silero 的工作采样率，写死。
pub const TARGET_RATE: u32 = SAMPLE_RATE_HZ;

/// 切句参数。全部集中在一个结构里，以后加参数不会 churn Dart 的调用点。
#[derive(Debug, Clone, Copy)]
pub struct SegmenterConfig {
    /// Dart 实际采集到的采样率：16000 / 48000 / 44100 / 8000。
    pub input_sample_rate: u32,
    /// Silero 的语音概率阈值。
    pub threshold: f32,
    /// 静音持续多久算这一段结束。**这是修"话没说完就被切"的主参数** ——
    /// crate 默认 100ms 太短，句内停顿都会被当成结束。
    pub min_silence_ms: u32,
    /// 段两端各外扩多少毫秒。对应旧 EnergyVad 的 leadInMs（不留会把第一个字切掉）。
    pub speech_pad_ms: u32,
    /// 短于此长度的段直接丢弃（咳嗽一声不触发）。按**减掉两端外扩**后的原始跨度算。
    pub min_speech_ms: u32,
    /// 说话超过此长度就强制切段，避免一直说下去永远不结束。
    pub max_speech_ms: u32,
    /// 环形缓冲保留多久的音频。必须大于 `max_speech_ms`，见 `dsp::capacity_for`。
    pub ring_capacity_ms: u32,
}

impl Default for SegmenterConfig {
    fn default() -> Self {
        Self {
            input_sample_rate: 16000,
            threshold: 0.5,
            min_silence_ms: 700,
            speech_pad_ms: 200,
            min_speech_ms: 300,
            max_speech_ms: 20000,
            ring_capacity_ms: 30000,
        }
    }
}

/// 一段切好的话，自带音频。
#[derive(Debug, Clone)]
pub struct VadSegment {
    /// 16k 单声道 PCM16LE。**采样率是这个字段说了算，不是采集率。**
    pub pcm16le: Vec<u8>,
    pub sample_rate: u32,
    /// 相对本次会话开始（上次 `reset` 之后）的毫秒偏移。
    pub start_ms: u32,
    pub end_ms: u32,
    pub duration_ms: u32,
    /// 因为超过 `max_speech_ms` 被强制切开，而不是因为出现停顿。
    pub forced_cut: bool,
    /// 这一段的开头已经被环形缓冲挤掉了（说明缓冲配小了）。正常情况恒为 false。
    pub truncated: bool,
}

/// 每次喂音频的结果。
#[derive(Debug, Clone)]
pub struct VadFeedResult {
    /// 处理完这一块之后，是否处于"正在说话"。
    pub speaking: bool,
    /// 最近一帧的语音概率，0~1。调阈值时唯一能看的数。
    pub prob: f32,
    pub segments: Vec<VadSegment>,
    /// 环形缓冲当前占了多少毫秒音频。
    pub buffered_ms: u32,
    /// 累计被缓冲挤掉多少毫秒音频（正常应该恒为 0）。
    pub dropped_ms: u32,
}

/// 有状态、流式的断句器。Dart 侧一个会话持有一个。
///
/// 必须是 opaque：这个类型里有 `Box<dyn Trait>` 和 ORT 的 session，
/// 没法（也不该）跨 FFI 搬运，Dart 拿到的只是一个句柄。
#[frb(opaque)]
pub struct SileroVadHandle {
    cfg: SegmenterConfig,
    detector: Box<dyn SpeechDetector>,
    resampler: LinearResampler,
    ring: SampleRing,
    /// 当前这段"正在说"的近似起点（16k 绝对采样下标），用于强制切句。
    run_start: Option<usize>,
    /// 本次会话已经喂进来多少 16k 采样（= 下一个绝对下标）。
    seen: usize,
    forced_cuts: usize,
    // 复用缓冲，避免每帧分配。
    resampled: Vec<i16>,
    frames: Vec<f32>,
}

impl SileroVadHandle {
    /// 构造。这一步会加载 ONNX 模型（约 1.26MB）并做图优化，是**几十到几百毫秒**的
    /// 开销 —— Dart 侧必须在开始收麦克风之前调完，不能让第一帧撞上它。
    #[frb(sync)]
    pub fn new(cfg: SegmenterConfig) -> Result<SileroVadHandle, String> {
        let vad = ReasonVad::with_config(ReasonVadConfig {
            threshold: cfg.threshold,
            min_silence_duration_ms: cfg.min_silence_ms,
            speech_pad_ms: cfg.speech_pad_ms,
            // 这两个字段流式路径根本不看（只有离线的 detect_segments 用），
            // 但为了语义完整还是填进去。真正的过滤/强制切句在下面自己做。
            min_speech_duration_ms: cfg.min_speech_ms,
            max_speech_duration_s: f32::INFINITY,
        })
        .map_err(|e| e.to_string())?;

        Ok(Self::with_detector(cfg, Box::new(vad)))
    }

    /// 喂一块 PCM16LE（长度任意，采样率必须是 `cfg.input_sample_rate`）。
    #[frb(sync)]
    pub fn feed(&mut self, pcm16le: Vec<u8>) -> Result<VadFeedResult, String> {
        self.feed_inner(&pcm16le)
    }

    #[frb(sync)]
    pub fn reset(&mut self) {
        self.detector.reset();
        self.resampler.reset();
        self.ring.reset();
        self.run_start = None;
        self.seen = 0;
        self.forced_cuts = 0;
    }

    #[frb(sync)]
    pub fn is_speaking(&self) -> bool {
        self.detector.is_speaking()
    }

    /// 累积的强制切段次数。调试面板用。
    #[frb(sync)]
    pub fn forced_cuts(&self) -> u32 {
        self.forced_cuts as u32
    }
}

impl SileroVadHandle {
    fn with_detector(cfg: SegmenterConfig, detector: Box<dyn SpeechDetector>) -> Self {
        let ring = SampleRing::new(crate::dsp::capacity_for(&cfg, TARGET_RATE));
        Self {
            cfg,
            detector,
            resampler: LinearResampler::new(cfg.input_sample_rate, TARGET_RATE),
            ring,
            run_start: None,
            seen: 0,
            forced_cuts: 0,
            resampled: Vec::new(),
            frames: Vec::new(),
        }
    }

    fn samples_per_ms(&self) -> usize {
        TARGET_RATE as usize / 1000
    }

    fn ms_to_samples(&self, ms: u32) -> usize {
        ms as usize * TARGET_RATE as usize / 1000
    }

    fn feed_inner(&mut self, pcm16le: &[u8]) -> Result<VadFeedResult, String> {
        // 1. 字节 → i16（小端）。奇数长度直接丢掉尾巴那一字节。
        let n = pcm16le.len() / 2;
        let mut src: Vec<i16> = (0..n)
            .map(|i| i16::from_le_bytes([pcm16le[i * 2], pcm16le[i * 2 + 1]]))
            .collect();

        // 2. 重采样到 16k（同率时是直通）
        self.resampled.clear();
        if self.resampler.is_identity() {
            self.resampled.extend_from_slice(&src);
        } else {
            self.resampler.process(&src, &mut self.resampled);
        }
        src.clear();

        let chunk_len = self.resampled.len();
        if chunk_len == 0 {
            return Ok(self.result(Vec::new()));
        }

        // 3. 进环形缓冲。必须在 process_pcm 之前 —— 这样段偏移量的终点一定
        //    落在缓冲范围内。
        self.ring.push_slice(&self.resampled);
        self.seen += chunk_len;

        // 4. i16 → f32
        self.frames.clear();
        self.frames
            .extend(self.resampled.iter().map(|&s| s as f32 / 32768.0));

        // 5. 喂模型。返回的是**绝对采样偏移量**（相对上次 reset）。
        let raw_segments = self.detector.process_pcm(&self.frames)?;

        let mut out = Vec::new();
        for seg in raw_segments {
            if let Some(s) = self.materialize(seg, false) {
                out.push(s);
            }
        }

        // 6. 强制切句。crate 的流式路径**不**做这件事（`max_speech_duration_s`
        //    只有离线 `detect_segments` 用），所以必须自己做，否则一口气说下去
        //    永远不结束，缓冲也会一直涨。
        let max_samples = self.ms_to_samples(self.cfg.max_speech_ms);
        if self.detector.is_speaking() {
            if let Some(rs) = self.run_start {
                if self.seen.saturating_sub(rs) >= max_samples {
                    if let Some(seg) = self.detector.flush() {
                        if let Some(s) = self.materialize(seg, true) {
                            out.push(s);
                            self.forced_cuts += 1;
                        }
                    }
                }
            }
        }

        // 7. 维护"这一段什么时候开始的"。flush 之后 is_speaking 会变回 false，
        //    所以这里重新读一次。
        let speaking = self.detector.is_speaking();
        if !speaking {
            self.run_start = None;
        } else if self.run_start.is_none() {
            // 近似到本块开头，误差不超过一块（20ms），对 20 秒的强制切句无所谓。
            self.run_start = Some(self.seen.saturating_sub(chunk_len));
        }

        Ok(self.result(out))
    }

    fn result(&self, segments: Vec<VadSegment>) -> VadFeedResult {
        let per_ms = self.samples_per_ms().max(1);
        VadFeedResult {
            speaking: self.detector.is_speaking(),
            prob: self.detector.last_probability(),
            segments,
            buffered_ms: (self.ring.len() / per_ms) as u32,
            dropped_ms: (self.ring.dropped() / per_ms) as u32,
        }
    }

    /// 把检测器返回的偏移量还原成一段带音频的结果。
    ///
    /// 返回 `None` 表示这一段太短，该丢。
    fn materialize(&self, seg: SpeechSegment, forced_cut: bool) -> Option<VadSegment> {
        let pad = self.ms_to_samples(self.cfg.speech_pad_ms);

        // crate 对**两端**都做了 speech_pad 外扩，所以判长度要减掉两倍，
        // 否则一段 1ms 的噪声外扩成 400ms 也会通过。
        let raw_len = (seg.end_sample - seg.start_sample).saturating_sub(2 * pad);
        if raw_len < self.ms_to_samples(self.cfg.min_speech_ms) {
            return None;
        }

        let from = seg.start_sample;
        let to = seg.end_sample.min(self.seen).max(from);
        let (samples, truncated) = self.ring.slice(from, to);
        if samples.is_empty() {
            return None;
        }

        let per_ms = self.samples_per_ms().max(1);
        let mut pcm16le = Vec::with_capacity(samples.len() * 2);
        for s in samples {
            pcm16le.extend_from_slice(&s.to_le_bytes());
        }

        Some(VadSegment {
            pcm16le,
            sample_rate: TARGET_RATE,
            start_ms: (from / per_ms) as u32,
            end_ms: (to / per_ms) as u32,
            duration_ms: ((to - from) / per_ms) as u32,
            forced_cut,
            truncated,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::detector::SpeechDetector;
    use reason_vad::SpeechSegment;

    /// 可脚本化的假检测器：按预设的"概率序列"决定什么时候算说话，
    /// 让切段/过滤/强制切句的逻辑能被确定性地测到，不依赖模型。
    struct FakeDetector {
        /// 每 `frame` 个采样一个判定
        frame: usize,
        probs: Vec<f32>,
        threshold: f32,
        pos: usize,
        speech_start: Option<usize>,
        last_speech: Option<usize>,
        processed: usize,
        min_silence_samples: usize,
        pad: usize,
    }

    impl FakeDetector {
        fn new(probs: Vec<f32>, min_silence_ms: u32, pad_ms: u32, threshold: f32) -> Self {
            Self {
                frame: 160, // 10ms @16k
                probs,
                threshold,
                pos: 0,
                speech_start: None,
                last_speech: None,
                processed: 0,
                min_silence_samples: min_silence_ms as usize * 16,
                pad: pad_ms as usize * 16,
            }
        }

        fn emit(&self, start: usize, end: usize) -> SpeechSegment {
            let padded_start = start.saturating_sub(self.pad);
            let padded_end = (end + self.pad).min(self.processed);
            SpeechSegment {
                start: padded_start as f32 / 16000.0,
                end: padded_end as f32 / 16000.0,
                start_sample: padded_start,
                end_sample: padded_end,
            }
        }
    }

    impl SpeechDetector for FakeDetector {
        fn process_pcm(&mut self, samples: &[f32]) -> Result<Vec<SpeechSegment>, String> {
            let mut out = Vec::new();
            let mut cursor = 0;
            while cursor < samples.len() {
                let take = self.frame.min(samples.len() - cursor);
                let p = self.probs.get(self.pos).copied().unwrap_or(0.0);
                self.pos += 1;
                let frame_start = self.processed;
                let frame_end = frame_start + take;
                if p >= self.threshold {
                    if self.speech_start.is_none() {
                        self.speech_start = Some(frame_start);
                    }
                    self.last_speech = Some(frame_end);
                } else if let (Some(s), Some(last)) = (self.speech_start, self.last_speech) {
                    if frame_end - last >= self.min_silence_samples {
                        out.push(self.emit(s, last));
                        self.speech_start = None;
                        self.last_speech = None;
                    }
                }
                self.processed = frame_end;
                cursor += take;
            }
            Ok(out)
        }

        fn flush(&mut self) -> Option<SpeechSegment> {
            let r = match (self.speech_start, self.last_speech) {
                (Some(s), Some(e)) => Some(self.emit(s, e)),
                _ => None,
            };
            self.speech_start = None;
            self.last_speech = None;
            r
        }

        fn is_speaking(&self) -> bool {
            self.speech_start.is_some()
        }

        fn last_probability(&self) -> f32 {
            self.probs
                .get(self.pos.saturating_sub(1))
                .copied()
                .unwrap_or(0.0)
        }

        fn reset(&mut self) {
            self.reset_state();
        }
    }

    impl FakeDetector {
        fn reset_state(&mut self) {
            self.pos = 0;
            self.speech_start = None;
            self.last_speech = None;
            self.processed = 0;
        }
    }

    /// 造一段可预测的 i16 输入：值的绝对值 = 绝对下标 % 1000。
    fn tone_bytes(count: usize) -> Vec<u8> {
        (0..count)
            .flat_map(|i| ((i % 1000) as i16).to_le_bytes())
            .collect()
    }

    fn handle_with(fake: FakeDetector, cfg: SegmenterConfig) -> SileroVadHandle {
        SileroVadHandle::with_detector(cfg, Box::new(fake))
    }

    fn base_cfg() -> SegmenterConfig {
        SegmenterConfig {
            input_sample_rate: 16000,
            threshold: 0.5,
            min_silence_ms: 700,
            speech_pad_ms: 200,
            min_speech_ms: 300,
            max_speech_ms: 20000,
            ring_capacity_ms: 30000,
        }
    }

    #[test]
    fn real_model_loads_and_reports_silence() {
        let mut h = SileroVadHandle::new(SegmenterConfig::default()).unwrap();
        // 5 秒纯静音
        let silence = vec![0u8; 16000 * 2 * 5];
        let r = h.feed(silence).unwrap();
        assert!(!r.speaking);
        assert!(r.segments.is_empty(), "静音不该切出任何东西");
        assert!(r.dropped_ms == 0);
    }

    #[test]
    fn real_model_survives_long_silence_without_growing_unbounded() {
        let mut h = SileroVadHandle::new(SegmenterConfig::default()).unwrap();
        for _ in 0..40 {
            let _ = h.feed(vec![0u8; 16000 * 2]).unwrap(); // 每秒喂一次，共 40 秒
        }
        let r = h.feed(vec![0u8; 320]).unwrap();
        assert!(
            r.buffered_ms <= 30_000,
            "缓冲不该超过配置容量，实际 {}",
            r.buffered_ms
        );
        assert!(r.segments.is_empty());
        // 40 秒音频进 30 秒的环，老的静音被挤掉是预期行为 —— 真正要担心的
        // 是 `VadSegment.truncated`（正在说的那段被挤掉），那个才是配置错误。
    }

    #[test]
    fn segment_audio_matches_the_ring() {
        let probs = vec![
            0.9, 0.9, 0.9, 0.9, 0.9, // 50ms 说话
            0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, // 100ms 静音
        ];
        let cfg = SegmenterConfig {
            min_silence_ms: 50,
            speech_pad_ms: 0,
            min_speech_ms: 10,
            ..base_cfg()
        };
        let fake = FakeDetector::new(probs, cfg.min_silence_ms, 0, cfg.threshold);
        let mut h = handle_with(fake, cfg);

        let input = tone_bytes(1600); // 100ms
        let r = h.feed(input.clone()).unwrap();

        assert_eq!(r.segments.len(), 1, "应该切出正好一段");
        let seg = &r.segments[0];
        assert!(!seg.forced_cut);
        assert!(!seg.truncated);
        assert_eq!(seg.sample_rate, 16000);
        // 假检测器在 100ms 静音积累够之后才发段，段的终点是最后一次说话的位置
        // （第 5 帧结束 = 800 采样 = 50ms），所以切出来的是前 50ms。
        assert_eq!(seg.duration_ms, 50);
        assert_eq!(seg.pcm16le.len(), 800 * 2);
        assert_eq!(seg.pcm16le, input[..800 * 2].to_vec(), "切出来的音频应该原样等于输入");
    }

    #[test]
    fn short_segment_is_dropped() {
        // 10ms 说话 + 100ms 静音；min_speech 要求 300ms，该丢
        let probs = vec![0.9, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
        let cfg = SegmenterConfig {
            min_silence_ms: 50,
            speech_pad_ms: 0,
            min_speech_ms: 300,
            ..base_cfg()
        };
        let fake = FakeDetector::new(probs, cfg.min_silence_ms, 0, cfg.threshold);
        let mut h = handle_with(fake, cfg);
        let r = h.feed(tone_bytes(1600)).unwrap();
        assert!(r.segments.is_empty(), "太短的段必须丢掉");
    }

    #[test]
    fn padding_is_subtracted_before_the_length_check() {
        // 一段只有 20ms 的说话，但 pad=200ms 会让 crate 交出来 420ms 的长度。
        // 如果不减掉两倍 pad，它就会蒙混过关。
        let probs = vec![0.9, 0.9, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
        let cfg = SegmenterConfig {
            min_silence_ms: 50,
            speech_pad_ms: 200,
            min_speech_ms: 300,
            ..base_cfg()
        };
        let fake = FakeDetector::new(probs, cfg.min_silence_ms, cfg.speech_pad_ms, cfg.threshold);
        let mut h = handle_with(fake, cfg);
        let r = h.feed(tone_bytes(1600)).unwrap();
        assert!(r.segments.is_empty(), "20ms 的原始跨度不该通过 300ms 的下限");
    }

    #[test]
    fn long_speech_is_force_split() {
        let cfg = SegmenterConfig {
            min_silence_ms: 700,
            speech_pad_ms: 0,
            min_speech_ms: 100,
            max_speech_ms: 200, // 200ms 就强制切
            ..base_cfg()
        };
        // 全程说话，没有停顿
        let fake = FakeDetector::new(vec![1.0; 200], cfg.min_silence_ms, 0, cfg.threshold);
        let mut h = handle_with(fake, cfg);

        let mut cuts = 0;
        let mut total_ms = 0u32;
        // 喂 1 秒，分 50 块
        for _ in 0..50 {
            let r = h.feed(tone_bytes(320)).unwrap();
            for s in r.segments {
                cuts += 1;
                total_ms += s.duration_ms;
                assert!(s.forced_cut, "没有停顿，只能是强制切");
                assert!(s.duration_ms <= 260, "单段不该明显超过 max_speech");
            }
        }
        assert!(cuts >= 4, "1 秒 / 每 200ms 一段，至少该切 4 次，实际 {cuts}");
        assert!(total_ms >= 800, "总时长不该丢太多，实际 {total_ms}ms");
        assert_eq!(h.forced_cuts(), cuts);
    }

    #[test]
    fn feed_accepts_arbitrary_chunk_sizes_and_tracks_offsets() {
        let cfg = SegmenterConfig {
            min_silence_ms: 100,
            speech_pad_ms: 0,
            min_speech_ms: 50,
            input_sample_rate: 16000,
            ..base_cfg()
        };
        let fake = FakeDetector::new(
            vec![1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            cfg.min_silence_ms,
            0,
            cfg.threshold,
        );
        let mut h = handle_with(fake, cfg);
        // 故意用不对齐的块长
        for size in [17, 3, 501, 320, 1] {
            let r = h.feed(tone_bytes(size)).unwrap();
            assert!(r.buffered_ms < 30_000);
        }
        // 这段"说话"只有 10ms，会被 min_speech=50 丢掉，但仍不该 panic
        assert!(h.forced_cuts() == 0);
    }

    #[test]
    fn resampling_to_16k_feeds_the_detector() {
        // 48k 输入：3 秒 = 144000 采样，期望喂给检测器约 48000 个 16k 采样
        let cfg = SegmenterConfig {
            input_sample_rate: 48000,
            min_silence_ms: 700,
            speech_pad_ms: 0,
            min_speech_ms: 300,
            ..base_cfg()
        };
        let fake = FakeDetector::new(vec![0.0; 1000], cfg.min_silence_ms, 0, cfg.threshold);
        let mut h = handle_with(fake, cfg);
        let mut fed = 0usize;
        for _ in 0..3 {
            let r = h.feed(tone_bytes(48000)).unwrap();
            fed = r.buffered_ms as usize;
        }
        assert!(
            (2800..=3000).contains(&fed),
            "3 秒 48k 输入应该在缓冲里留下约 3 秒，实际 {fed}ms"
        );
    }
}

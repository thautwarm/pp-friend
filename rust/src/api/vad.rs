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
use crate::pvad::{PvadConfig, SegmentScore, SpeakerGate, VerifyConfig};

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

/// 说话人门控参数。只有挂了 pVAD 才有意义。
#[derive(Debug, Clone, Copy)]
pub struct PvadGateConfig {
    /// 单帧判为"目标人"的阈值，0~1。
    pub threshold: f32,
    /// 一段里目标帧占比达到多少才保留，0~1。
    ///
    /// 低于它的段会被**整段丢掉**：不上传、不进消息流。这是有意的 ——
    /// 家人说话不该出现在 agent 的上下文里。
    pub min_target_ratio: f32,
}

/// 整段声纹比对参数（ECAPA cosine）。
#[derive(Debug, Clone, Copy)]
pub struct SpeakerVerifyConfig {
    /// 和注册声纹的 cosine 低于它就丢掉这一段。同一个人的跨录音通常 > 0.5，
    /// 不同人通常 < 0.3，0.4 左右是安全的分界。
    pub min_cosine: f32,
    /// 短于此长度的段不比声纹，退回 pVAD。太短的 embedding 不稳。
    pub min_verify_ms: u32,
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
    /// pVAD 平滑概率的段内均值。没挂声纹门控时是 -1。
    pub pvad_score: f32,
    /// 段内被判为目标人的帧占比，0~1。没挂门控时是 -1。
    pub pvad_target_ratio: f32,
    /// 这一段和注册声纹的 cosine。没比或太短时是 -1。
    pub speaker_cos: f32,
}

/// 被说话人门控丢掉的一段。音频不传，只留元数据给调试面板。
#[derive(Debug, Clone)]
pub struct DroppedSegment {
    pub start_ms: u32,
    pub end_ms: u32,
    pub duration_ms: u32,
    pub pvad_score: f32,
    pub pvad_target_ratio: f32,
    pub speaker_cos: f32,
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
    /// 这一帧之后说话人门控是否生效。
    pub pvad_enabled: bool,
    /// 最近一帧的 pVAD 平滑概率。没挂门控时是 0。
    pub pvad_prob: f32,
    /// 是否挂了整段声纹比对（ECAPA）。
    pub speaker_verify_enabled: bool,
    /// 最近一段的声纹 cosine。还没比过时是 -1。
    pub speaker_cos: f32,
    /// 这一次 feed 里因为不是目标人而被丢掉的段。
    pub filtered: Vec<DroppedSegment>,
    /// 门控挂了的原因（推理失败、模型不兼容）。非空时 `pvad_enabled` 一定是 false。
    pub pvad_error: Option<String>,
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
    /// 说话人门控。默认没挂模型，`enabled()` 为 false，行为和不集成 pVAD 时完全一样。
    gate: SpeakerGate,
    /// 最近一段的声纹 cosine，调试面板用。没比过时是 -1。
    last_cos: f32,
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
        self.last_cos = -1.0;
        self.gate.reset();
    }

    /// 挂上说话人门控（pVAD）。
    ///
    /// `model` 是 `pvad.onnx` 的字节，`spkemb` 是 192 个 little-endian f32
    /// （768 字节，由网页端或 Python 注册工具生成）。
    ///
    /// **必须在开始喂音频之前调完**：这一步要加载 3.9MB 模型并做图优化，
    /// 是几十到几百毫秒的开销。
    #[frb(sync)]
    pub fn set_pvad(
        &mut self,
        model: Vec<u8>,
        spkemb: Vec<u8>,
        cfg: PvadGateConfig,
    ) -> Result<(), String> {
        let emb = crate::pvad::parse_spkemb(&spkemb)?;
        let scorer = crate::pvad::PvadScorer::new(&model, &emb)?;
        self.gate.attach(
            Box::new(scorer),
            PvadConfig {
                threshold: cfg.threshold,
                min_target_ratio: cfg.min_target_ratio,
            },
        );
        Ok(())
    }

    /// 挂上整段声纹比对（ECAPA cosine）。
    ///
    /// 和 [`Self::set_pvad`] 可以同时挂：够长的段以 cosine 为准，短段退回 pVAD。
    /// `model` 是 `ecapa.onnx`（约 81 MiB）的字节，`spkemb` 是网页导出的 768 字节。
    ///
    /// **必须在开始喂音频之前调完**：加载 81 MiB 模型是秒级的开销。
    #[frb(sync)]
    pub fn set_speaker_verifier(
        &mut self,
        model: Vec<u8>,
        spkemb: Vec<u8>,
        cfg: SpeakerVerifyConfig,
    ) -> Result<(), String> {
        let emb = crate::pvad::parse_spkemb(&spkemb)?;
        let verifier = crate::ecapa::EcapaVerifier::new(&model, &emb)?;
        self.gate.attach_verifier(
            Box::new(verifier),
            VerifyConfig {
                min_cosine: cfg.min_cosine.clamp(0.0, 1.0),
                min_samples: self.ms_to_samples(cfg.min_verify_ms),
            },
        );
        Ok(())
    }

    /// 摘掉门控。摘掉之后所有段都放行。
    #[frb(sync)]
    pub fn clear_pvad(&mut self) {
        self.gate.detach();
    }

    /// 门控是否生效。推理失败之后会变成 false。
    #[frb(sync)]
    pub fn pvad_enabled(&self) -> bool {
        self.gate.enabled()
    }

    /// 累计被判定为"不是目标人"而丢掉的段数。
    #[frb(sync)]
    pub fn pvad_filtered(&self) -> u32 {
        self.gate.filtered()
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
            gate: SpeakerGate::default(),
            last_cos: -1.0,
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
            return Ok(self.result(Vec::new(), Vec::new()));
        }

        // 3. 进环形缓冲。必须在 process_pcm 之前 —— 这样段偏移量的终点一定
        //    落在缓冲范围内。
        self.ring.push_slice(&self.resampled);
        self.seen += chunk_len;

        // 4. i16 → f32
        self.frames.clear();
        self.frames
            .extend(self.resampled.iter().map(|&s| s as f32 / 32768.0));

        // 5. 喂 pVAD。和 Silero 共享同一份 16k 采样 —— 两边各自重采样的话
        //    相位会漂，段和概率就对不上了。
        self.gate.push(&self.frames, self.seen - chunk_len);

        // 6. 喂模型。返回的是**绝对采样偏移量**（相对上次 reset）。
        let raw_segments = self.detector.process_pcm(&self.frames)?;

        let mut out = Vec::new();
        let mut filtered = Vec::new();
        for seg in raw_segments {
            if let Some((s, score, cos)) = self.materialize(seg, false) {
                if self.gate.is_target(score, cos) {
                    out.push(s);
                } else {
                    filtered.push(dropped(&s, score));
                    self.gate.mark_filtered();
                }
            }
        }

        // 7. 强制切句。crate 的流式路径**不**做这件事（`max_speech_duration_s`
        //    只有离线 `detect_segments` 用），所以必须自己做，否则一口气说下去
        //    永远不结束，缓冲也会一直涨。
        let max_samples = self.ms_to_samples(self.cfg.max_speech_ms);
        if self.detector.is_speaking() {
            if let Some(rs) = self.run_start {
                if self.seen.saturating_sub(rs) >= max_samples {
                    if let Some(seg) = self.detector.flush() {
                        if let Some((s, score, cos)) = self.materialize(seg, true) {
                            if self.gate.is_target(score, cos) {
                                out.push(s);
                                self.forced_cuts += 1;
                            } else {
                                filtered.push(dropped(&s, score));
                                self.gate.mark_filtered();
                            }
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

        Ok(self.result(out, filtered))
    }

    fn result(
        &self,
        segments: Vec<VadSegment>,
        filtered: Vec<DroppedSegment>,
    ) -> VadFeedResult {
        let per_ms = self.samples_per_ms().max(1);
        VadFeedResult {
            speaking: self.detector.is_speaking(),
            prob: self.detector.last_probability(),
            segments,
            buffered_ms: (self.ring.len() / per_ms) as u32,
            dropped_ms: (self.ring.dropped() / per_ms) as u32,
            pvad_enabled: self.gate.enabled(),
            pvad_prob: self.gate.last(),
            speaker_verify_enabled: self.gate.verify_enabled(),
            speaker_cos: self.last_cos,
            filtered,
            pvad_error: self.gate.error().map(str::to_string),
        }
    }

    /// 拼出送进 ECAPA 的那段音频。
    ///
    /// 一句话中间停顿的地方是纯静音。整段直接送进去，静音会按长度比例稀释
    /// embedding —— 说得越长、停顿越多，同一个人的 cosine 反而越低。这里只
    /// 取 Silero 判为语音的帧，最多 [`crate::ecapa::MAX_VERIFY_SAMPLES`] 个采样。
    ///
    /// 挑出来的语音不足门控要求的最短长度时退回整段：短句本来就没多少静音，
    /// 而且不能因为"挑不出东西"就把门控变成"没有数据就全丢"。
    fn verify_audio(&self, samples: &[i16], from: usize, to: usize) -> Vec<f32> {
        let mut voiced: Vec<f32> = Vec::new();
        for frame in self.detector.frame_probabilities() {
            if frame.probability < self.cfg.threshold {
                continue;
            }
            // 帧是模型对齐的，不一定正好落在外扩之外的区间里，剪一下。
            let a = frame.start_sample.max(from);
            let b = frame.end_sample.min(to);
            if b <= a {
                continue;
            }
            let ia = a - from;
            let ib = b - from;
            if ib > samples.len() {
                break;
            }
            voiced.extend(samples[ia..ib].iter().map(|&s| s as f32 / 32768.0));
            if voiced.len() >= crate::ecapa::MAX_VERIFY_SAMPLES {
                voiced.truncate(crate::ecapa::MAX_VERIFY_SAMPLES);
                break;
            }
        }
        if voiced.len() >= self.gate.min_verify_samples() {
            voiced
        } else {
            samples.iter().map(|&s| s as f32 / 32768.0).collect()
        }
    }

    /// 把检测器返回的偏移量还原成一段带音频的结果。
    ///
    /// 返回 `None` 表示这一段太短，该丢。
    fn materialize(
        &mut self,
        seg: SpeechSegment,
        forced_cut: bool,
    ) -> Option<(VadSegment, Option<SegmentScore>, Option<f32>)> {
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

        // 说话人打分只算**去掉两端外扩**的那一段。外扩是静音，pVAD 在静音上
        // 给的本来就是低概率，算进去只会把本人的段也拉下来。
        let score_from = (seg.start_sample + pad).min(seg.end_sample);
        let score_to = seg
            .end_sample
            .saturating_sub(pad)
            .max(score_from)
            .min(self.seen);
        let score = if score_to > score_from {
            self.gate.score(score_from, score_to)
        } else {
            self.gate.score(seg.start_sample, seg.end_sample.min(self.seen))
        };

        // 整段声纹比对只用**去掉两端外扩**的语音；外扩是静音，会把 embedding
        // 拉向"没人说话"的方向。`samples` 的下标是相对 `from` 的。
        let cos = if score_to > score_from {
            let a = score_from.saturating_sub(from).min(samples.len());
            let b = score_to.saturating_sub(from).min(samples.len());
            let verify = self.verify_audio(&samples[a..b], score_from, score_to);
            let c = self.gate.verify(&verify);
            if let Some(c) = c {
                self.last_cos = c;
            }
            c
        } else {
            None
        };

        let per_ms = self.samples_per_ms().max(1);
        let mut pcm16le = Vec::with_capacity(samples.len() * 2);
        for s in samples {
            pcm16le.extend_from_slice(&s.to_le_bytes());
        }

        Some((
            VadSegment {
                pcm16le,
                sample_rate: TARGET_RATE,
                start_ms: (from / per_ms) as u32,
                end_ms: (to / per_ms) as u32,
                duration_ms: ((to - from) / per_ms) as u32,
                forced_cut,
                truncated,
                pvad_score: score.map(|s| s.mean).unwrap_or(-1.0),
                pvad_target_ratio: score.map(|s| s.target_ratio).unwrap_or(-1.0),
                speaker_cos: cos.unwrap_or(-1.0),
            },
            score,
            cos,
        ))
    }
}

fn dropped(segment: &VadSegment, score: Option<SegmentScore>) -> DroppedSegment {
    DroppedSegment {
        start_ms: segment.start_ms,
        end_ms: segment.end_ms,
        duration_ms: segment.duration_ms,
        pvad_score: score.map(|s| s.mean).unwrap_or(-1.0),
        pvad_target_ratio: score.map(|s| s.target_ratio).unwrap_or(-1.0),
        speaker_cos: segment.speaker_cos,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::detector::SpeechDetector;
    use reason_vad::{FrameProb, SpeechSegment};
    use std::sync::{Arc, Mutex};

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
        frames: Vec<FrameProb>,
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
                frames: Vec::new(),
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
                self.frames.push(FrameProb {
                    start_sample: frame_start,
                    end_sample: frame_end,
                    probability: p,
                });
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

        fn frame_probabilities(&self) -> &[FrameProb] {
            &self.frames
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
            self.frames.clear();
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

    // ---------------------------------------------------------- 说话人门控

    /// 每帧固定吐同一个概率的假打分器。
    struct FixedScorer(f32);

    impl crate::pvad::SpeakerScorer for FixedScorer {
        fn push(
            &mut self,
            samples: &[f32],
            on_frame: &mut dyn FnMut(f32),
        ) -> Result<(), String> {
            for _ in 0..samples.len() / crate::pvad::FRAME_SAMPLES {
                on_frame(self.0);
            }
            Ok(())
        }

        fn reset(&mut self) {}
    }

    fn handle_with_gate(fake: FakeDetector, cfg: SegmenterConfig, p: f32) -> SileroVadHandle {
        let mut h = handle_with(fake, cfg);
        h.gate.attach(
            Box::new(FixedScorer(p)),
            PvadConfig {
                threshold: 0.5,
                min_target_ratio: 0.5,
            },
        );
        h
    }

    /// 一段 50ms 说话 + 100ms 静音，切出一段 50ms。
    fn one_segment_cfg() -> SegmenterConfig {
        SegmenterConfig {
            min_silence_ms: 50,
            speech_pad_ms: 0,
            min_speech_ms: 10,
            ..base_cfg()
        }
    }

    fn one_segment_probs() -> Vec<f32> {
        let mut p = vec![0.9; 5];
        p.extend(vec![0.0; 10]);
        p
    }

    #[test]
    fn target_speaker_segment_passes_the_gate() {
        let cfg = one_segment_cfg();
        let fake = FakeDetector::new(one_segment_probs(), cfg.min_silence_ms, 0, cfg.threshold);
        let mut h = handle_with_gate(fake, cfg, 0.95);

        let r = h.feed(tone_bytes(1600)).unwrap();
        assert_eq!(r.segments.len(), 1);
        assert!(r.filtered.is_empty());
        assert!(r.pvad_enabled);
        assert!(r.segments[0].pvad_score > 0.9, "{}", r.segments[0].pvad_score);
        assert_eq!(h.pvad_filtered(), 0);
    }

    #[test]
    fn other_speaker_segment_is_dropped_before_it_reaches_dart() {
        let cfg = one_segment_cfg();
        let fake = FakeDetector::new(one_segment_probs(), cfg.min_silence_ms, 0, cfg.threshold);
        let mut h = handle_with_gate(fake, cfg, 0.02);

        let r = h.feed(tone_bytes(1600)).unwrap();
        assert!(r.segments.is_empty(), "非目标段不能出现在 segments 里");
        assert_eq!(r.filtered.len(), 1, "要能看见它被丢了");
        assert_eq!(r.filtered[0].duration_ms, 50);
        assert!(r.filtered[0].pvad_score < 0.1);
        assert_eq!(h.pvad_filtered(), 1);
    }

    /// 记录最后一段输入长度的假比对器。
    struct RecordingVerifier {
        last_len: Arc<Mutex<usize>>,
        cosine: f32,
    }

    impl crate::pvad::SpeakerVerifier for RecordingVerifier {
        fn cosine(&mut self, samples: &[f32]) -> Result<f32, String> {
            *self.last_len.lock().unwrap() = samples.len();
            Ok(self.cosine)
        }
    }

    #[test]
    fn voiceprint_skips_silence_inside_a_segment() {
        // 5 帧说话 + 3 帧停顿 + 5 帧说话。停顿只有 30ms，不够 min_silence(100ms)，
        // 所以整段会被切成**一段**，停顿夹在段中间 —— 正是用户说的"说一半停一下"。
        let mut probs = vec![0.9; 5];
        probs.extend(vec![0.0; 3]);
        probs.extend(vec![0.9; 5]);
        probs.extend(vec![0.0; 10]);

        let cfg = SegmenterConfig {
            min_silence_ms: 100,
            speech_pad_ms: 0,
            min_speech_ms: 10,
            ..base_cfg()
        };
        let fake = FakeDetector::new(probs, cfg.min_silence_ms, 0, cfg.threshold);
        let mut h = handle_with(fake, cfg);

        let last_len = Arc::new(Mutex::new(0usize));
        h.gate.attach_verifier(
            Box::new(RecordingVerifier {
                last_len: last_len.clone(),
                cosine: 0.66,
            }),
            crate::pvad::VerifyConfig {
                min_cosine: 0.4,
                // 50ms，故意设得比整段（130ms）短，让挑出来的 100ms 语音够用
                min_samples: 800,
            },
        );

        let r = h.feed(tone_bytes(23 * 160)).unwrap();
        assert_eq!(r.segments.len(), 1, "停顿不该把一句话切成两段");
        assert_eq!(r.segments[0].duration_ms, 130);
        assert!((r.segments[0].speaker_cos - 0.66).abs() < 1e-6);

        // 13 帧里有 3 帧静音，声纹输入只该拿到 10 帧 = 1600 采样。
        assert_eq!(
            *last_len.lock().unwrap(),
            1600,
            "段中间的静音不能被送进声纹比对"
        );
    }

    #[test]
    fn voiceprint_falls_back_to_the_whole_segment_when_too_little_voiced_audio() {
        // 段里只有 10ms 被判为语音，但 min_samples 要求 50ms：挑出来的不够，
        // 应该退回整段，而不是让 verify 静默地什么都不做。
        let mut probs = vec![0.9];
        probs.extend(vec![0.0; 2]); // 20ms 停顿，不够 min_silence(100ms)
        probs.extend(vec![0.0; 10]);

        let cfg = SegmenterConfig {
            min_silence_ms: 100,
            speech_pad_ms: 0,
            min_speech_ms: 10,
            ..base_cfg()
        };
        let fake = FakeDetector::new(probs, cfg.min_silence_ms, 0, cfg.threshold);
        let mut h = handle_with(fake, cfg);

        let last_len = Arc::new(Mutex::new(0usize));
        h.gate.attach_verifier(
            Box::new(RecordingVerifier {
                last_len: last_len.clone(),
                cosine: 0.5,
            }),
            crate::pvad::VerifyConfig {
                min_cosine: 0.4,
                min_samples: 800,
            },
        );

        let r = h.feed(tone_bytes(13 * 160)).unwrap();
        assert_eq!(r.segments.len(), 1);
        // 段真的只有 10ms，比 min_samples 还短 —— verify 直接返回 None，
        // 这里要确认的是**没有拿挑空的 Vec 去调它**（否则会拿到 -1 把段误杀）。
        assert_eq!(*last_len.lock().unwrap(), 0, "太短的段不该调用比对器");
    }

    #[test]
    fn without_a_scorer_nothing_is_filtered() {
        let cfg = one_segment_cfg();
        let fake = FakeDetector::new(one_segment_probs(), cfg.min_silence_ms, 0, cfg.threshold);
        let mut h = handle_with(fake, cfg);
        let r = h.feed(tone_bytes(1600)).unwrap();
        assert_eq!(r.segments.len(), 1);
        assert!(!r.pvad_enabled);
        assert_eq!(r.segments[0].pvad_score, -1.0);
        assert!(r.filtered.is_empty());
    }

    #[test]
    fn reset_restarts_gate_state() {
        let cfg = one_segment_cfg();
        let fake = FakeDetector::new(one_segment_probs(), cfg.min_silence_ms, 0, cfg.threshold);
        let mut h = handle_with_gate(fake, cfg, 0.02);
        let _ = h.feed(tone_bytes(1600)).unwrap();
        assert_eq!(h.pvad_filtered(), 1);
        h.reset();
        assert_eq!(h.pvad_filtered(), 0);
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

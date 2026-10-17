//! 个性化 VAD（pVAD）—— 判断"当前说话的是不是注册的那个人"。
//!
//! 模型来自 `FireRedTeam/FireRedChat-pvad`（Apache-2.0），3.9MB ONNX。
//! 输入是 10ms 一帧（160 采样 @16k）的音频和一个 192 维 ECAPA 声纹，
//! 输出是"这一帧是目标说话人"的概率。模型自带 mel 前端和 GRU 状态，
//! 状态通过 `mel_buffer` / `gru_buffer` 在帧之间回传。
//!
//! **这里只做门控，不做断句。** 断句仍然是 Silero 的活：Silero 决定
//! "这段有没有人说话"，pVAD 决定"说话的是不是本人"。两个模型串起来，
//! 家人说话时整段就不会被上传，agent 的上下文里也就不会混进别人的话。
//!
//! 为什么不在 Dart 侧直接调 onnxruntime：音频重采样、Silero 的帧推进、
//! pVAD 的帧推进必须共享**同一条 16k 流**。放到 Dart 就得把重采样抄一遍，
//! 两边的相位迟早对不上。

use std::collections::VecDeque;

use ort::session::Session;
use ort::value::Tensor;

/// pVAD 的帧长：10ms @16k。
pub const FRAME_SAMPLES: usize = 160;

/// ECAPA 声纹维度。
pub const EMB_DIM: usize = 192;

/// 声纹文件的字节数（192 个 little-endian f32）。
pub const SPKEMB_BYTES: usize = EMB_DIM * 4;

/// 概率平滑的系数。与 FireRedChat 插件里的 LiveKit `ExpFilter(alpha=0.8)` 对齐：
/// `smooth = alpha * smooth + (1 - alpha) * raw`。
const EMA_ALPHA: f32 = 0.8;

/// 历史概率保留多久。段是在静音判定之后才吐出来的，所以要能回溯
/// 至少一个"静音窗口"（当前默认 1 秒）加上段本身的长度。
const HISTORY_MS: usize = 15_000;

/// 门控参数。
#[derive(Debug, Clone, Copy)]
pub struct PvadConfig {
    /// 单帧判为"目标人"的阈值。
    pub threshold: f32,
    /// 一段里目标帧占比达到多少才算"这一段是本人说的"。
    pub min_target_ratio: f32,
}

impl Default for PvadConfig {
    fn default() -> Self {
        Self {
            threshold: 0.5,
            min_target_ratio: 0.5,
        }
    }
}

/// 一段话的声纹判定结果。
#[derive(Debug, Clone, Copy)]
pub struct SegmentScore {
    /// 平滑后概率的均值。
    pub mean: f32,
    /// 超过阈值的帧占多少。0~1。
    pub target_ratio: f32,
    /// 参与统计的帧数。0 表示这一段没有覆盖到任何 pVAD 帧。
    pub frames: u32,
}

/// 逐帧打分器的抽象。
///
/// 抽出来是为了让门控逻辑能用确定性的假打分器测到 —— 和
/// [`crate::detector::SpeechDetector`] 是同一个理由：真模型加载不了、
/// 判什么也不可控，而"哪一段该丢"恰恰是最需要测的部分。
pub trait SpeakerScorer: Send + Sync {
    /// 喂 16k 单声道 f32 采样（长度任意），每凑满 160 个回调一次**原始**概率。
    fn push(&mut self, samples: &[f32], on_frame: &mut dyn FnMut(f32)) -> Result<(), String>;

    fn reset(&mut self);
}

/// 整段声纹比对。生产实现是 [`crate::ecapa::EcapaVerifier`]。
///
/// 和 [`SpeakerScorer`] 分开：pVAD 是逐帧流式的，声纹比对只在段结束时
/// 跑一次，输入是整段（或前 3 秒）音频。
pub trait SpeakerVerifier: Send + Sync {
    /// 返回和注册声纹的 cosine。比不了时返回 -1。
    fn cosine(&mut self, samples: &[f32]) -> Result<f32, String>;
}

/// 声纹比对的判定参数。
#[derive(Debug, Clone, Copy)]
pub struct VerifyConfig {
    /// 低于这个 cosine 就当成"不是本人"。
    pub min_cosine: f32,
    /// 少于这么多采样（16k）就不做声纹比对，退回 pVAD 的逐帧判据。
    /// 太短的段 embedding 不稳，硬比只会把本人误杀。
    pub min_samples: usize,
}

impl Default for VerifyConfig {
    fn default() -> Self {
        Self {
            min_cosine: 0.4,
            min_samples: 12_800, // 0.8 秒
        }
    }
}

/// 真模型。持有 ORT session 和帧间状态。
pub struct PvadScorer {
    session: Session,
    spkemb: Vec<f32>,
    /// `[1, 80, 15]`
    mel: Vec<f32>,
    /// `[2, 1, 256]`
    gru: Vec<f32>,
    /// 不足一帧的尾巴，留到下次。
    pending: Vec<f32>,
}

impl PvadScorer {
    /// `model` 是 `pvad.onnx` 的字节，`spkemb` 是 192 个 float（可以是原始
    /// 文件字节，见 [`parse_spkemb`]）。
    pub fn new(model: &[u8], spkemb: &[f32]) -> Result<Self, String> {
        if spkemb.len() != EMB_DIM {
            return Err(format!(
                "声纹维度不对：期望 {EMB_DIM}，实际 {}",
                spkemb.len()
            ));
        }

        // 防御性重新归一化。注册工具已经做过一次，这里是幂等的；
        // 但手工改过的文件、或者别的工具导出的文件就靠这一道兜住。
        let norm = spkemb.iter().map(|v| v * v).sum::<f32>().sqrt();
        if !norm.is_finite() || norm <= 1e-6 {
            return Err("声纹向量是零向量或含非法值".to_string());
        }
        let spkemb: Vec<f32> = spkemb.iter().map(|v| v / norm).collect();

        let session = Session::builder()
            .map_err(|e| format!("ORT builder: {e}"))?
            .with_intra_threads(1)
            .map_err(|e| format!("ORT 线程数: {e}"))?
            .commit_from_memory(model)
            .map_err(|e| format!("加载 pvad.onnx: {e}"))?;

        // 形状核对：模型换了而代码没跟着改时，这里要当场报出来，
        // 而不是等到第一次推理才给一个看不懂的 ORT 错误。
        let inputs: Vec<String> = session
            .inputs()
            .iter()
            .map(|i| i.name().to_string())
            .collect();
        for want in ["input_audio", "spkemb", "mel_buffer", "gru_buffer"] {
            if !inputs.iter().any(|n| n == want) {
                return Err(format!("pvad.onnx 缺输入 {want}，实际 {inputs:?}"));
            }
        }

        Ok(Self {
            session,
            spkemb,
            mel: vec![0.0; 80 * 15],
            gru: vec![0.0; 2 * 256],
            pending: Vec::with_capacity(FRAME_SAMPLES),
        })
    }

    fn step(&mut self, frame: &[f32]) -> Result<f32, String> {
        debug_assert_eq!(frame.len(), FRAME_SAMPLES);

        let audio = Tensor::from_array(([1usize, FRAME_SAMPLES], frame.to_vec()))
            .map_err(|e| format!("input_audio: {e}"))?;
        let spk = Tensor::from_array(([1usize, EMB_DIM], self.spkemb.clone()))
            .map_err(|e| format!("spkemb: {e}"))?;
        let mel = Tensor::from_array(([1usize, 80, 15], self.mel.clone()))
            .map_err(|e| format!("mel_buffer: {e}"))?;
        let gru = Tensor::from_array(([2usize, 1, 256], self.gru.clone()))
            .map_err(|e| format!("gru_buffer: {e}"))?;

        let outputs = self
            .session
            .run(ort::inputs![
                "input_audio" => audio,
                "spkemb" => spk,
                "mel_buffer" => mel,
                "gru_buffer" => gru
            ])
            .map_err(|e| format!("pvad 推理: {e}"))?;

        // 按名字取，不按顺序 —— 顺序是导出时的偶然。
        let prob = {
            let (_, p) = outputs["sigmoid_out"]
                .try_extract_tensor::<f32>()
                .map_err(|e| format!("sigmoid_out: {e}"))?;
            p[0]
        };
        let mel_out = {
            let (_, m) = outputs["mel_buffer_out"]
                .try_extract_tensor::<f32>()
                .map_err(|e| format!("mel_buffer_out: {e}"))?;
            m.to_vec()
        };
        let gru_out = {
            let (_, g) = outputs["gru_buffer_out"]
                .try_extract_tensor::<f32>()
                .map_err(|e| format!("gru_buffer_out: {e}"))?;
            g.to_vec()
        };
        drop(outputs);

        if mel_out.len() != self.mel.len() || gru_out.len() != self.gru.len() {
            return Err(format!(
                "pvad 状态形状变了：mel {} / gru {}",
                mel_out.len(),
                gru_out.len()
            ));
        }
        self.mel = mel_out;
        self.gru = gru_out;

        Ok(prob)
    }
}

impl SpeakerScorer for PvadScorer {
    fn push(&mut self, samples: &[f32], on_frame: &mut dyn FnMut(f32)) -> Result<(), String> {
        self.pending.extend_from_slice(samples);
        let mut offset = 0;
        while offset + FRAME_SAMPLES <= self.pending.len() {
            // 复制一份再推理：`step` 要可变借用 self，不能同时借用 pending。
            let frame: Vec<f32> = self.pending[offset..offset + FRAME_SAMPLES].to_vec();
            let p = self.step(&frame)?;
            on_frame(p);
            offset += FRAME_SAMPLES;
        }
        self.pending.drain(..offset);
        Ok(())
    }

    fn reset(&mut self) {
        self.mel.fill(0.0);
        self.gru.fill(0.0);
        self.pending.clear();
    }
}

/// 读声纹文件：192 个 little-endian f32，正好 768 字节。
///
/// 只认裸字节，不认 WAV / JSON —— 格式越少，导入口子越不容易被塞进
/// 一个"看起来成功了其实是乱码"的文件。
pub fn parse_spkemb(bytes: &[u8]) -> Result<Vec<f32>, String> {
    if bytes.len() != SPKEMB_BYTES {
        return Err(format!(
            "声纹文件应该是 {SPKEMB_BYTES} 字节（192 个 float32），实际 {}",
            bytes.len()
        ));
    }
    let mut out = Vec::with_capacity(EMB_DIM);
    for c in bytes.chunks_exact(4) {
        let v = f32::from_le_bytes([c[0], c[1], c[2], c[3]]);
        if !v.is_finite() {
            return Err("声纹文件里有 NaN 或无穷大".to_string());
        }
        out.push(v);
    }
    let norm = out.iter().map(|v| v * v).sum::<f32>().sqrt();
    if norm <= 1e-6 {
        return Err("声纹向量是零向量".to_string());
    }
    Ok(out)
}

/// 说话人门控：把逐帧概率按"段"汇总，决定这一段要不要。
pub struct SpeakerGate {
    scorer: Option<Box<dyn SpeakerScorer>>,
    /// 整段声纹比对。比 pVAD 的逐帧概率可靠得多，有它时以它为准。
    verifier: Option<Box<dyn SpeakerVerifier>>,
    verify: VerifyConfig,
    cfg: PvadConfig,
    /// `(帧结束的绝对采样下标, 平滑后概率)`，按时间升序。
    history: VecDeque<(usize, f32)>,
    /// 下一帧的起始绝对采样下标。
    frame_cursor: usize,
    /// 第一段音频进来过没有。
    ///
    /// **不能拿 `frame_cursor == 0` 当这个标志**：会话从 0 开始时它本来就是 0，
    /// 而第一段不足 160 采样时 `frame_cursor` 会一直是 0，下一段就会被
    /// 重新对齐到错误的位置，帧边界整体错开。
    started: bool,
    smooth: Option<f32>,
    last: f32,
    enabled: bool,
    filtered: u32,
    error: Option<String>,
}

impl Default for SpeakerGate {
    fn default() -> Self {
        Self {
            scorer: None,
            verifier: None,
            verify: VerifyConfig::default(),
            cfg: PvadConfig::default(),
            history: VecDeque::new(),
            frame_cursor: 0,
            started: false,
            smooth: None,
            last: 0.0,
            enabled: false,
            filtered: 0,
            error: None,
        }
    }
}

impl SpeakerGate {
    pub fn attach(&mut self, scorer: Box<dyn SpeakerScorer>, cfg: PvadConfig) {
        scorer_reset(&mut self.scorer);
        self.scorer = Some(scorer);
        self.cfg = cfg;
        self.enabled = true;
        self.history.clear();
        self.frame_cursor = 0;
        self.started = false;
        self.smooth = None;
        self.last = 0.0;
        self.filtered = 0;
        self.error = None;
    }

    /// 挂上整段声纹比对。可以和 pVAD 同时挂；有它时，够长的段以 cosine 为准，
    /// 短段仍然退回 pVAD。
    pub fn attach_verifier(&mut self, verifier: Box<dyn SpeakerVerifier>, cfg: VerifyConfig) {
        self.verifier = Some(verifier);
        self.verify = cfg;
        self.enabled = true;
        self.error = None;
    }

    pub fn detach(&mut self) {
        if let Some(mut s) = self.scorer.take() {
            s.reset();
        }
        self.verifier = None;
        self.enabled = false;
        self.history.clear();
        self.smooth = None;
        self.last = 0.0;
        self.error = None;
    }

    pub fn reset(&mut self) {
        if let Some(s) = self.scorer.as_mut() {
            s.reset();
        }
        self.history.clear();
        self.frame_cursor = 0;
        self.started = false;
        self.smooth = None;
        self.last = 0.0;
        self.filtered = 0;
        self.error = None;
    }

    pub fn enabled(&self) -> bool {
        self.enabled
    }

    /// 挂上之后，因为不是目标人而被丢掉的段数。
    pub fn filtered(&self) -> u32 {
        self.filtered
    }

    /// 整段声纹比对是否挂上了。
    pub fn verify_enabled(&self) -> bool {
        self.verifier.is_some()
    }

    /// 声纹比对要求的最短音频长度（采样数）。短于它的段 [`Self::verify`]
    /// 会直接返回 `None`。调用方在挑完语音帧之后要用它判断够不够长。
    pub fn min_verify_samples(&self) -> usize {
        self.verify.min_samples
    }

    /// 推理失败的原因。一旦出错就自动降级为"不门控"：
    /// 语音识别比说话人识别重要，pVAD 挂了不能把整条链路拖死。
    pub fn error(&self) -> Option<&str> {
        self.error.as_deref()
    }

    /// 喂一段 16k 采样。`base` 是这段采样第一个样本的绝对下标。
    ///
    /// 出错不返回 Err，而是记下原因并关掉门控 —— 见 [`Self::error`]。
    pub fn push(&mut self, samples: &[f32], base: usize) {
        if !self.enabled {
            return;
        }
        if !self.started {
            // 第一次喂（或者 reset 之后）：对齐到这一段开头。
            self.frame_cursor = base;
            self.started = true;
        }

        let mut new_frames: Vec<f32> = Vec::new();
        let mut smooth = self.smooth.unwrap_or(0.0);
        let mut first = self.smooth.is_none();

        let result = {
            let scorer = match self.scorer.as_mut() {
                Some(s) => s,
                None => return,
            };
            scorer.push(samples, &mut |raw| {
                // 和 LiveKit ExpFilter 一样：第一帧直接取原值，之后做 EMA。
                if first {
                    smooth = raw;
                    first = false;
                } else {
                    smooth = EMA_ALPHA * smooth + (1.0 - EMA_ALPHA) * raw;
                }
                new_frames.push(smooth);
            })
        };

        match result {
            Ok(()) => {
                self.smooth = Some(smooth);
                for (i, p) in new_frames.iter().enumerate() {
                    let end = self.frame_cursor + (i + 1) * FRAME_SAMPLES;
                    self.history.push_back((end, *p));
                }
                self.frame_cursor += new_frames.len() * FRAME_SAMPLES;
                self.last = new_frames.last().copied().unwrap_or(self.last);

                // 只保留最近 HISTORY_MS 的概率。
                let keep = HISTORY_MS * 16; // 16k 下每毫秒 16 个采样
                while let Some((end, _)) = self.history.front() {
                    if *end + keep < self.frame_cursor {
                        self.history.pop_front();
                    } else {
                        break;
                    }
                }
            }
            Err(e) => {
                self.enabled = false;
                self.error = Some(e);
                self.history.clear();
                if let Some(mut s) = self.scorer.take() {
                    s.reset();
                }
            }
        }
    }

    /// 统计绝对采样区间 `[from, to)` 里的帧。
    ///
    /// 用帧**中心**判定归属，避免段边界正好落在帧中间时一帧算进两段。
    pub fn score(&self, from: usize, to: usize) -> Option<SegmentScore> {
        if !self.enabled || to <= from {
            return None;
        }
        let mut sum = 0.0f64;
        let mut target = 0u32;
        let mut frames = 0u32;
        for (end, p) in &self.history {
            let start = end.saturating_sub(FRAME_SAMPLES);
            let center = start + FRAME_SAMPLES / 2;
            if center < from || center >= to {
                continue;
            }
            frames += 1;
            sum += *p as f64;
            if *p >= self.cfg.threshold {
                target += 1;
            }
        }
        if frames == 0 {
            return None;
        }
        Some(SegmentScore {
            mean: (sum / frames as f64) as f32,
            target_ratio: target as f32 / frames as f32,
            frames,
        })
    }

    /// 跑一次整段声纹比对。
    ///
    /// 返回 `None` 表示这一段用不上声纹（没挂比对器，或者段太短），
    /// 调用方应退回 pVAD 的逐帧判据。
    ///
    /// 推理失败时只摘掉比对器，不关整个门控：pVAD 还在，链路不会断。
    pub fn verify(&mut self, samples: &[f32]) -> Option<f32> {
        if !self.enabled || samples.len() < self.verify.min_samples {
            return None;
        }
        let result = match self.verifier.as_mut() {
            Some(v) => v.cosine(samples),
            None => return None,
        };
        match result {
            Ok(c) if c.is_finite() => Some(c),
            Ok(_) => None,
            Err(e) => {
                self.verifier = None;
                self.error = Some(e);
                if self.scorer.is_none() {
                    self.enabled = false;
                }
                None
            }
        }
    }

    /// 这一段是不是目标说话人。
    ///
    /// 有整段 cosine 时以它为准；否则退回 pVAD 的逐帧占比。
    /// 没挂模型、或者统计不到帧，一律放行 —— 门控是**附加**的过滤，
    /// 不能变成"没数据就全丢"。
    pub fn is_target(&self, score: Option<SegmentScore>, cosine: Option<f32>) -> bool {
        if !self.enabled {
            return true;
        }
        if let Some(c) = cosine {
            return c >= self.verify.min_cosine;
        }
        match score {
            Some(s) if s.frames > 0 => s.target_ratio >= self.cfg.min_target_ratio,
            _ => true,
        }
    }

    pub fn mark_filtered(&mut self) {
        self.filtered += 1;
    }

    /// 最近一帧的平滑概率（调试面板用）。
    pub fn last(&self) -> f32 {
        self.last
    }
}

fn scorer_reset(scorer: &mut Option<Box<dyn SpeakerScorer>>) {
    if let Some(s) = scorer.as_mut() {
        s.reset();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 按预设概率出帧的假打分器：每 160 个采样吐一个值。
    struct FakeScorer {
        probs: Vec<f32>,
        pos: usize,
        pending: usize,
    }

    impl FakeScorer {
        fn new(probs: Vec<f32>) -> Self {
            Self {
                probs,
                pos: 0,
                pending: 0,
            }
        }
    }

    impl SpeakerScorer for FakeScorer {
        fn push(&mut self, samples: &[f32], on_frame: &mut dyn FnMut(f32)) -> Result<(), String> {
            self.pending += samples.len();
            while self.pending >= FRAME_SAMPLES {
                self.pending -= FRAME_SAMPLES;
                let p = self.probs.get(self.pos).copied().unwrap_or(0.0);
                self.pos += 1;
                on_frame(p);
            }
            Ok(())
        }

        fn reset(&mut self) {
            self.pos = 0;
            self.pending = 0;
        }
    }

    fn gate_with(probs: Vec<f32>) -> SpeakerGate {
        let mut g = SpeakerGate::default();
        g.attach(Box::new(FakeScorer::new(probs)), PvadConfig::default());
        g
    }

    #[test]
    fn parse_spkemb_roundtrip_keeps_raw_values() {
        let mut v = vec![0.0f32; EMB_DIM];
        v[0] = 3.0;
        v[1] = 4.0; // norm = 5
        let mut bytes = Vec::new();
        for x in &v {
            bytes.extend_from_slice(&x.to_le_bytes());
        }
        // 解析只负责读出数值，归一化在 `PvadScorer::new` 里做 ——
        // 这样文件里存的是什么就能原样核出来。
        let parsed = parse_spkemb(&bytes).unwrap();
        assert_eq!(parsed.len(), EMB_DIM);
        assert!((parsed[0] - 3.0).abs() < 1e-6);
        assert!((parsed[1] - 4.0).abs() < 1e-6);
    }

    #[test]
    fn parse_spkemb_rejects_wrong_size() {
        assert!(parse_spkemb(&[0u8; 767]).is_err());
        assert!(parse_spkemb(&[0u8; 769]).is_err());
    }

    #[test]
    fn parse_spkemb_rejects_zero() {
        assert!(parse_spkemb(&[0u8; SPKEMB_BYTES]).is_err());
    }

    #[test]
    fn target_speaker_segment_is_kept() {
        let mut g = gate_with(vec![0.95; 100]);
        // 1 秒 = 100 帧
        g.push(&vec![0.1; 16000], 0);
        let s = g.score(0, 16000).expect("应该有帧");
        assert!(s.frames >= 99, "帧数 {}", s.frames);
        assert!(g.is_target(Some(s), None));
        assert!((s.mean - 0.95).abs() < 0.01, "mean {}", s.mean);
    }

    #[test]
    fn other_speaker_segment_is_filtered() {
        let mut g = gate_with(vec![0.02; 100]);
        g.push(&vec![0.1; 16000], 0);
        let s = g.score(0, 16000).unwrap();
        assert!(!g.is_target(Some(s), None));
        g.mark_filtered();
        assert_eq!(g.filtered(), 1);
    }

    #[test]
    fn mixed_segment_uses_target_ratio() {
        // 一半 0.9、一半 0.0；ratio 约 0.5，默认阈值 0.5 → 保留
        let mut probs = vec![0.9; 50];
        probs.extend(vec![0.0; 50]);
        let mut g = gate_with(probs);
        g.push(&vec![0.1; 16000], 0);
        let s = g.score(0, 16000).unwrap();
        assert!(s.target_ratio >= 0.5, "ratio {}", s.target_ratio);
        assert!(g.is_target(Some(s), None));
    }

    #[test]
    fn score_is_restricted_to_the_requested_range() {
        // 前 0.5 秒是目标人，后 0.5 秒是别人
        let mut probs = vec![0.95; 50];
        probs.extend(vec![0.02; 50]);
        let mut g = gate_with(probs);
        g.push(&vec![0.1; 16000], 0);

        let first = g.score(0, 8000).unwrap();
        let second = g.score(8000, 16000).unwrap();
        assert!(g.is_target(Some(first), None));
        assert!(!g.is_target(Some(second), None));
    }

    #[test]
    fn gating_is_disabled_without_a_scorer() {
        let g = SpeakerGate::default();
        assert!(!g.enabled());
        assert!(g.is_target(None, None));
        assert_eq!(g.filtered(), 0);
    }

    #[test]
    fn reset_clears_history_and_rebases_cursor() {
        let mut g = gate_with(vec![0.9; 100]);
        g.push(&vec![0.1; 16000], 0);
        assert!(g.score(0, 16000).is_some());
        g.reset();
        assert!(g.score(0, 16000).is_none());
        // reset 之后从 0 重新数，绝对下标不再接续
        g.push(&vec![0.1; 1600], 0);
        assert!(g.score(0, 1600).is_some());
    }

    #[test]
    fn arbitrary_chunk_sizes_do_not_shift_frame_alignment() {
        let mut g = gate_with(vec![0.9; 100]);
        for chunk in [17usize, 3, 500, 320, 1, 160] {
            g.push(&vec![0.1; chunk], 0);
        }
        let total: usize = [17, 3, 500, 320, 1, 160].iter().sum();
        let s = g.score(0, total).unwrap();
        assert_eq!(s.frames as usize, total / FRAME_SAMPLES);
    }

    #[test]
    fn real_pvad_model_loads_and_keeps_frame_state() {
        // 模型是仓库里的资产，不是代码生成的；路径相对 crate 根。
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../assets/models/pvad.onnx");
        let bytes = std::fs::read(path).expect("assets/models/pvad.onnx 应该在仓库里");
        let mut emb = vec![0.0f32; EMB_DIM];
        emb[0] = 1.0;
        let mut scorer = PvadScorer::new(&bytes, &emb).expect("真模型应该能加载");

        let mut probs = Vec::new();
        scorer
            .push(&vec![0.0f32; 1600], &mut |p| probs.push(p))
            .unwrap();
        assert_eq!(probs.len(), 10, "1600 采样 = 100ms = 10 帧");
        assert!(probs[0] > 0.0 && probs[0] < 0.2, "零输入 {}", probs[0]);
        // 状态确实在推进：第二帧和第一帧不会逐位相同。
        assert_ne!(probs[0], probs[1]);
    }

    #[test]
    fn a_short_first_chunk_does_not_shift_frame_alignment() {
        // 第一段不足一帧，第二段才凑满。帧的绝对边界必须仍然从 0 开始数，
        // 不能被"第二段的起点"重新对齐。
        let mut g = gate_with(vec![0.9; 10]);
        g.push(&vec![0.1; 100], 0);
        g.push(&vec![0.1; 220], 100);

        // 正确对齐：帧 1 覆盖 [0,160)，中心 80，落在 [0,160) 里。
        // 错位的话这里会是 0 帧。
        let first = g.score(0, 160).expect("第一帧应该落在 [0,160)");
        assert_eq!(first.frames, 1);
        assert_eq!(g.score(0, 320).unwrap().frames, 2);
    }

    #[test]
    fn empty_range_has_no_score() {
        let mut g = gate_with(vec![0.9; 10]);
        g.push(&vec![0.1; 1600], 0);
        assert!(g.score(1600, 1600).is_none());
        assert!(g.score(2000, 3000).is_none());
        // 没有分数的段照样放行
        assert!(g.is_target(None, None));
    }

    /// 固定 cosine 的假比对器。
    struct FakeVerifier {
        cosine: f32,
        fail: bool,
    }

    impl SpeakerVerifier for FakeVerifier {
        fn cosine(&mut self, _samples: &[f32]) -> Result<f32, String> {
            if self.fail {
                Err("假比对器失败".to_string())
            } else {
                Ok(self.cosine)
            }
        }
    }

    fn gate_with_verifier(cosine: f32, fail: bool) -> SpeakerGate {
        let mut g = gate_with(vec![0.9; 10]);
        g.attach_verifier(
            Box::new(FakeVerifier { cosine, fail }),
            VerifyConfig {
                min_cosine: 0.4,
                min_samples: 1000,
            },
        );
        g
    }

    #[test]
    fn long_segment_is_decided_by_cosine_not_pvad() {
        // pVAD 给的是 0.9（会放行），但 cosine 低 —— 必须以 cosine 为准。
        let mut g = gate_with_verifier(0.1, false);
        let samples = vec![0.1f32; 2000];
        let cos = g.verify(&samples).expect("够长，应该比");
        assert!((cos - 0.1).abs() < 1e-6);
        let score = g.score(0, 1600);
        assert!(!g.is_target(score, Some(cos)), "cosine 低就该丢");

        let mut g = gate_with_verifier(0.8, false);
        let cos = g.verify(&samples).unwrap();
        assert!(g.is_target(g.score(0, 1600), Some(cos)), "cosine 高就该留");
    }

    #[test]
    fn short_segment_falls_back_to_pvad() {
        let mut g = gate_with_verifier(0.0, false);
        g.push(&vec![0.1f32; 1600], 0);
        let short = vec![0.1f32; 500];
        assert!(g.verify(&short).is_none(), "太短不比声纹");
        // 退回 pVAD：这一段 pVAD 是 0.9，放行。
        assert!(g.is_target(g.score(0, 1600), None));
    }

    #[test]
    fn verifier_failure_degrades_to_pvad() {
        let mut g = gate_with_verifier(0.0, true);
        g.push(&vec![0.1f32; 1600], 0);
        let samples = vec![0.1f32; 2000];
        assert!(g.verify(&samples).is_none());
        assert!(g.error().is_some(), "失败原因要留下来");
        // pVAD 还在，所以门控没被整个关掉。
        assert!(g.enabled());
        assert!(g.is_target(g.score(0, 1600), None));
    }
}

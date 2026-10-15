//! `reason-vad` is a minimal, CPU-only, on-device voice activity detection library.
//!
//! Ergonomic defaults:
//! - 16kHz input
//! - 512-sample inference frame
//! - embedded Silero ONNX model (no runtime download)
//! - single-thread ORT session to reduce host CPU impact

mod model;
mod vad;

use std::path::Path;

use ndarray::ArrayView1;

use model::{FRAME_SIZE, SAMPLE_RATE, SileroVadModel};
use vad::StreamVad;

pub const SAMPLE_RATE_HZ: u32 = SAMPLE_RATE;
pub const FRAME_SAMPLES: usize = FRAME_SIZE;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SpeechSegment {
    /// Segment start time in seconds.
    pub start: f32,
    /// Segment end time in seconds.
    pub end: f32,
    /// Start sample offset from the beginning of the input stream.
    pub start_sample: usize,
    /// End sample offset from the beginning of the input stream.
    pub end_sample: usize,
}

impl SpeechSegment {
    /// Segment range in sample offsets, useful for slicing original PCM.
    pub fn sample_range(&self) -> std::ops::Range<usize> {
        self.start_sample..self.end_sample
    }
}

#[derive(Debug, Clone)]
pub struct ReasonVadConfig {
    pub threshold: f32,
    pub min_silence_duration_ms: u32,
    pub speech_pad_ms: u32,
    pub min_speech_duration_ms: u32,
    pub max_speech_duration_s: f32,
}

impl Default for ReasonVadConfig {
    fn default() -> Self {
        Self {
            threshold: 0.5,
            min_silence_duration_ms: 100,
            speech_pad_ms: 30,
            min_speech_duration_ms: 250,
            max_speech_duration_s: f32::INFINITY,
        }
    }
}

impl ReasonVadConfig {
    pub fn with_threshold(mut self, threshold: f32) -> Self {
        self.threshold = threshold;
        self
    }

    pub fn with_min_silence_duration_ms(mut self, ms: u32) -> Self {
        self.min_silence_duration_ms = ms;
        self
    }

    pub fn with_speech_pad_ms(mut self, ms: u32) -> Self {
        self.speech_pad_ms = ms;
        self
    }

    pub fn with_min_speech_duration_ms(mut self, ms: u32) -> Self {
        self.min_speech_duration_ms = ms;
        self
    }

    pub fn with_max_speech_duration_s(mut self, seconds: f32) -> Self {
        self.max_speech_duration_s = seconds;
        self
    }
}

pub struct ReasonVad {
    cfg: ReasonVadConfig,
    engine: StreamVad,
    pending_frame: [f32; FRAME_SIZE],
    pending_len: usize,
    observed_samples: usize,
}

impl ReasonVad {
    /// Create VAD with ergonomic defaults.
    pub fn new() -> Result<Self> {
        Self::with_config(ReasonVadConfig::default())
    }

    /// Create VAD with custom config and embedded model.
    pub fn with_config(cfg: ReasonVadConfig) -> Result<Self> {
        let model = SileroVadModel::new()?;
        Ok(Self::with_engine(model, cfg))
    }

    /// Create VAD from custom ONNX bytes.
    pub fn from_onnx_bytes(model_bytes: &[u8], cfg: ReasonVadConfig) -> Result<Self> {
        let model = SileroVadModel::from_bytes(model_bytes)?;
        Ok(Self::with_engine(model, cfg))
    }

    /// Create VAD from custom ONNX file path.
    pub fn from_onnx_file<P: AsRef<Path>>(model_path: P, cfg: ReasonVadConfig) -> Result<Self> {
        let model = SileroVadModel::from_file(model_path)?;
        Ok(Self::with_engine(model, cfg))
    }

    fn with_engine(model: SileroVadModel, cfg: ReasonVadConfig) -> Self {
        let engine = StreamVad::new(
            model,
            cfg.threshold,
            cfg.min_silence_duration_ms,
            cfg.speech_pad_ms,
        );
        Self {
            cfg,
            engine,
            pending_frame: [0.0; FRAME_SIZE],
            pending_len: 0,
            observed_samples: 0,
        }
    }

    fn clamp_to_observed(&self, mut segment: SpeechSegment) -> SpeechSegment {
        segment.end_sample = segment.end_sample.min(self.observed_samples);
        if segment.start_sample > segment.end_sample {
            segment.start_sample = segment.end_sample;
        }
        segment.start = segment.start_sample as f32 / SAMPLE_RATE as f32;
        segment.end = segment.end_sample as f32 / SAMPLE_RATE as f32;
        segment
    }

    /// Frame size required by `process_frame`.
    pub fn frame_size(&self) -> usize {
        self.engine.frame_size()
    }

    pub fn is_speaking(&self) -> bool {
        self.engine.is_speaking()
    }

    /// 最近一帧的语音概率（0.0~1.0）。**本仓库的本地改动**，上游未暴露。
    pub fn last_probability(&self) -> f32 {
        self.engine.last_probability()
    }

    /// Process one 512-sample frame and return a segment if one is closed.
    pub fn process_frame(&mut self, frame: &[f32]) -> Result<Option<SpeechSegment>> {
        if self.pending_len != 0 {
            return Err(Error::InvalidInput(
                "cannot call `process_frame` while partial PCM is buffered; call `finish` or `reset`"
                    .into(),
            ));
        }
        if frame.len() != FRAME_SIZE {
            return Err(Error::InvalidInput(format!(
                "frame must contain exactly {FRAME_SIZE} samples"
            )));
        }

        self.observed_samples += FRAME_SIZE;
        let frame_view = ArrayView1::from(frame);
        Ok(self
            .engine
            .process_frame(&frame_view)?
            .map(|segment| self.clamp_to_observed(segment)))
    }

    /// Process arbitrary-length PCM and emit all closed speech segments.
    ///
    /// This is the recommended streaming API. It accepts any chunk size and internally
    /// handles 512-sample framing.
    pub fn process_pcm(&mut self, samples: &[f32]) -> Result<Vec<SpeechSegment>> {
        if samples.is_empty() {
            return Ok(Vec::new());
        }

        self.observed_samples += samples.len();
        let mut out = Vec::new();
        let mut cursor = 0;

        while cursor < samples.len() {
            let needed = FRAME_SIZE - self.pending_len;
            let available = samples.len() - cursor;
            let take = needed.min(available);

            self.pending_frame[self.pending_len..self.pending_len + take]
                .copy_from_slice(&samples[cursor..cursor + take]);
            self.pending_len += take;
            cursor += take;

            if self.pending_len == FRAME_SIZE {
                let frame = ArrayView1::from(&self.pending_frame[..]);
                if let Some(segment) = self.engine.process_frame(&frame)? {
                    out.push(self.clamp_to_observed(segment));
                }
                self.pending_len = 0;
            }
        }

        Ok(out)
    }

    /// Detect speech segments for a complete audio buffer.
    ///
    /// This call is independent from streaming state and leaves the instance reset.
    pub fn detect_segments(&mut self, audio: &[f32]) -> Result<Vec<SpeechSegment>> {
        self.pending_len = 0;
        self.observed_samples = 0;

        let audio_view = ArrayView1::from(audio);
        let segments = self.engine.detect_segments(
            &audio_view,
            self.cfg.min_speech_duration_ms,
            self.cfg.max_speech_duration_s,
        )?;

        self.engine.reset();
        Ok(segments)
    }

    /// Flush currently active segment without processing buffered partial frame.
    ///
    /// Prefer `finish` at end-of-stream.
    pub fn flush(&mut self) -> Option<SpeechSegment> {
        self.engine
            .flush()
            .map(|segment| self.clamp_to_observed(segment))
    }

    /// Finalize end-of-stream: process buffered tail (zero-padded) and flush active speech.
    pub fn finish(&mut self) -> Result<Vec<SpeechSegment>> {
        let mut out = Vec::new();

        if self.pending_len > 0 {
            self.pending_frame[self.pending_len..].fill(0.0);
            let frame = ArrayView1::from(&self.pending_frame[..]);
            if let Some(segment) = self.engine.process_frame(&frame)? {
                out.push(self.clamp_to_observed(segment));
            }
            self.pending_len = 0;
        }

        if let Some(segment) = self.engine.flush() {
            out.push(self.clamp_to_observed(segment));
        }

        Ok(out)
    }

    /// Reset recurrent state and segmentation state.
    pub fn reset(&mut self) {
        self.pending_len = 0;
        self.observed_samples = 0;
        self.pending_frame.fill(0.0);
        self.engine.reset();
    }
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("Model loading error: {0}")]
    ModelLoad(String),
    #[error("Invalid input: {0}")]
    InvalidInput(String),
    #[error("ONNX Runtime error: {0}")]
    Ort(#[from] ort::Error),
}

pub type Result<T> = std::result::Result<T, Error>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_model_initializes() {
        let mut vad = ReasonVad::new().expect("embedded model should initialize");
        let frame = vec![0.0_f32; FRAME_SAMPLES];
        let _ = vad.process_frame(&frame).expect("single frame should run");
    }

    #[test]
    fn process_pcm_accepts_arbitrary_chunk_sizes() {
        let mut vad = ReasonVad::new().expect("embedded model should initialize");
        let samples = vec![0.0_f32; FRAME_SAMPLES * 2 + 123];

        let segments = vad.process_pcm(&samples).expect("streaming should work");
        assert!(segments.is_empty());

        let final_segments = vad.finish().expect("finish should work");
        assert!(final_segments.is_empty());
    }
}

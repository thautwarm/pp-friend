use ndarray::{ArrayView1, s};

use crate::{
    Result, SpeechSegment,
    model::{FRAME_SIZE, SAMPLE_RATE, SileroVadModel},
};

pub(crate) struct StreamVad {
    model: SileroVadModel,
    threshold: f32,
    min_silence_duration_ms: u32,
    speech_pad_ms: u32,
    speech_start_sample: Option<usize>,
    last_speech_sample: Option<usize>,
    processed_samples: usize,
    /// 最近一帧的语音概率。**本仓库的本地改动**（上游没暴露），
    /// 用来在调试面板上观测模型对当前音频的判定，调阈值时最有用。
    last_probability: f32,
}

impl StreamVad {
    pub(crate) fn new(
        model: SileroVadModel,
        threshold: f32,
        min_silence_duration_ms: u32,
        speech_pad_ms: u32,
    ) -> Self {
        Self {
            model,
            threshold,
            min_silence_duration_ms,
            speech_pad_ms,
            speech_start_sample: None,
            last_speech_sample: None,
            processed_samples: 0,
            last_probability: 0.0,
        }
    }

    pub(crate) fn last_probability(&self) -> f32 {
        self.last_probability
    }

    fn ms_to_samples(ms: u32) -> usize {
        ((ms as usize) * (SAMPLE_RATE as usize)) / 1000
    }

    fn min_silence_samples(&self) -> usize {
        Self::ms_to_samples(self.min_silence_duration_ms)
    }

    fn speech_pad_samples(&self) -> usize {
        Self::ms_to_samples(self.speech_pad_ms)
    }

    fn emit_segment(
        &self,
        start_sample: usize,
        end_sample: usize,
        max_end: usize,
    ) -> SpeechSegment {
        let pad = self.speech_pad_samples();
        let padded_start = start_sample.saturating_sub(pad);
        let padded_end = end_sample.saturating_add(pad).min(max_end);
        SpeechSegment {
            start: padded_start as f32 / SAMPLE_RATE as f32,
            end: padded_end as f32 / SAMPLE_RATE as f32,
            start_sample: padded_start,
            end_sample: padded_end,
        }
    }

    fn clamp_segment_end(segment: &mut SpeechSegment, max_end_sample: usize) {
        segment.end_sample = segment.end_sample.min(max_end_sample);
        if segment.start_sample > segment.end_sample {
            segment.start_sample = segment.end_sample;
        }
        segment.start = segment.start_sample as f32 / SAMPLE_RATE as f32;
        segment.end = segment.end_sample as f32 / SAMPLE_RATE as f32;
    }

    fn update_with_probability(
        &mut self,
        probability: f32,
        frame_len: usize,
    ) -> Option<SpeechSegment> {
        let frame_start = self.processed_samples;
        let frame_end = frame_start + frame_len;
        let mut emitted = None;
        self.last_probability = probability;

        if probability >= self.threshold {
            if self.speech_start_sample.is_none() {
                self.speech_start_sample = Some(frame_start);
            }
            self.last_speech_sample = Some(frame_end);
        } else if let (Some(start), Some(last_speech)) =
            (self.speech_start_sample, self.last_speech_sample)
        {
            let silence = frame_end.saturating_sub(last_speech);
            if silence >= self.min_silence_samples() {
                emitted = Some(self.emit_segment(start, last_speech, frame_end));
                self.speech_start_sample = None;
                self.last_speech_sample = None;
            }
        }

        self.processed_samples = frame_end;
        emitted
    }

    pub(crate) fn process_frame(
        &mut self,
        frame: &ArrayView1<f32>,
    ) -> Result<Option<SpeechSegment>> {
        let probability = self.model.process_frame(frame)?;
        Ok(self.update_with_probability(probability, frame.len()))
    }

    pub(crate) fn flush(&mut self) -> Option<SpeechSegment> {
        let result = match (self.speech_start_sample, self.last_speech_sample) {
            (Some(start), Some(end)) => Some(self.emit_segment(start, end, self.processed_samples)),
            _ => None,
        };
        self.speech_start_sample = None;
        self.last_speech_sample = None;
        result
    }

    pub(crate) fn reset(&mut self) {
        self.speech_start_sample = None;
        self.last_speech_sample = None;
        self.processed_samples = 0;
        self.last_probability = 0.0;
        self.model.reset_states(1);
    }

    pub(crate) fn detect_segments(
        &mut self,
        audio: &ArrayView1<f32>,
        min_speech_duration_ms: u32,
        max_speech_duration_s: f32,
    ) -> Result<Vec<SpeechSegment>> {
        self.reset();
        let mut segments = Vec::new();
        let max_end_sample = audio.len();
        let mut idx = 0;

        while idx + FRAME_SIZE <= audio.len() {
            let frame = audio.slice(s![idx..idx + FRAME_SIZE]);
            if let Some(mut segment) = self.process_frame(&frame)?
                && Self::keep_segment(&segment, min_speech_duration_ms, max_speech_duration_s)
            {
                Self::clamp_segment_end(&mut segment, max_end_sample);
                segments.push(segment);
            }
            idx += FRAME_SIZE;
        }

        if idx < audio.len() {
            let mut tail = [0.0_f32; FRAME_SIZE];
            let remainder = audio.slice(s![idx..]);
            for (dst, src) in tail.iter_mut().zip(remainder.iter()) {
                *dst = *src;
            }
            let frame = ArrayView1::from(&tail);
            if let Some(mut segment) = self.process_frame(&frame)?
                && Self::keep_segment(&segment, min_speech_duration_ms, max_speech_duration_s)
            {
                Self::clamp_segment_end(&mut segment, max_end_sample);
                segments.push(segment);
            }
        }

        if let Some(mut segment) = self.flush() {
            Self::clamp_segment_end(&mut segment, max_end_sample);
            if Self::keep_segment(&segment, min_speech_duration_ms, max_speech_duration_s) {
                segments.push(segment);
            }
        }

        Ok(segments)
    }

    fn keep_segment(
        segment: &SpeechSegment,
        min_speech_duration_ms: u32,
        max_speech_duration_s: f32,
    ) -> bool {
        let duration_samples = segment.end_sample.saturating_sub(segment.start_sample);
        let min_samples = ((min_speech_duration_ms as usize) * (SAMPLE_RATE as usize)) / 1000;
        let max_samples = if max_speech_duration_s.is_finite() {
            if max_speech_duration_s < 0.0 {
                0
            } else {
                (max_speech_duration_s * SAMPLE_RATE as f32) as usize
            }
        } else {
            usize::MAX
        };
        duration_samples >= min_samples && duration_samples <= max_samples
    }

    pub(crate) fn frame_size(&self) -> usize {
        FRAME_SIZE
    }

    pub(crate) fn is_speaking(&self) -> bool {
        self.speech_start_sample.is_some()
    }
}

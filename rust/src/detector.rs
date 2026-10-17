//! 检测器的抽象层。
//!
//! 放在 `crate::api` 之外是刻意的：frb 只扫描 `crate::api`，把这个 trait
//! 留在那里会让它出现在生成的 Dart 里（还会顺带把 `reason_vad::SpeechSegment`
//! 也翻出来），而那些东西 Dart 侧根本用不到。
//!
//! 抽象本身只有一个目的：切段、最短过滤、强制切句这些**逻辑**能用确定性的
//! 假检测器测到，不必依赖模型对某段具体音频怎么判。

use reason_vad::{FrameProb, ReasonVad, SpeechSegment};

// `Send + Sync` 不是可选的：handle 是 frb 的 opaque 类型，会被包进 `RwLock`，
// 而 `RwLock<T>: Sync` 要求 `T: Send + Sync`。少一个 bound 编译就不过。
pub trait SpeechDetector: Send + Sync {
    fn process_pcm(&mut self, samples: &[f32]) -> Result<Vec<SpeechSegment>, String>;
    fn flush(&mut self) -> Option<SpeechSegment>;
    fn is_speaking(&self) -> bool;
    fn last_probability(&self) -> f32;

    /// 逐帧语音概率历史（含采样区间）。默认空 —— 假检测器不需要它。
    ///
    /// 用来在算声纹时跳过段内的静音帧。
    fn frame_probabilities(&self) -> &[FrameProb] {
        &[]
    }

    fn reset(&mut self);
}

impl SpeechDetector for ReasonVad {
    fn process_pcm(&mut self, samples: &[f32]) -> Result<Vec<SpeechSegment>, String> {
        ReasonVad::process_pcm(self, samples).map_err(|e| e.to_string())
    }
    fn flush(&mut self) -> Option<SpeechSegment> {
        ReasonVad::flush(self)
    }
    fn is_speaking(&self) -> bool {
        ReasonVad::is_speaking(self)
    }
    fn last_probability(&self) -> f32 {
        ReasonVad::last_probability(self)
    }
    fn frame_probabilities(&self) -> &[FrameProb] {
        ReasonVad::frame_probabilities(self)
    }
    fn reset(&mut self) {
        ReasonVad::reset(self)
    }
}

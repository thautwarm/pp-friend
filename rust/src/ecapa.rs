//! ECAPA 声纹比对。
//!
//! pVAD 自己的 sigmoid 输出主要反映"像不像语音"，对"是谁"其实很弱 ——
//! 实测里目标人和家人能一起到 0.9。真正能分开两个人的，是说话人 embedding
//! 本身的余弦相似度：同一个人的两段录音通常 > 0.5，不同人通常 < 0.3。
//!
//! 这里的模型和注册网页（`tools/voiceprint`）导出的是同一份
//! `spkrec-ecapa-voxceleb`，所以注册时生成的 192 维向量可以直接拿来比。
//! 模型 81 MiB，只在门控打开时加载一次。

use ort::session::Session;
use ort::value::Tensor;

use crate::pvad::EMB_DIM;

/// 最多用一段话的前 3 秒算 embedding。
///
/// 3 秒已经足够稳定（同一段 3 秒窗口和整段录音的 cosine 约 0.92），
/// 再长只会线性增加延迟。段中间的停顿也不该拖慢判定的时间点。
pub const MAX_VERIFY_SAMPLES: usize = 3 * 16_000;

/// 单次推理用几路线程。
///
/// 一开始写的是 1：ECAPA 每句话只跑一次，不想长期占核。但实测手机上
/// 3 秒音频单线程要 120ms，放开到 4 路之后才能压到 100ms 以内。推理
/// 只持续几十毫秒，而且发生在 VAD 刚关句、上传还没开始的时候，多占
/// 这几个核不会影响录音。
const INFER_THREADS: usize = 4;

pub struct EcapaVerifier {
    session: Session,
    input: String,
    output: String,
    /// 已 L2 归一化的注册声纹。
    enrolled: Vec<f32>,
}

impl EcapaVerifier {
    /// `model` 是 `ecapa.onnx` 的字节，`spkemb` 是 192 维 f32。
    pub fn new(model: &[u8], spkemb: &[f32]) -> Result<Self, String> {
        let session = Session::builder()
            .map_err(|e| format!("ORT builder: {e}"))?
            .with_intra_threads(INFER_THREADS)
            .map_err(|e| format!("ORT 线程数: {e}"))?
            .commit_from_memory(model)
            .map_err(|e| format!("加载 ecapa.onnx: {e}"))?;

        let inputs: Vec<String> = session
            .inputs()
            .iter()
            .map(|i| i.name().to_string())
            .collect();
        let outputs: Vec<String> = session
            .outputs()
            .iter()
            .map(|o| o.name().to_string())
            .collect();
        if !inputs.iter().any(|n| n == "wav") {
            return Err(format!("ecapa.onnx 缺输入 wav，实际 {inputs:?}"));
        }
        if !outputs.iter().any(|n| n == "emb") {
            return Err(format!("ecapa.onnx 缺输出 emb，实际 {outputs:?}"));
        }

        let mut verifier = Self {
            session,
            input: "wav".to_string(),
            output: "emb".to_string(),
            enrolled: Vec::new(),
        };
        verifier.set_enrolled(spkemb)?;
        Ok(verifier)
    }

    /// 换注册声纹（已经加载的 session 复用）。
    pub fn set_enrolled(&mut self, spkemb: &[f32]) -> Result<(), String> {
        if spkemb.len() != EMB_DIM {
            return Err(format!(
                "声纹维度不对：期望 {EMB_DIM}，实际 {}",
                spkemb.len()
            ));
        }
        let norm = spkemb.iter().map(|v| v * v).sum::<f32>().sqrt();
        if !norm.is_finite() || norm <= 1e-6 {
            return Err("声纹向量是零向量或含非法值".to_string());
        }
        self.enrolled = spkemb.iter().map(|v| v / norm).collect();
        Ok(())
    }

    /// 算一段语音的 192 维 embedding（已 L2 归一化）。
    pub fn embed(&mut self, samples: &[f32]) -> Result<Vec<f32>, String> {
        let n = samples.len().min(MAX_VERIFY_SAMPLES);
        if n < 400 {
            return Err("音频太短，算不出声纹".to_string());
        }
        let tensor = Tensor::from_array(([1usize, n], samples[..n].to_vec()))
            .map_err(|e| format!("wav: {e}"))?;

        let outputs = self
            .session
            .run(ort::inputs![self.input.clone() => tensor])
            .map_err(|e| format!("ecapa 推理: {e}"))?;
        let (_, emb) = outputs[self.output.as_str()]
            .try_extract_tensor::<f32>()
            .map_err(|e| format!("emb: {e}"))?;
        if emb.len() != EMB_DIM {
            return Err(format!(
                "ecapa 输出维度不对：期望 {EMB_DIM}，实际 {}",
                emb.len()
            ));
        }
        if emb.iter().any(|v| !v.is_finite()) {
            return Err("ecapa 输出里有 NaN 或无穷大".to_string());
        }
        let norm = emb
            .iter()
            .map(|v| (*v as f64) * (*v as f64))
            .sum::<f64>()
            .sqrt();
        if norm <= 1e-8 {
            return Err("ecapa 输出是零向量".to_string());
        }
        Ok(emb.iter().map(|v| (*v as f64 / norm) as f32).collect())
    }

    /// 算这段语音和注册声纹的 cosine。返回 -1 表示无法判定（太短）。
    pub fn cosine(&mut self, samples: &[f32]) -> Result<f32, String> {
        if samples.len() < 400 {
            return Ok(-1.0);
        }
        let emb = self.embed(samples)?;
        Ok(emb
            .iter()
            .zip(self.enrolled.iter())
            .map(|(a, b)| *a as f64 * *b as f64)
            .sum::<f64>() as f32)
    }
}

impl crate::pvad::SpeakerVerifier for EcapaVerifier {
    fn cosine(&mut self, samples: &[f32]) -> Result<f32, String> {
        EcapaVerifier::cosine(self, samples)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn model_bytes() -> Vec<u8> {
        // 宿主上跑测试才需要；Android 包里的模型由 Dart 传入。
        std::fs::read(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../assets/models/ecapa.onnx"
        ))
        .expect("读取 assets/models/ecapa.onnx")
    }

    fn voice(freq: f32, mod_hz: f32, seconds: f32, seed: u32) -> Vec<f32> {
        let n = (seconds * 16_000.0) as usize;
        let mut state = seed;
        (0..n)
            .map(|i| {
                state = state.wrapping_mul(1_103_515_245).wrapping_add(12_345);
                let noise = ((state >> 16) & 0x7fff) as f32 / 32768.0 - 0.5;
                let t = i as f32 / 16_000.0;
                let f = freq * (1.0 + 0.02 * (2.0 * std::f32::consts::PI * mod_hz * t).sin());
                0.3 * (2.0 * std::f32::consts::PI * f * t).sin()
                    + 0.1 * (2.0 * std::f32::consts::PI * f * 2.0 * t).sin()
                    + 0.01 * noise
            })
            .collect()
    }

    #[test]
    fn rejects_zero_and_wrong_dimension_embeddings() {
        let model = model_bytes();
        assert!(EcapaVerifier::new(&model, &[0.0; EMB_DIM]).is_err());
        assert!(EcapaVerifier::new(&model, &[0.1; 10]).is_err());
    }

    #[test]
    fn real_ecapa_model_scores_same_voice_higher_than_other() {
        let model = model_bytes();
        let mut v = EcapaVerifier::new(&model, &[1.0; EMB_DIM]).expect("加载模型");

        let a = voice(150.0, 3.0, 2.0, 7);
        let a2 = voice(155.0, 3.2, 2.0, 9);
        let b = voice(420.0, 1.0, 2.0, 11);

        let emb_a = v.embed(&a).expect("embed a");
        assert_eq!(emb_a.len(), EMB_DIM);
        let norm: f32 = emb_a.iter().map(|x| x * x).sum::<f32>().sqrt();
        assert!((norm - 1.0).abs() < 1e-4, "embedding 应已归一化，norm={norm}");

        v.set_enrolled(&emb_a).expect("set enrolled");
        let same = v.cosine(&a2).expect("cos a2");
        let other = v.cosine(&b).expect("cos b");
        assert!(same.is_finite() && other.is_finite());
        assert!(
            same > other,
            "同一音色的 cosine ({same}) 应高于不同音色 ({other})"
        );
        assert!(same > 0.5, "同一音色的 cosine 应明显偏高，实际 {same}");
    }
}

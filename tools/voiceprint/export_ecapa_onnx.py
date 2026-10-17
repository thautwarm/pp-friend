#!/usr/bin/env python3
"""把 FireRedChat pVAD 用的 ECAPA-TDNN 声纹模型导出成单文件 ONNX。

用法（一定要用本目录的 venv）：

    tools/voiceprint/.venv/bin/python tools/voiceprint/export_ecapa_onnx.py

产物默认写到 ``tools/voiceprint/models/ecapa.onnx``，约 84 MB，不入库。

为什么不能直接 torch.onnx.export 原模型：

* speechbrain 的 Fbank 前端走 ``torch.stft(return_complex=True)``，PyTorch 2.14
  的 legacy ONNX 导出器在 opset 17 下对 complex 类型直接报错
  ("STFT does not currently support complex types")；
* 新版 dynamo 导出器（torch.export）在这个环境里连一个普通 Linear 都无法保留
  动态 batch 轴（会把 batch 特化成一个常量）。

所以这里只替换了两个**在满长度输入下数学等价**的实现，其余权重、卷积、
池化全部来自原始 checkpoint：

1. ``ExportSTFT``：用 identity Conv1d 分帧 + 余弦/正弦 DFT 矩阵做实数 FFT，
   严格复刻 SpeechBrain STFT 的 center padding、Hamming 窗、帧移和输出布局；
2. 满长度 ASP：AttentiveStatisticsPooling 在 ``lengths=None`` 时会用
   ``torch.ones(batch)`` 造 mask，这个 batch 会被 trace 成常量。这里改成
   ``torch.ones_like(x[:, :1, :])``，对满长度输入 mask 恒为全 1，结果不变。

输入/输出契约（导出后会打印并校验）：

    wav : float32 [B, T]   T = 采样点数 @ 16 kHz，建议 8000 <= T
    emb : float32 [B, 192] **未归一化**的 ECAPA embedding

页面在平均多窗结果后会做 L2 归一化；Rust 侧 pVAD 也会防御性再归一化一次。
"""

from __future__ import annotations

import argparse
import math
import sys
import types
import warnings
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

HERE = Path(__file__).resolve().parent
DEFAULT_MODEL_DIR = HERE / "models" / "spkrec-ecapa-voxceleb"
DEFAULT_OUT = HERE / "models" / "ecapa.onnx"


# ---------------------------------------------------------------------------
# 可导出的 STFT：与 SpeechBrain STFT 输出一致，但只用 Conv/MatMul 等基础算子
# ---------------------------------------------------------------------------
class ExportSTFT(nn.Module):
    """等价于 speechbrain.processing.features.STFT（Fbank 的默认参数）。

    torch.stft(center=True, pad_mode="constant") 等价于：
      1. 左右各 pad n_fft//2 个 0；
      2. 以 hop_length 分帧，每帧乘 Hamming 窗；
      3. 对每帧做 n_fft 点实数 DFT，输出 [B, frames, n_fft//2+1, 2]。
    """

    def __init__(
        self,
        sample_rate: int = 16000,
        win_length: float = 25,
        hop_length: float = 10,
        n_fft: int = 400,
    ) -> None:
        super().__init__()
        self.win_length = int(round(sample_rate / 1000.0 * win_length))
        self.hop_length = int(round(sample_rate / 1000.0 * hop_length))
        self.n_fft = n_fft
        # SpeechBrain 用的是 torch.hamming_window(win_length)（periodic=True）。
        self.register_buffer("window", torch.hamming_window(self.win_length))

        # 实数 DFT 的 cos/sin 基矩阵：[n_fft, n_fft//2+1]。
        n = torch.arange(n_fft, dtype=torch.float64)
        k = torch.arange(n_fft // 2 + 1, dtype=torch.float64)
        angle = 2.0 * math.pi * n[:, None] * k[None, :] / n_fft
        self.register_buffer("cos_mat", angle.cos().float())
        self.register_buffer("sin_mat", angle.sin().float())

        # 用 identity 卷积做分帧，避免 as_strided/unfold 在 ONNX 里的兼容问题。
        self.register_buffer("eye", torch.eye(n_fft).reshape(n_fft, 1, n_fft))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # x: [B, T]
        pad = self.n_fft // 2
        x = F.pad(x, (pad, pad))
        # [B, n_fft, frames] -> [B, frames, n_fft]
        frames = F.conv1d(x.unsqueeze(1), self.eye, stride=self.hop_length)
        frames = frames.transpose(1, 2) * self.window
        real = frames @ self.cos_mat
        imag = -(frames @ self.sin_mat)
        return torch.stack([real, imag], dim=-1)  # [B, frames, 201, 2]


# ---------------------------------------------------------------------------
# 满长度版 AttentiveStatisticsPooling
# ---------------------------------------------------------------------------
def _asp_forward_full_length(self, x: torch.Tensor, lengths=None) -> torch.Tensor:
    """AttentiveStatisticsPooling.forward 的满长度版本。

    原实现里 ``lengths=None`` -> ``torch.ones(x.shape[0])`` -> ``length_to_mask``，
    其中的 batch 大小会在 tracing 时固化。这里用 ``x`` 自身派生的全 1 mask，
    保证动态 batch 正确。输入始终是满长度窗口时，两者逐元素相同。
    """
    length = x.shape[-1]
    # [B, 1, L]，bool；shape 来自输入，不会被 trace 成常量。
    mask = torch.ones_like(x[:, :1, :], dtype=torch.bool)

    def _compute_statistics(x, m, dim=2, eps=self.eps):
        mean = (m * x).sum(dim)
        std = torch.sqrt((m * (x - mean.unsqueeze(dim)).pow(2)).sum(dim).clamp(eps))
        return mean, std

    # Expand the temporal context (global_context=True in this checkpoint).
    if self.global_context:
        total = mask.sum(dim=2, keepdim=True).float()
        mean, std = _compute_statistics(x, mask / total)
        mean = mean.unsqueeze(2).repeat(1, 1, length)
        std = std.unsqueeze(2).repeat(1, 1, length)
        attn = torch.cat([x, mean, std], dim=1)
    else:
        attn = x

    attn = self.conv(self.tanh(self.tdnn(attn)))
    attn = attn.masked_fill(mask == 0, float("-inf"))
    attn = F.softmax(attn, dim=2)
    mean, std = _compute_statistics(x, attn)
    return torch.cat((mean, std), dim=1).unsqueeze(2)


class ECAPAEncoder(nn.Module):
    """wav [B, T] float32 -> emb [B, 192] float32（未归一化）。

    等价于 EncoderClassifier.encode_batch(wavs)[:, 0, :]：
      Fbank(80) -> 句级均值归一化（std_norm=False）-> ECAPA_TDNN。
    """

    def __init__(self, classifier) -> None:
        super().__init__()
        self.compute_features = classifier.mods.compute_features
        self.embedding_model = classifier.mods.embedding_model

    def forward(self, wav: torch.Tensor) -> torch.Tensor:
        wav = wav.float()
        feats = self.compute_features(wav)
        # 等价于 InputNormalization(norm_type="sentence", std_norm=False)
        # 在满长度输入下的行为：每个 utterance 减掉自己所有帧的均值。
        feats = feats - feats.mean(dim=1, keepdim=True)
        emb = self.embedding_model(feats, None)
        return emb.squeeze(1)


def load_classifier(model_dir: Path):
    from speechbrain.inference.classifiers import EncoderClassifier

    # hyperparams.yaml 里 pretrained_path 是 "./"；给绝对路径，保证不依赖 cwd。
    return EncoderClassifier.from_hparams(
        source=str(model_dir),
        hparams_file="hyperparams.yaml",
        overrides={"pretrained_path": str(model_dir)},
        run_opts={"device": "cpu"},
    )


# ---------------------------------------------------------------------------
# 验证信号
# ---------------------------------------------------------------------------
def speech_like(seconds: float, seed: int, sr: int = 16000) -> np.ndarray:
    """合成一段类语音信号：谐波堆 + 基频起伏 + 音节包络 + 少量噪声。"""
    rng = np.random.default_rng(seed)
    n = int(round(seconds * sr))
    t = np.arange(n, dtype=np.float64) / sr
    f0 = 115.0 + 22.0 * np.sin(2 * np.pi * 0.9 * t) + 6.0 * np.sin(2 * np.pi * 3.7 * t)
    phase = 2 * np.pi * np.cumsum(f0) / sr
    sig = np.zeros(n, dtype=np.float64)
    for k in range(1, 31):
        sig += (1.0 / k) * np.sin(k * phase + rng.uniform(0, 2 * np.pi))
    env = 0.5 + 0.5 * np.sin(2 * np.pi * 3.2 * t - np.pi / 2)
    sig *= np.clip(env, 0.0, 1.0) ** 0.25
    sig += 0.01 * rng.standard_normal(n)
    sig = 0.35 * sig / max(1e-9, np.max(np.abs(sig)))
    return sig.astype(np.float32)


def make_cases(extra_wavs: list[Path]) -> list[tuple[str, np.ndarray]]:
    rng = np.random.default_rng(20261018)
    cases: list[tuple[str, np.ndarray]] = [
        ("silence 1.0s", np.zeros(16000, dtype=np.float32)),
        ("random noise 1.0s", (0.05 * rng.standard_normal(16000)).astype(np.float32)),
        ("speech-like 3.0s", speech_like(3.0, 1)),
        ("speech-like 1.0s", speech_like(1.0, 2)),
        ("speech-like 0.5s", speech_like(0.5, 3)),
        ("speech-like 10.0s", speech_like(10.0, 4)),
    ]
    for path in extra_wavs:
        import soundfile as sf
        import torchaudio

        data, sr = sf.read(str(path), dtype="float32", always_2d=True)
        # [frames, channels] -> [channels, frames]，多声道下混，再重采样到 16 kHz。
        mono = torch.from_numpy(data).T.mean(dim=0, keepdim=True)
        if sr != 16000:
            mono = torchaudio.functional.resample(mono, sr, 16000)
        wav = mono[0]
        cases.append((f"file {path.name} ({wav.shape[0] / 16000:.2f}s)", wav.numpy()))
    return cases


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    a = a.astype(np.float64).ravel()
    b = b.astype(np.float64).ravel()
    denom = np.linalg.norm(a) * np.linalg.norm(b)
    if denom == 0:
        return float("nan")
    return float(np.dot(a, b) / denom)


def validate(onnx_path: Path, model_dir: Path, extra_wavs: list[Path]) -> bool:
    import onnx
    import onnxruntime as ort

    print("\n== 检查 ONNX 文件 ==")
    model = onnx.load(str(onnx_path))
    onnx.checker.check_model(model)
    opsets = [(o.domain or "ai.onnx", o.version) for o in model.opset_import]
    print(f"opset      : {opsets}")
    print(f"ir_version : {model.ir_version}")
    print(f"size       : {onnx_path.stat().st_size / 1024 / 1024:.2f} MiB")
    for kind, items in (("input", model.graph.input), ("output", model.graph.output)):
        for item in items:
            t = item.type.tensor_type
            dims = [d.dim_param if d.dim_param else d.dim_value for d in t.shape.dim]
            print(f"{kind:6s}     : {item.name} {t.elem_type} {dims}")
    if not (len(model.graph.input) == 1 and model.graph.input[0].name == "wav"):
        print("!! 输入不是单个 wav", file=sys.stderr)
        return False
    if not (len(model.graph.output) == 1 and model.graph.output[0].name == "emb"):
        print("!! 输出不是单个 emb", file=sys.stderr)
        return False

    sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    print("\n== 与 SpeechBrain 原模型逐条对比 ==")
    print(f"{'case':32s} {'cos':>12s} {'1-cos':>10s} {'max|diff|':>12s} {'mean|diff|':>12s}")

    # 原模型单独加载一份，确保参考路径没有被上面的等价替换改动。
    ref = load_classifier(model_dir)
    ref.eval()

    all_ok = True
    for name, wav in make_cases(extra_wavs):
        x = torch.from_numpy(np.asarray(wav, dtype=np.float32)).unsqueeze(0)
        with torch.no_grad():
            ref_emb = ref.encode_batch(x).squeeze(1).numpy()
        onnx_emb = sess.run(None, {"wav": x.numpy()})[0]

        c = cosine(ref_emb, onnx_emb)
        max_diff = float(np.max(np.abs(ref_emb.astype(np.float64) - onnx_emb)))
        mean_diff = float(np.mean(np.abs(ref_emb.astype(np.float64) - onnx_emb)))
        ok = c > 0.9999
        all_ok &= ok
        print(f"{name:32s} {c:12.9f} {1.0 - c:10.2e} {max_diff:12.3e} {mean_diff:12.3e} {'' if ok else '  <-- FAIL'}")

    # 动态 batch：两段不同长度不行（ONNX 输入是矩形张量），所以用同长度两段。
    print("\n== 动态 batch 检查 ==")
    b1 = speech_like(1.5, 11)
    b2 = speech_like(1.5, 12)
    batch = np.stack([b1, b2]).astype(np.float32)
    batch_out = sess.run(None, {"wav": batch})[0]
    single1 = sess.run(None, {"wav": b1[None]})[0][0]
    single2 = sess.run(None, {"wav": b2[None]})[0][0]
    c1 = cosine(batch_out[0], single1)
    c2 = cosine(batch_out[1], single2)
    print(f"batch[0] vs single: cos={c1:.9f}  batch[1] vs single: cos={c2:.9f}")
    all_ok &= c1 > 0.99999 and c2 > 0.99999

    # 不同长度一致性：同一条语音裁到 1s / 3s，ONNX 与 torch 的 cos 都要过线。
    print("\n== 不同长度（1.0s / 3.0s）一致性 ==")
    long_wav = speech_like(3.0, 21)
    for seconds in (1.0, 3.0):
        wav = long_wav[: int(seconds * 16000)]
        x = torch.from_numpy(wav).unsqueeze(0)
        with torch.no_grad():
            r = ref.encode_batch(x).squeeze(1).numpy()
        o = sess.run(None, {"wav": x.numpy()})[0]
        c = cosine(r, o)
        ok = c > 0.9999
        all_ok &= ok
        print(f"{seconds:.1f}s: cos={c:.9f}  max|diff|={np.max(np.abs(r-o)):.3e}  {'OK' if ok else 'FAIL'}")

    print(f"\n结论: {'全部通过 (cos > 0.9999)' if all_ok else '有检查未通过'}")
    return all_ok


def main() -> int:
    parser = argparse.ArgumentParser(description="Export the pVAD ECAPA-TDNN speaker encoder to ONNX")
    parser.add_argument("--model-dir", type=Path, default=DEFAULT_MODEL_DIR,
                        help="SpeechBrain 模型目录（含 hyperparams.yaml 和 4 个 .ckpt）")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="输出 ONNX 路径")
    parser.add_argument("--wav", type=Path, action="append", default=[],
                        help="额外的真实 WAV，可重复；用于验证")
    parser.add_argument("--skip-validation", action="store_true", help="只导出、不验证（不建议）")
    args = parser.parse_args()

    warnings.filterwarnings("ignore", category=torch.jit.TracerWarning)
    warnings.filterwarnings("ignore", category=UserWarning, module="torch.onnx")
    warnings.filterwarnings("ignore", category=DeprecationWarning,
                            message="You are using the legacy TorchScript-based ONNX export.*")

    model_dir = args.model_dir.resolve()
    out = args.out.resolve()
    needed = ["hyperparams.yaml", "embedding_model.ckpt", "mean_var_norm_emb.ckpt",
              "classifier.ckpt", "label_encoder.ckpt"]
    missing = [name for name in needed if not (model_dir / name).is_file()]
    if missing:
        print(f"模型目录缺少文件: {missing}", file=sys.stderr)
        return 2

    print(f"加载模型: {model_dir}")
    classifier = load_classifier(model_dir)
    classifier.eval()

    # 先在 Python 里留一份未打补丁的参考输出。
    probe = torch.from_numpy(speech_like(2.0, 7)).unsqueeze(0)
    with torch.no_grad():
        ref_probe = classifier.encode_batch(probe).squeeze(1)

    # 1) 替换 STFT 前端（数学等价）。
    classifier.mods.compute_features.compute_STFT = ExportSTFT(
        sample_rate=16000, win_length=25, hop_length=10, n_fft=400
    )
    # 2) 替换满长度 ASP（只去掉会固化 batch 的 mask 构造）。
    classifier.mods.embedding_model.asp.forward = types.MethodType(
        _asp_forward_full_length, classifier.mods.embedding_model.asp
    )

    wrapper = ECAPAEncoder(classifier).eval()
    with torch.no_grad():
        out_probe = wrapper(probe)
    probe_cos = F.cosine_similarity(ref_probe.flatten(), out_probe.flatten(), dim=0).item()
    probe_diff = (ref_probe - out_probe).abs().max().item()
    print(f"wrapper vs encode_batch: cos={probe_cos:.8f} max|diff|={probe_diff:.3e}")
    if probe_cos <= 0.99999:
        print("!! wrapper 与 encode_batch 不一致，停止导出", file=sys.stderr)
        return 3

    out.parent.mkdir(parents=True, exist_ok=True)
    example = torch.from_numpy(speech_like(3.0, 1)).unsqueeze(0)
    print(f"导出 ONNX (opset 17, dynamic B/T): {out}")
    with torch.no_grad():
        torch.onnx.export(
            wrapper,
            (example,),
            str(out),
            input_names=["wav"],
            output_names=["emb"],
            opset_version=17,
            dynamo=False,
            do_constant_folding=True,
            dynamic_axes={"wav": {0: "B", 1: "T"}, "emb": {0: "B"}},
        )
    print(f"写出完成: {out.stat().st_size / 1024 / 1024:.2f} MiB")

    if args.skip_validation:
        print("已跳过验证。")
        return 0
    return 0 if validate(out, model_dir, args.wav) else 1


if __name__ == "__main__":
    raise SystemExit(main())

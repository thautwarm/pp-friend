#!/usr/bin/env python3
"""把导出的 ECAPA ONNX 量化成 int8，用于手机内置。

用法（一定要用本目录的 venv）：

    tools/voiceprint/.venv/bin/python tools/voiceprint/quantize_ecapa_int8.py \
        --calib-dir /tmp/ecapa_calib

校准音频要求：16 kHz、单声道、PCM16 的 wav，几段正常说话就行。macOS 上
可以直接用 `say` 生成，见 README。

做了什么：

1. 把图末尾的 `If` 换成 `Squeeze(axis=1)`。那个 If 是根据 batch 大小
   选 Squeeze 还是 Identity，ORT 的静态量化会在它和外部作用域的边之间
   插入 Q/DQ，生成出来的模型加载时报 "Argument type mismatch"。
   App 永远只喂 batch=1，Squeeze 就是 then 分支，输出仍是 [1, 192]。
2. 只量化 `embedding_model` 下的 Conv/MatMul，**不量化 Fbank/STFT 前端**。
   前端是频谱计算，量化后动态范围压不住，实测会出现 NaN。
3. 静态 QDQ + per-channel + reduce_range。校准集要覆盖 0.3/0.6/1.5/3 秒
   和几个增益，否则真实音量下的激活值容易越界。

实测（Apple Silicon，ORT CPU EP）：

    fp32  84.8MB   0.3s 10.2ms   3s 37.3ms
    int8  23.1MB   0.3s  2.9ms   3s 17.6ms
    同一段音频 embedding 的 cosine：min 0.986 / mean 0.992
    用 fp32 声纹注册、int8 探针比对，同人 cosine 平均只差 -0.006

所以注册用的 fp32 模型不用换，旧声纹继续有效。
"""

from __future__ import annotations

import argparse
import glob
import os
import wave
from pathlib import Path

import numpy as np
import onnx
from onnxruntime.quantization import (
    CalibrationDataReader,
    QuantFormat,
    QuantType,
    quantize_static,
)

HERE = Path(__file__).resolve().parent
DEFAULT_MODEL = HERE / "models" / "ecapa.onnx"
DEFAULT_OUT = HERE / "models" / "ecapa-int8.onnx"


def load_wav(path: str) -> np.ndarray:
    with wave.open(path, "rb") as w:
        if w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise SystemExit(f"{path}: 需要 16-bit 单声道 wav")
        if w.getframerate() != 16000:
            raise SystemExit(f"{path}: 需要 16 kHz，实际 {w.getframerate()}")
        return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(
            np.float32
        ) / 32768.0


def replace_if_with_squeeze(model: onnx.ModelProto) -> onnx.ModelProto:
    """把图末尾的 If 换成等价的 Squeeze，让静态量化能生成可加载的模型。"""
    nodes = []
    replaced = False
    for node in model.graph.node:
        if node.op_type != "If":
            nodes.append(node)
            continue
        axes = onnx.helper.make_tensor("sq_axes", onnx.TensorProto.INT64, [1], [1])
        nodes.append(
            onnx.helper.make_node(
                "Constant",
                [],
                ["sq_axes_val"],
                value=axes,
                name="sq_axes_const",
            )
        )
        nodes.append(
            onnx.helper.make_node(
                "Squeeze",
                ["/embedding_model/Transpose_1_output_0", "sq_axes_val"],
                ["emb"],
                name="if_as_squeeze",
            )
        )
        replaced = True
    if not replaced:
        raise SystemExit("模型里没有找到 If 节点，导出脚本可能已经改过了")
    del model.graph.node[:]
    model.graph.node.extend(nodes)
    for node in model.graph.node:
        if not node.name:
            node.name = node.output[0]
    onnx.checker.check_model(model)
    return model


class Calibration(CalibrationDataReader):
    """一段音频切成几种长度、再乘几个增益，覆盖手机上的实际音量。"""

    def __init__(self, paths: list[str]) -> None:
        items: list[np.ndarray] = []
        for path in paths:
            x = load_wav(path)
            for n in (48000, 24000, 9600, 4800):
                if len(x) < n:
                    continue
                base = x[:n]
                for gain in (0.15, 0.5, 1.0, 2.0):
                    items.append(np.clip(base * gain, -1.0, 1.0))
        if not items:
            raise SystemExit("校准音频都短于 0.3 秒，没法用")
        # 静音和极低噪声：真实输入里经常出现
        rng = np.random.default_rng(7)
        items.append(np.zeros(48000, np.float32))
        items.append((rng.standard_normal(48000) * 0.001).astype(np.float32))
        print(f"校准样本：{len(items)} 段")
        self._it = iter([{"wav": x[None, :]} for x in items])

    def get_next(self):
        return next(self._it, None)


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    a = a.reshape(-1)
    b = b.reshape(-1)
    return float(
        a @ b / ((np.linalg.norm(a) + 1e-9) * (np.linalg.norm(b) + 1e-9))
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", type=Path, default=DEFAULT_MODEL)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument(
        "--calib-dir",
        type=Path,
        required=True,
        help="16 kHz 单声道 wav 目录，几段正常说话即可",
    )
    args = ap.parse_args()

    paths = sorted(glob.glob(str(args.calib_dir / "*.wav")))
    if not paths:
        raise SystemExit(f"{args.calib_dir} 里没有 wav")

    model = replace_if_with_squeeze(onnx.load(str(args.model)))
    exclude = [n.name for n in model.graph.node if "/compute_features/" in n.name]
    print(f"跳过前端节点：{len(exclude)} 个")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    quantize_static(
        model,
        str(args.out),
        Calibration(paths),
        quant_format=QuantFormat.QDQ,
        activation_type=QuantType.QInt8,
        weight_type=QuantType.QInt8,
        per_channel=True,
        reduce_range=True,
        op_types_to_quantize=["Conv", "MatMul"],
        nodes_to_exclude=exclude,
    )
    print(
        f"fp32 {os.path.getsize(args.model) / 1e6:.1f}MB -> "
        f"int8 {os.path.getsize(args.out) / 1e6:.1f}MB"
    )

    # 自检：输出形状必须还是 [1, 192]，embedding 不能跑偏。
    import onnxruntime as ort

    fp = ort.InferenceSession(str(args.model), providers=["CPUExecutionProvider"])
    q = ort.InferenceSession(str(args.out), providers=["CPUExecutionProvider"])
    scores = []
    for path in paths:
        x = load_wav(path)[:48000][None, :]
        a = fp.run(None, {"wav": x})[0]
        b = q.run(None, {"wav": x})[0]
        if b.shape != (1, 192):
            raise SystemExit(f"量化后输出形状不对：{b.shape}")
        scores.append(cosine(a, b))
    print(
        f"自检 cosine：min {min(scores):.4f} / "
        f"mean {sum(scores) / len(scores):.4f}"
    )


if __name__ == "__main__":
    main()

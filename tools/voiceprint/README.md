# 项目网站与声纹创建工具（ECAPA）

这个目录同时是项目的静态网站源码：根目录是产品主页（中 / 英 / 日），
`enroll/` 是声纹创建工具。为说话人门控创建目标说话人的声纹：浏览器里
解码音频、算 192 维 ECAPA-TDNN embedding，导出成 App 能直接读的
`spkemb.f32`。

**全部计算都在本机浏览器内完成，音频不会上传。**
onnxruntime-web 1.30.0 优先从 jsDelivr 加载（wasm 压缩后约 4 MiB），
失败就退回 `vendor/onnxruntime-web/dist/`（从 npm 包里取的
`ort.wasm.min.js` + `ort-wasm-simd-threaded.mjs/.wasm`）。localhost 下
先用本地，开发时不需要联网；file:// 下浏览器读不了同目录的 wasm，反过来
先走 CDN，模型用页面上的「选择模型文件」手动挑。22 MiB 的模型超过
jsDelivr 的 GitHub 通道上限，线上从页面同源（GitHub Pages）加载。

## 目录

```
tools/voiceprint/
├── export_ecapa_onnx.py          # 一次性导出 + 强制验证脚本
├── quantize_ecapa_int8.py        # 导出 int8，给 App 内置用
├── index.html                    # 产品主页（中 / 英 / 日）
├── brain-api/index.html          # Brain API 协议说明
├── enroll/index.html             # 声纹创建工具页
├── assets/
│   ├── i18n.js                   # 三语字典与切换逻辑
│   ├── main.js                   # 主页初始化
│   ├── site.css                  # 两页共享样式
│   └── voiceprint.js             # 创建工具逻辑（原单文件页拆出）
├── vendor/onnxruntime-web/dist/  # 本地 ORT 运行时（约 14 MiB，入库，CDN 的保底）
├── README.md
├── .gitignore                    # 忽略 .venv / *.ckpt / *.onnx / 音频
├── models/
│   ├── ecapa.onnx                # 导出产物，约 81 MiB，不入库（创建页用）
│   ├── ecapa-int8.onnx           # 量化产物，约 23 MiB，不入库（App 用）
│   └── spkrec-ecapa-voxceleb/    # 原始 SpeechBrain 模型，ckpt 不入库
│       ├── hyperparams.yaml
│       ├── embedding_model.ckpt
│       ├── mean_var_norm_emb.ckpt
│       ├── classifier.ckpt
│       ├── label_encoder.ckpt
│       ├── label_encoder.txt
│       ├── config.json
│       └── README.md
└── .venv/                        # 本地导出环境，不入库
```

## 模型来源

权重来自：

<https://huggingface.co/FireRedTeam/FireRedChat-pvad/tree/main/spkrec-ecapa-voxceleb>

这是 pVAD 训练时实际使用的 ECAPA-TDNN checkpoint（VoxCeleb 1+2，
7205 个说话人，Apache-2.0），**不是**从 `speechbrain/spkrec-ecapa-voxceleb`
另外找的替代品。下载 4 个 ckpt：

```bash
cd tools/voiceprint/models/spkrec-ecapa-voxceleb
BASE=https://huggingface.co/FireRedTeam/FireRedChat-pvad/resolve/main/spkrec-ecapa-voxceleb
for f in embedding_model.ckpt mean_var_norm_emb.ckpt classifier.ckpt label_encoder.ckpt; do
  curl -L -O "$BASE/$f"
done
```

体积：`embedding_model.ckpt` 83,316,686 B，`classifier.ckpt` 5,534,328 B，
`mean_var_norm_emb.ckpt` 1,921 B，`label_encoder.ckpt` 128,619 B。

> `hyperparams.yaml` 里 `pretrained_path` 是 `./`，所以脚本用
> `overrides={"pretrained_path": <绝对路径>}` 加载，不依赖当前工作目录。

## 导出 ONNX

用已经建好的 venv（Python 3.12，speechbrain 1.1.2、torch 2.14.1、
torchaudio 2.11.0、onnx 1.23.2、onnxruntime 1.24.4）：

```bash
cd tools/voiceprint
.venv/bin/python export_ecapa_onnx.py
# 产物: models/ecapa.onnx
```

额外用真实语音验证（可选）：

```bash
.venv/bin/python export_ecapa_onnx.py --wav /path/to/speech.wav
```

导出后脚本会自动做以下检查，任何一项失败都会返回非 0：

* `onnx.checker.check_model`；
* 输入/输出名字与形状；
* 与未改动的 SpeechBrain `EncoderClassifier.encode_batch` 逐条对比：
  silence、随机噪声、合成类语音（0.5 / 1 / 3 / 10 秒）、可选真实 WAV；
* 动态 batch（B=2 对比单条推理）；
* 不同长度（1.0 s 与 3.0 s）。

本机实测（`onnxruntime 1.24.4` CPU）：

| case | cosine | 1 − cos | max abs diff | mean abs diff |
|---|---:|---:|---:|---:|
| silence 1.0 s | 1.000000000 | 5.88e-12 | 3.815e-04 | 8.396e-05 |
| random noise 1.0 s | 1.000000000 | 1.46e-12 | 1.526e-04 | 3.538e-05 |
| speech-like 0.5 s | 1.000000000 | 3.04e-12 | 1.974e-04 | 5.494e-05 |
| speech-like 1.0 s | 1.000000000 | 2.52e-12 | 1.812e-04 | 3.864e-05 |
| speech-like 3.0 s | 1.000000000 | 2.48e-12 | 1.869e-04 | 4.170e-05 |
| speech-like 10.0 s | 1.000000000 | 4.15e-12 | 2.098e-04 | 5.429e-05 |
| VoxCeleb sample 4.20 s | 1.000000000 | 2.05e-12 | 1.259e-04 | 2.818e-05 |

动态 batch：两条 1.5 s 语音，`cos(batch[i], single[i]) = 1.000000000`。
不同长度：1.0 s cos 1.000000000，3.0 s cos 1.000000000。
（cosine 在 float64 下计算，打印到 9 位小数；差异来自 float32 与 STFT
实现顺序，远小于 0.9999 的门槛。）

### 为什么脚本替换了 STFT / ASP

原始 `encode_batch` 的前端是 SpeechBrain 自己的 Fbank（`torch.stft` +
三角 mel 滤波器 + log10），导出时遇到两个 PyTorch 2.14 的限制：

1. legacy 导出器在 opset 17 下不支持 `torch.stft(return_complex=True)`；
2. dynamo/`torch.export` 在这个环境里无法保留动态 batch（连普通 `Linear`
   都会把 batch 特化成常量）。

脚本的替换只涉及**满长度输入下数学等价**的实现：

* `ExportSTFT`：identity Conv1d 分帧 + 实数 DFT 矩阵，复刻 SpeechBrain
  STFT 的 `center=True`、constant padding、Hamming 窗、帧移和
  `[B, frames, 201, 2]` 布局；
* 满长度 ASP：把 `torch.ones(batch)` 的 mask 改成由输入形状派生的全 1
  mask，避免 batch 被 trace 成常量。

卷积、BatchNorm、SE-Res2Net、注意力池化、FC、全部权重和 mel 滤波器都
直接来自 checkpoint。验证结果证明与原始 `encode_batch` 在数值上一致。

导出参数：opset **17**、IR version 8、`dynamo=False`、单文件（无 external
data）。动态轴：输入 batch、time；输出 batch。

## ONNX 契约

```
输入  wav : float32 [B, T]
输出  emb : float32 [B, 192]      # 原始 embedding，未 L2 归一化
```

* **采样率 16 kHz、单声道。** 输入是原始波形（float32），不是 mel。
* `T` 是采样点数；模型图内包含完整前端：
  * 80 维 log-mel（25 ms 窗 / 10 ms hop / 400 点 FFT / Hamming）；
  * 句级均值归一化（`std_norm=False`，只在时间轴减均值）；
  * ECAPA-TDNN（1024×4 + 3072，attention pooling，192 维输出）。
* `B` 与 `T` 都是动态轴。`T` 建议至少 8000（0.5 秒）；导出实现要求
  `T >= 640`（40 ms）。长的 `T` 会线性增加耗时，页面固定按 3 秒切窗。
* **没有 `wav_lens` 输入。** 不要把不同长度的语音 zero-pad 成一个 batch：
  padding 会参与句级均值归一化和注意力池化。请逐条推理，或只把等长片段
  组成 batch。

## int8 量化（App 内置的那份）

本地开发时创建页用 fp32 模型；线上 gh-pages 为了体积用的是 int8 版
（22 MB）。打进 APK 的也是量化版：

```bash
# 校准音频：16 kHz 单声道 wav，几段正常说话即可
mkdir -p /tmp/ecapa_calib
say -v Tingting -o /tmp/a.aiff "今天天气不错，我们出去走走吧。"
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/a.aiff /tmp/ecapa_calib/a.wav

cd tools/voiceprint
.venv/bin/python quantize_ecapa_int8.py --calib-dir /tmp/ecapa_calib
# 产物: models/ecapa-int8.onnx，拷到 assets/models/ecapa.onnx
```

脚本会做两处必要的改写：把末尾按 batch 分支的 `If` 换成 `Squeeze`，
否则静态量化生成出来的模型 ORT 加载不了；跳过 Fbank/STFT 前端，
前端量化后会出现 NaN。实测：

| | 体积 | 0.3 s | 3 s | embedding cosine |
|---|---:|---:|---:|---:|
| fp32 | 84.8 MB | 10.2 ms | 37.3 ms | — |
| int8 | 23.1 MB | 2.9 ms | 17.6 ms | min 0.986 / mean 0.992 |

用 fp32 创建声纹、int8 探针比对，同人 cosine 平均只挪 -0.006，所以
旧声纹不用重新录。
* **`emb` 没有归一化**，L2 范数通常在 300–500。页面会先对多窗结果求平均，
  再做 L2 归一化后导出。Rust 侧 pVAD（`rust/src/pvad.rs`）读取文件后还会
  防御性再归一化一次，所以两种顺序都安全。
* 直接和 `EncoderClassifier.encode_batch(wav)[:, 0, :]` 对齐：页面里的
  平均/归一化是模型之外的后处理。

App 端的对应写法（Rust/ORT）：

```rust
let wav = Tensor::from_array(([1usize, n], samples))?; // f32, 16 kHz mono
let out = session.run(ort::inputs!["wav" => wav])?;
let emb = out["emb"].try_extract_tensor::<f32>()?;      // [1, 192]
```

## 运行页面

```bash
cd tools/voiceprint
python3 -m http.server 8000
# 主页：  http://localhost:8000/
# 创建页：http://localhost:8000/enroll/
```

主页和创建页共用 `assets/` 下的样式、脚本和 i18n 字典。站点的
`vendor/`、`models/` 都在这个目录的根下，创建页用 `../vendor/` 和
`../models/` 引用，所以整目录部署到 GitHub Pages 时可直接用。

`models/ecapa.onnx` 存在时页面自动加载。若直接用 `file://` 打开、或模型
不存在，页面会显示「选择模型文件」按钮；选 `models/ecapa.onnx` 即可，
仍然不会上传。

线上 gh-pages 部署的模型是 int8 版（22 MB，字节与 `models/ecapa-int8.onnx`
一致）；本地这份 fp32 模型（81 MiB）也能直接跑创建页。两者算出的声纹
cosine 平均差 0.006 左右，见下面的量化一节。

### 页面行为

* 支持拖放/选择 wav、mp3、m4a、ogg，或直接用麦克风录音。
* 用 `decodeAudioData` 解码：优先在 16 kHz 的 `OfflineAudioContext` 里解码，
  让浏览器原生重采样器一步到位；不支持时退回普通 `AudioContext` 解码，再用
  `OfflineAudioContext` 重采样。全程没有手写线性插值。多声道手动下混。
* 少于 0.5 秒拒绝；0.5–3 秒作为单个窗口；超过 3 秒按连续 3 秒切窗，最后
  不足 3 秒但 ≥0.5 秒的尾巴向前重叠成一个完整 3 秒窗。
* 每个窗口分别推理，原始 embedding 求平均，再 L2 归一化。
* 显示每个窗口与均值的 cosine，方便判断录音是否一致（最低 <0.8 会提示重录）。
* 显示归一化前 L2 范数、192 维热力条和数值表。
* 下载：
  * `spkemb.f32`：**768 字节**，192 个 little-endian float32，无文件头，
    已 L2 归一化；
  * `spkemb.json`：同样的 192 个值 + 范数、窗口范围、窗口 cosine、模型信息。

## 验证记录

* 导出脚本：全部 case `cos > 0.9999`；动态 batch/长度检查通过。
* ONNX 在 Python `onnxruntime` 1.24.4 下运行通过。
* 页面在 headless Chromium（Playwright）里做过端到端实测：
  * 自动加载 `models/ecapa.onnx` → 选择 4.2 s WAV → 2 个窗口 → 下载
    `spkemb.f32`（768 B）与 JSON；页面无 JS 错误；
  * 浏览器页面的最终 192 维向量与 Python（同一 ONNX + 同样切窗/平均/
    归一化）对比：`cos = 1.00000005`，`max|diff| = 3.9e-6`（16 kHz 输入）；
  * 44.1 kHz 输入经浏览器原生重采样后与 torchaudio 重采样的结果对比：
    `cos = 0.9973`（两边重采样滤波器不同，属预期差异）；
  * `file://` / fetch 失败路径：手动选择 ONNX 后照常推理；
  * 0.3 s 音频被拒绝；7 s 音频得到 3 个窗口（0–3、3–6、4–7）；
  * 麦克风路径用 Chromium 的 fake audio device 验证通过。
* 改为本地 vendor 之后的复测（headless Chromium）：页面只请求
  `index.html`、`ort.wasm.min.js`、`ort-wasm-simd-threaded.mjs/.wasm` 和
  `models/ecapa.onnx` 这 5 个本地文件，**没有任何外网请求**；2 秒合成语音
  得到 192 维向量，L2 范数 0.9999999986。
* 模型文件大小：84,815,814 B（80.89 MiB）。

## 风险与注意事项

* **opset 17、IR 8**：onnxruntime-web 1.30.0 已实测可加载；如果换更老的
  ORT-web，建议至少 1.18+。
* 模型约 81 MiB，首次加载需要下载/读取；`python -m http.server` 单线程
  也能跑，但下载期间不要关页面。
* 麦克风录音使用 `MediaRecorder`，Chrome/Edge 下是 WebM/Opus；页面用
  `decodeAudioData` 解码。若某个浏览器不支持 WebM/Opus，请改用文件上传。
* `getUserMedia` 需要安全上下文：`http://localhost` 可以，局域网 IP 的
  HTTP 页面不行（需要 HTTPS）。文件上传不受此限制。
* 浏览器内 float32 与 Python 端的差异在 1e-4 量级（见上表），对 cosine
  声纹匹配没有影响。
* 导出的 embedding 依赖 pVAD 训练时的同一套权重；**不要**换成 HF hub 上
  另一个 `speechbrain/spkrec-ecapa-voxceleb`，即使名字相同也可能不是同一份
  字节。

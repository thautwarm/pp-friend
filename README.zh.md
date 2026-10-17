# PP Friend

[English](README.md) · 中文 · [日本語](README.ja.md)

自托管的实时语音助手客户端。手机端只做两件事——**采音、放音**；识别、对话、合成全部交给服务端（代码里叫 **brain**）。

**PP 是 Push and Pull**：人和 agent 两边各自 push、各自 pull。手机把你的语音推给 brain，再长轮询取回它的回复；agent 把文本推进来，也把人的文本拉回去。四路通道一直开着，所以是异步协作——你还在说话，它也能开口。

> **Made with deepseek v4.1 flash and pp-friend itself.**
> 这个项目的开发过程本身就用 PP Friend 在跑：对着手机说话来驱动编码，需求、审查和修复一路靠语音说完。

---

## 它是什么

一个随时能对话的语音助手，跑在自己家里的 brain 上，数据不出自己的服务器。

- **全双工**：用户说话 AI 听，AI 说话用户听，两个方向同时开着
- **可打断**：AI 正在说的时候用户开口，立刻停掉它；被打断时会把「我哪一段没听到」报给 brain，而不是让 brain 以为它讲完了
- **后台不中断**：切到别的 App 或锁屏，对话继续（前台服务撑住录音）
- **本地断句**：Silero VAD 跑在手机上（Rust），只把成句的片段传上去，不是把连续音频整段推流
- **声纹门控**：用注册声纹和这一段语音算 ECAPA 余弦相似度，够长的句子低于阈值就整段丢掉——家人说话不上传，也不进 agent 的上下文
- **多个档案**：每个档案一套 brain 配置、一份独立历史，可以同时跑；但只有聚焦的那个会播声音，其余只记文字

## 项目主页与声纹注册

项目主页（产品介绍、架构、隐私说明，支持中文 / English / 日本語）：

**<https://thautwarm.github.io/pp-friend/>**

想自己写一个 brain，先看协议说明：

**<https://thautwarm.github.io/pp-friend/brain-api/>**

说话人识别需要一份本人的声纹。注册页：

**<https://thautwarm.github.io/pp-friend/enroll/>**

在浏览器里录一段话，下载 `spkemb.f32`，再回到 App 的
**设置 → 通用 → 说话人识别** 导入。录音和推理都在浏览器本地完成，
音频不上传。主页和注册页的源码都在 `tools/voiceprint`，App 里也有
「打开声纹录制页面」按钮。

## 架构

**手机端不持有对话上下文**——那是服务端的，换 brain 名字就是换一段对话。
手机端落盘的只是**用于展示的历史**，不进任何请求，删掉不影响对话。

| 层 | 技术 |
|---|---|
| UI / 业务 | Flutter（Dart 3.13） |
| 本地断句 | Rust + Silero VAD，flutter_rust_bridge 2.13 |
| 声纹门控 | Rust + ECAPA 声纹余弦（int8 ONNX，23 MB）；声纹由 `tools/voiceprint` 网页生成 |
| 音频引擎 | Android 原生（Kotlin）：AudioRecord / AudioTrack / AEC |
| 上行编码 | Ogg Opus 16 kHz（MediaCodec + MediaMuxer） |
| 下行解码 | Ogg Opus 24 kHz（MediaExtractor + MediaCodec）→ 重采样到 16 kHz |
| 与服务端通信 | HTTP + MessagePack，两条独立长轮询循环 |
| 历史落盘 | NDJSON，按 1 MB 分片，只增不删 |

只支持 **Android arm64**，minSdk 29。iOS 的 Dart 契约已就绪，原生侧没写。

## 构建

前提：Flutter 3.47 以上、Android NDK、Rust 工具链。

```bash
# 1. ONNX Runtime（Android 那份 .so 已入库，宿主跑 cargo test 才需要）
tools/fetch_onnxruntime.sh

# 2. 出包——新克隆不需要 NDK 就能构建，jniLibs 里的 .so 是入库的
flutter build apk --release

# 3. 只有改了 Rust 源码才需要重跑（产物要一起提交）
tools/build_rust_android.sh
```

## 端到端自测

仓库里带了一个**按协议手写实现的假 brain**，不依赖任何服务端就能把链路跑通：

```bash
tools/mock_brain.py
```

它自带一份手写的 MessagePack 实现，用来验证协议理解有没有跑偏。

## 目录

```
lib/            Dart 侧：配置、会话、存储、UI
rust/           本地断句（Silero VAD）、说话人门控（ECAPA）与 frb 绑定
android/        原生音频引擎、前台服务、通知
assets/         模型资产（ecapa.onnx，int8）
tools/          构建脚本、假 brain、声纹注册网页、图标生成
docs/           设计与协议文档
test/           单元测试
```

## 文档

| 文档 | 内容 |
|---|---|
| `docs/voice-assistant.md` | 需求与技术方案 |
| `docs/voice-engine.md` | 原生音频引擎与 AEC |
| `docs/brain-api.md` | 与 brain 的协议（端点、载荷、历史分页） |
| `docs/handoff.md` | 已定决策、审查结论、已知问题 |
| `docs/需求-闭麦与打断.md` | 闭麦与打断的语义 |
| `docs/屏幕输出约定.md` | 输出给 TTS 时的说话约定 |

## 许可

尚未确定。

/* PP Friend 站点 i18n：字典 + 切换逻辑。无依赖，纯静态。
 *
 * 用法：
 *   - 元素加 data-i18n="key"（textContent）或 data-i18n-html="key"（innerHTML，
 *     仅用于字典内自带的少量 <b>/<strong> 标记），属性用
 *     data-i18n-attr="title:key;aria-label:key2"。
 *   - 动态字符串用 PP_I18N.t(key, {name: value})，占位符写作 {name}。
 *   - 语言优先级：localStorage("pp-friend-lang") > navigator.language，默认 en。
 *   - 切换后触发 PP_I18N.onChange 回调，并更新 <html lang>。
 */
window.PP_I18N = (() => {
  "use strict";

  const LANGS = ["zh", "en", "ja"];
  const LANG_NAMES = { zh: "中文", en: "English", ja: "日本語" };
  const HTML_LANG = { zh: "zh-CN", en: "en", ja: "ja" };
  const STORE_KEY = "pp-friend-lang";

  const dict = {
    zh: {
      "meta.title.home": "PP Friend · 自托管的实时语音助手客户端",
      "meta.desc.home": "PP Friend 是自托管的实时语音助手客户端：手机只采音放音，识别、对话、合成都在你自己的服务端运行。",
      "meta.title.enroll": "声纹注册 · PP Friend",
      "meta.desc.enroll": "在浏览器本地为 PP Friend 注册声纹：录音或选择音频文件，计算 192 维 ECAPA 声纹并导出 spkemb.f32。音频不上传。",

      "nav.home": "主页",
      "nav.enroll": "声纹注册",
      "nav.github": "GitHub",
      "nav.lang": "语言",

      "h.hero.tag": "自托管的实时语音助手客户端。手机只做两件事：采音、放音；识别、对话、合成全部交给你自己的服务端（代码里叫 brain）。",
      "h.hero.made": "这个项目本身的开发就是用 PP Friend 跑的：对着手机说话来驱动编码，需求、审查和修复一路靠语音说完。",
      "h.hero.ctaEnroll": "打开声纹注册工具",
      "h.hero.ctaGithub": "GitHub 仓库",

      "h.feat.title": "主要能力",
      "h.feat.duplex.t": "全双工",
      "h.feat.duplex.d": "你说话它听，它说话你听，两个方向同时开着，不用轮流按键。",
      "h.feat.barge.t": "可打断",
      "h.feat.barge.d": "它正在说的时候你开口，本地断句确认连续 350 ms 人声后立刻停播，并把没听到的那段文字报给 brain，它不会以为自己讲完了。打断是独立开关，默认关闭。",
      "h.feat.bg.t": "后台不中断",
      "h.feat.bg.d": "前台服务撑住录音，切到别的 App 或锁屏，对话继续。",
      "h.feat.vad.t": "本地断句",
      "h.feat.vad.d": "Silero VAD 跑在手机上（Rust），按 512 采样（32 ms）一帧推进。只把成句的片段传上去，不是把连续音频整段推流。",
      "h.feat.vp.t": "声纹门控",
      "h.feat.vp.d": "ECAPA 声纹和这一段语音算余弦相似度，每段最多看开头 3 秒，低于阈值（默认 0.4）整段丢弃：家人的话不上传，也不进 agent 的上下文。",
      "h.feat.profiles.t": "多档案",
      "h.feat.profiles.d": "每个档案一套 brain 配置、一份独立历史，可以同时跑；只有聚焦的那个播声音，其余只记文字。想开一段新对话，换个 brain 名字就行。",

      "h.arch.title": "架构与数据流",
      "h.arch.lead": "手机端不持有对话上下文，上下文在服务端。手机落盘的只是用于展示的历史，不进任何请求，删掉不影响对话。",
      "h.arch.flow.mic": "麦克风",
      "h.arch.flow.engine": "音频引擎（Kotlin）采集 / AEC / Opus 编码",
      "h.arch.flow.gate": "断句与门控（Rust）Silero VAD + ECAPA",
      "h.arch.flow.brain": "brain（你的服务端）识别 / 对话 / 合成",
      "h.arch.flow.speaker": "扬声器",
      "h.arch.note": "上行 Ogg Opus 16 kHz，下行 Ogg Opus 24 kHz（解码后重采样到 16 kHz）。通信是 HTTP + MessagePack，两条独立的长轮询循环。",
      "h.arch.stackTitle": "技术栈",
      "h.arch.row1.k": "UI / 业务",
      "h.arch.row1.v": "Flutter（Dart 3.13）",
      "h.arch.row2.k": "本地断句",
      "h.arch.row2.v": "Rust + Silero VAD，flutter_rust_bridge 2.13",
      "h.arch.row3.k": "声纹门控",
      "h.arch.row3.v": "Rust + ECAPA（int8 ONNX，23 MB）；声纹由本站注册工具生成",
      "h.arch.row4.k": "音频引擎",
      "h.arch.row4.v": "Android 原生（Kotlin）：AudioRecord / AudioTrack / AEC",
      "h.arch.row5.k": "上行 / 下行",
      "h.arch.row5.v": "Ogg Opus 16 kHz 上行；Ogg Opus 24 kHz 下行，重采样到 16 kHz",
      "h.arch.row6.k": "与 brain 通信",
      "h.arch.row6.v": "HTTP + MessagePack，两条独立长轮询循环",
      "h.arch.row7.k": "历史落盘",
      "h.arch.row7.v": "NDJSON，按 1 MB 分片，只增不删，仅用于展示",
      "h.arch.row8.k": "平台",
      "h.arch.row8.v": "Android arm64，minSdk 29",

      "h.privacy.title": "隐私与自托管",
      "h.privacy.i1": "识别、对话、合成全部运行在你自己的服务端，音频不去第三方服务。",
      "h.privacy.i2": "声纹门控在手机本地完成：不够像本人的片段在上传之前就被丢弃。",
      "h.privacy.i3": "声纹注册在浏览器里完成，录音和推理都不出本机（见本站声纹注册工具）。",
      "h.privacy.i4": "对话上下文在服务端，由 brain_id（人起的名字）区分；客户端只保存展示用历史。",
      "h.privacy.i5": "客户端与服务端之间用一个可选的 Bearer token 鉴权；token 为空表示该部署未启用鉴权。",

      "h.quick.title": "快速开始",
      "h.quick.req": "前提：Flutter 3.47 以上、Android NDK、Rust 工具链。新克隆不需要 NDK 就能构建，jniLibs 里的 .so 已入库。",
      "h.quick.rust": "只有改了 Rust 源码才需要重跑 tools/build_rust_android.sh（产物要一起提交）。",
      "h.quick.mock": "没有 brain 也能端到端自测：仓库带了一个按协议手写实现的假 brain，内含一份独立的 MessagePack 实现，用来验证协议理解有没有跑偏。",

      "h.enroll.title": "声纹注册工具",
      "h.enroll.body": "说话人识别需要一份本人声纹。在浏览器里录一段话或选一个音频文件，算出 192 维声纹并下载 spkemb.f32（768 字节，float32），再到 App 的设置 → 通用 → 说话人识别里导入。录音和推理都在浏览器本地完成，音频不上传。",
      "h.enroll.button": "打开声纹注册工具",

      "h.footer.license": "PP Friend 是开源项目。许可证尚未确定，以仓库 README 为准。",
      "h.footer.docs": "设计、协议与交接文档见仓库的 docs/ 目录。",

      "vp.back": "← 返回主页",
      "vp.title": "声纹注册",
      "vp.sub": "录一段语音，或选择音频文件。",
      "vp.privacy": "纯前端计算：音频不离开浏览器，声纹只保存到本机，不上传任何数据。页面可以保存到本地运行。",
      "vp.model.loading": "模型加载中",
      "vp.model.ready": "就绪",
      "vp.model.failed": "加载失败",
      "vp.progress.wait": "等待模型",
      "vp.progress.connect": "连接模型",
      "vp.progress.download": "下载模型 {pct}%",
      "vp.progress.mib": "{mib} MiB",
      "vp.progress.parse": "解析模型",
      "vp.progress.load": "加载模型",
      "vp.progress.modelReady": "模型已就绪",
      "vp.progress.autoFail": "自动读取失败",
      "vp.progress.engine": "加载推理引擎",
      "vp.progress.engineFail": "引擎加载失败",
      "vp.pickModel": "选择模型文件",
      "vp.addVoice": "添加语音",
      "vp.audio.wait": "等待音频",
      "vp.audio.decoding": "解码中",
      "vp.audio.ready": "已就绪",
      "vp.audio.bad": "无法使用",
      "vp.audio.infer": "推理中",
      "vp.audio.done": "完成",
      "vp.audio.failed": "推理失败",
      "vp.drop.title": "选择音频文件",
      "vp.drop.hint": "拖放到这里 · wav / mp3 / m4a / ogg",
      "vp.mic.start": "开始录音",
      "vp.mic.stop": "停止录音",
      "vp.mic.recording": "录音中 {s} 秒",
      "vp.infer.prepare": "准备推理",
      "vp.infer.progress": "推理中 {i}/{n}",
      "vp.result": "声纹结果",
      "vp.result.done": "已完成",
      "vp.result.duration": "时长 <b>{s}</b>",
      "vp.audioInfo": "<b>{name}</b> · {s} · {n}",
      "vp.seconds": "{s} 秒",
      "vp.windows": "{n} 个窗口",
      "vp.metric.minCos": "最低 cos",
      "vp.metric.windows": "窗口数",
      "vp.showValues": "查看 192 维数值",
      "vp.strip.aria": "192 维声纹数值热力条",
      "vp.legend.neg": "负值",
      "vp.legend.pos": "正值",
      "vp.chip": "窗口 {i} · {cos}",
      "vp.chip.title": "该窗口与平均向量的余弦相似度",
      "vp.consistency.low": "<strong>!</strong> 一致性偏低（最低 {cos}），建议在安静环境下重录。",
      "vp.consistency.ok": "一致性正常（最低 {cos}）。",
      "vp.cell.aria": "维度 {i} 值 {v}",
      "vp.dl.f32": "导出 spkemb.f32",
      "vp.dl.json": "导出 spkemb.json",
      "vp.err.sep": "。",
      "vp.err.engineMissing": "推理引擎未加载，请通过本地 HTTP 服务打开页面",
      "vp.err.ioNames": "模型输入/输出不是 wav/emb，请确认模型文件",
      "vp.err.modelLoad": "模型加载失败：{detail}",
      "vp.err.hintFile": "点「选择模型文件」，选上级目录的 models/ecapa.onnx 即可",
      "vp.err.hintHttp": "请选择模型文件，或通过本地 HTTP 服务打开页面",
      "vp.err.audioShort": "音频太短，至少需要 0.5 秒",
      "vp.err.audioProcess": "音频处理失败：{detail}",
      "vp.err.decode": "浏览器无法解码这个文件，请换 wav / mp3 / m4a / ogg",
      "vp.err.audioEmpty": "音频是空的",
      "vp.err.noEmbedding": "没有得到有效声纹，请换一段清晰的语音",
      "vp.err.compute": "计算失败：{detail}",
      "vp.err.outputDim": "模型输出维度不是 192",
      "vp.err.noRecording": "没有录到音频",
      "vp.err.mic": "无法打开麦克风：{detail}。请检查权限，或选择音频文件",
      "vp.err.micUnsupported": "当前浏览器不支持录音，请选择音频文件",
      "vp.err.engineFail": "推理引擎加载失败，请检查网络后刷新页面",
      "vp.log.scriptTimeout": "脚本加载超时",
      "vp.log.scriptFail": "脚本下载失败",
      "vp.log.wasmUnreachable": "wasm 不可达",
      "vp.log.ortNotRegistered": "ort 没有注册",
      "vp.log.ortFail": "onnxruntime 加载失败（{src}）：{detail}",
      "vp.src.cdn": "CDN",
      "vp.src.local": "本地",
    },

    en: {
      "meta.title.home": "PP Friend · Self-hosted real-time voice assistant client",
      "meta.desc.home": "PP Friend is a self-hosted real-time voice assistant client: the phone only records and plays audio; recognition, dialogue, and synthesis run on your own server.",
      "meta.title.enroll": "Voiceprint enrollment · PP Friend",
      "meta.desc.enroll": "Enroll a voiceprint for PP Friend entirely in your browser: record or pick an audio file, compute a 192-dimensional ECAPA embedding, and export spkemb.f32. Audio is never uploaded.",

      "nav.home": "Home",
      "nav.enroll": "Voiceprint",
      "nav.github": "GitHub",
      "nav.lang": "Language",

      "h.hero.tag": "A self-hosted, real-time voice assistant client. The phone does two things: record and play audio. Recognition, dialogue, and synthesis all run on your own server (called the brain in the code).",
      "h.hero.made": "PP Friend was built with PP Friend itself: requirements, reviews, and fixes were dictated to the coding agent by voice, through the phone.",
      "h.hero.ctaEnroll": "Open the enrollment tool",
      "h.hero.ctaGithub": "GitHub repository",

      "h.feat.title": "What it does",
      "h.feat.duplex.t": "Full duplex",
      "h.feat.duplex.d": "It listens while you speak and you listen while it speaks. Both directions stay open; no push-to-talk.",
      "h.feat.barge.t": "Barge-in",
      "h.feat.barge.d": "Start talking while it is speaking and on-device endpointing confirms 350 ms of continuous speech, stops playback at once, and reports the part you missed back to the brain, so it does not assume it finished. Barge-in is a separate switch, off by default.",
      "h.feat.bg.t": "Runs in the background",
      "h.feat.bg.d": "A foreground service keeps the microphone alive. Switch apps or lock the screen; the conversation continues.",
      "h.feat.vad.t": "On-device endpointing",
      "h.feat.vad.d": "Silero VAD runs on the phone (Rust), advancing in 512-sample (32 ms) steps. Only complete utterances are uploaded, not a continuous audio stream.",
      "h.feat.vp.t": "Voiceprint gate",
      "h.feat.vp.d": "Each segment is compared with your enrolled ECAPA voiceprint by cosine similarity, looking at most at the first 3 seconds. Below the threshold (0.4 by default) the whole segment is dropped: family members' speech is never uploaded and never enters the agent's context.",
      "h.feat.profiles.t": "Multiple profiles",
      "h.feat.profiles.d": "Each profile has its own brain configuration and history, and several can run at once. Only the focused profile plays audio; the rest record text. To start a fresh conversation, use a new brain name.",

      "h.arch.title": "Architecture and data flow",
      "h.arch.lead": "The phone holds no conversational context; the context lives on the server. What the phone stores is display-only history: it is never sent in any request, and deleting it does not affect the conversation.",
      "h.arch.flow.mic": "Microphone",
      "h.arch.flow.engine": "Audio engine (Kotlin) capture / AEC / Opus encoding",
      "h.arch.flow.gate": "Endpointing and gate (Rust) Silero VAD + ECAPA",
      "h.arch.flow.brain": "brain (your server) recognition / dialogue / synthesis",
      "h.arch.flow.speaker": "Speaker",
      "h.arch.note": "Uplink is Ogg Opus at 16 kHz; downlink is Ogg Opus at 24 kHz, resampled to 16 kHz after decoding. Transport is HTTP + MessagePack over two independent long-polling loops.",
      "h.arch.stackTitle": "Stack",
      "h.arch.row1.k": "UI / app logic",
      "h.arch.row1.v": "Flutter (Dart 3.13)",
      "h.arch.row2.k": "Endpointing",
      "h.arch.row2.v": "Rust + Silero VAD, flutter_rust_bridge 2.13",
      "h.arch.row3.k": "Voiceprint gate",
      "h.arch.row3.v": "Rust + ECAPA (int8 ONNX, 23 MB); voiceprints come from the enrollment tool on this site",
      "h.arch.row4.k": "Audio engine",
      "h.arch.row4.v": "Native Android (Kotlin): AudioRecord / AudioTrack / AEC",
      "h.arch.row5.k": "Uplink / downlink",
      "h.arch.row5.v": "Ogg Opus 16 kHz up; Ogg Opus 24 kHz down, resampled to 16 kHz",
      "h.arch.row6.k": "Brain transport",
      "h.arch.row6.v": "HTTP + MessagePack, two independent long-polling loops",
      "h.arch.row7.k": "History storage",
      "h.arch.row7.v": "NDJSON, 1 MB shards, append-only, display only",
      "h.arch.row8.k": "Platform",
      "h.arch.row8.v": "Android arm64, minSdk 29",

      "h.privacy.title": "Privacy and self-hosting",
      "h.privacy.i1": "Recognition, dialogue, and synthesis all run on your own server. Audio never goes to a third-party service.",
      "h.privacy.i2": "The voiceprint gate runs on the phone: segments that do not match you are dropped before upload.",
      "h.privacy.i3": "Voiceprint enrollment runs in the browser; recording and inference never leave the machine (see the enrollment tool on this site).",
      "h.privacy.i4": "Conversational context lives on the server, keyed by a brain_id (a name you choose). The client only keeps display history.",
      "h.privacy.i5": "The client authenticates to the server with an optional Bearer token; an empty token means the deployment has no authentication.",

      "h.quick.title": "Getting started",
      "h.quick.req": "Prerequisites: Flutter 3.47+, Android NDK, and a Rust toolchain. A fresh clone builds without the NDK; the .so files in jniLibs are checked in.",
      "h.quick.rust": "Re-run tools/build_rust_android.sh only after changing Rust code, and commit the artifacts together.",
      "h.quick.mock": "You can test the whole chain without a real brain: the repo ships a mock brain implemented by hand against the protocol, including a standalone MessagePack implementation, to check that the protocol understanding has not drifted.",

      "h.enroll.title": "Voiceprint enrollment tool",
      "h.enroll.body": "Speaker gating needs an enrolled voiceprint. Record a clip or pick an audio file in the browser; the tool computes a 192-dimensional embedding and offers spkemb.f32 (768 bytes, float32) for download. Import it in the app under Settings → General → Speaker verification. Recording and inference stay in the browser; audio is never uploaded.",
      "h.enroll.button": "Open the enrollment tool",

      "h.footer.license": "PP Friend is an open-source project. The license is not decided yet; see the repository README.",
      "h.footer.docs": "Design, protocol, and handoff documents live in the docs/ directory of the repository.",

      "vp.back": "← Back to home",
      "vp.title": "Voiceprint enrollment",
      "vp.sub": "Record a clip, or choose an audio file.",
      "vp.privacy": "All computation happens in the browser: audio never leaves the browser, the voiceprint is saved only to your machine, and nothing is uploaded. The page can be saved and run locally.",
      "vp.model.loading": "Loading model",
      "vp.model.ready": "Ready",
      "vp.model.failed": "Failed to load",
      "vp.progress.wait": "Waiting for model",
      "vp.progress.connect": "Connecting to model",
      "vp.progress.download": "Downloading model {pct}%",
      "vp.progress.mib": "{mib} MiB",
      "vp.progress.parse": "Parsing model",
      "vp.progress.load": "Loading model",
      "vp.progress.modelReady": "Model ready",
      "vp.progress.autoFail": "Automatic load failed",
      "vp.progress.engine": "Loading inference engine",
      "vp.progress.engineFail": "Engine failed to load",
      "vp.pickModel": "Choose model file",
      "vp.addVoice": "Add audio",
      "vp.audio.wait": "Waiting for audio",
      "vp.audio.decoding": "Decoding",
      "vp.audio.ready": "Ready",
      "vp.audio.bad": "Unusable",
      "vp.audio.infer": "Running inference",
      "vp.audio.done": "Done",
      "vp.audio.failed": "Inference failed",
      "vp.drop.title": "Choose an audio file",
      "vp.drop.hint": "or drop it here · wav / mp3 / m4a / ogg",
      "vp.mic.start": "Start recording",
      "vp.mic.stop": "Stop recording",
      "vp.mic.recording": "Recording {s} s",
      "vp.infer.prepare": "Preparing inference",
      "vp.infer.progress": "Inference {i}/{n}",
      "vp.result": "Voiceprint result",
      "vp.result.done": "Done",
      "vp.result.duration": "Duration <b>{s}</b>",
      "vp.audioInfo": "<b>{name}</b> · {s} · {n}",
      "vp.seconds": "{s} s",
      "vp.windows": "{n} windows",
      "vp.metric.minCos": "Min cos",
      "vp.metric.windows": "Windows",
      "vp.showValues": "Show the 192 values",
      "vp.strip.aria": "Heat strip of the 192-dimensional voiceprint values",
      "vp.legend.neg": "Negative",
      "vp.legend.pos": "Positive",
      "vp.chip": "Window {i} · {cos}",
      "vp.chip.title": "Cosine similarity between this window and the mean vector",
      "vp.consistency.low": "<strong>!</strong> Low consistency (minimum {cos}). Consider re-recording in a quieter place.",
      "vp.consistency.ok": "Consistency looks fine (minimum {cos}).",
      "vp.cell.aria": "Dimension {i}, value {v}",
      "vp.dl.f32": "Export spkemb.f32",
      "vp.dl.json": "Export spkemb.json",
      "vp.err.sep": ". ",
      "vp.err.engineMissing": "The inference engine is not loaded; open the page through a local HTTP server",
      "vp.err.ioNames": "The model's input/output names are not wav/emb; check the model file",
      "vp.err.modelLoad": "Failed to load the model: {detail}",
      "vp.err.hintFile": "click \"Choose model file\" and select models/ecapa.onnx from the parent directory",
      "vp.err.hintHttp": "choose a model file manually, or open the page through a local HTTP server",
      "vp.err.audioShort": "Audio too short; at least 0.5 seconds is required",
      "vp.err.audioProcess": "Failed to process the audio: {detail}",
      "vp.err.decode": "The browser cannot decode this file; try wav / mp3 / m4a / ogg",
      "vp.err.audioEmpty": "The audio is empty",
      "vp.err.noEmbedding": "No valid voiceprint could be computed; try a clearer recording",
      "vp.err.compute": "Computation failed: {detail}",
      "vp.err.outputDim": "The model output is not 192-dimensional",
      "vp.err.noRecording": "No audio was recorded",
      "vp.err.mic": "Cannot open the microphone: {detail}. Check permissions, or choose an audio file",
      "vp.err.micUnsupported": "This browser does not support recording; choose an audio file instead",
      "vp.err.engineFail": "The inference engine failed to load; check your network and reload the page",
      "vp.log.scriptTimeout": "script load timed out",
      "vp.log.scriptFail": "script download failed",
      "vp.log.wasmUnreachable": "wasm unreachable",
      "vp.log.ortNotRegistered": "ort did not register",
      "vp.log.ortFail": "onnxruntime failed to load ({src}): {detail}",
      "vp.src.cdn": "CDN",
      "vp.src.local": "local",
    },

    ja: {
      "meta.title.home": "PP Friend · セルフホスト型リアルタイム音声アシスタント",
      "meta.desc.home": "PP Friend はセルフホスト型のリアルタイム音声アシスタントクライアントです。スマホは録音と再生だけを行い、認識・対話・合成はすべて自分のサーバーで動きます。",
      "meta.title.enroll": "声紋登録 · PP Friend",
      "meta.desc.enroll": "PP Friend の声紋をブラウザ内だけで登録します。録音または音声ファイルから 192 次元の ECAPA 声紋を計算し、spkemb.f32 を書き出します。音声はアップロードされません。",

      "nav.home": "ホーム",
      "nav.enroll": "声紋登録",
      "nav.github": "GitHub",
      "nav.lang": "言語",

      "h.hero.tag": "自分のサーバーで動く、リアルタイム音声アシスタントのクライアントです。スマホがやることは録音と再生の二つだけ。認識・対話・合成はすべて自分のサーバー（コード内では brain）が担当します。",
      "h.hero.made": "このプロジェクト自体の開発も PP Friend で回しています。スマホに向かって話すことでコーディングを駆動し、要件もレビューも修正も音声で進めました。",
      "h.hero.ctaEnroll": "声紋登録ツールを開く",
      "h.hero.ctaGithub": "GitHub リポジトリ",

      "h.feat.title": "主な機能",
      "h.feat.duplex.t": "全二重",
      "h.feat.duplex.d": "こちらが話している間も相手は聞き、相手が話している間もこちらは聞けます。双方向が同時に開いていて、ボタンの押し合いは不要です。",
      "h.feat.barge.t": "割り込み",
      "h.feat.barge.d": "相手の発話中に話し始めると、端末上の区間検出が 350 ms の連続した人声を確認した時点で再生を止め、聞き取れなかった部分のテキストを brain に報告します。相手が話し終えたと誤解することはありません。割り込みは独立したスイッチで、既定はオフです。",
      "h.feat.bg.t": "バックグラウンドで継続",
      "h.feat.bg.d": "フォアグラウンドサービスが録音を維持するので、別アプリへの切り替えや画面ロック中も会話が続きます。",
      "h.feat.vad.t": "端末上の区間検出",
      "h.feat.vad.d": "Silero VAD がスマホ上で動き（Rust）、512 サンプル（32 ms）単位で進行します。完成した文の区間だけを送信し、連続した音声をそのまま流すことはしません。",
      "h.feat.vp.t": "声紋ゲート",
      "h.feat.vp.d": "各区間について、登録済みの ECAPA 声紋とのコサイン類似度を計算します。先頭から最大 3 秒だけを見て、しきい値（既定 0.4）を下回れば区間ごと破棄します。家族の発話はアップロードされず、エージェントのコンテキストにも入りません。",
      "h.feat.profiles.t": "複数プロファイル",
      "h.feat.profiles.d": "プロファイルごとに brain の設定と独立した履歴を持ち、同時に動かせます。音声を再生するのはフォーカス中のプロファイルだけで、残りはテキストのみ記録します。新しい会話を始めたければ、brain の名前を変えるだけです。",

      "h.arch.title": "アーキテクチャとデータフロー",
      "h.arch.lead": "会話のコンテキストはスマホ側に持たず、サーバー側に置きます。スマホに保存されるのは表示用の履歴だけで、リクエストには含まれず、消しても会話には影響しません。",
      "h.arch.flow.mic": "マイク",
      "h.arch.flow.engine": "オーディオエンジン（Kotlin）収録 / AEC / Opus エンコード",
      "h.arch.flow.gate": "区間検出とゲート（Rust）Silero VAD + ECAPA",
      "h.arch.flow.brain": "brain（自分のサーバー）認識 / 対話 / 合成",
      "h.arch.flow.speaker": "スピーカー",
      "h.arch.note": "上りは 16 kHz の Ogg Opus、下りは 24 kHz の Ogg Opus（デコード後に 16 kHz へリサンプル）です。通信は HTTP + MessagePack で、独立した 2 本のロングポーリングループを使います。",
      "h.arch.stackTitle": "技術スタック",
      "h.arch.row1.k": "UI / アプリロジック",
      "h.arch.row1.v": "Flutter（Dart 3.13）",
      "h.arch.row2.k": "区間検出",
      "h.arch.row2.v": "Rust + Silero VAD、flutter_rust_bridge 2.13",
      "h.arch.row3.k": "声紋ゲート",
      "h.arch.row3.v": "Rust + ECAPA（int8 ONNX、23 MB）。声紋は本サイトの登録ツールで生成",
      "h.arch.row4.k": "オーディオエンジン",
      "h.arch.row4.v": "Android ネイティブ（Kotlin）：AudioRecord / AudioTrack / AEC",
      "h.arch.row5.k": "上り / 下り",
      "h.arch.row5.v": "上り Ogg Opus 16 kHz、下り Ogg Opus 24 kHz（16 kHz にリサンプル）",
      "h.arch.row6.k": "brain との通信",
      "h.arch.row6.v": "HTTP + MessagePack、独立した 2 本のロングポーリングループ",
      "h.arch.row7.k": "履歴の保存",
      "h.arch.row7.v": "NDJSON、1 MB ごとの分割、追記のみ、表示専用",
      "h.arch.row8.k": "プラットフォーム",
      "h.arch.row8.v": "Android arm64、minSdk 29",

      "h.privacy.title": "プライバシーとセルフホスト",
      "h.privacy.i1": "認識・対話・合成はすべて自分のサーバーで動き、音声が第三者のサービスに送られることはありません。",
      "h.privacy.i2": "声紋ゲートはスマホ上で完結します。本人らしくない区間はアップロード前に破棄されます。",
      "h.privacy.i3": "声紋の登録もブラウザ内で完結し、録音も推論も端末の外に出ません（本サイトの声紋登録ツールを参照）。",
      "h.privacy.i4": "会話のコンテキストはサーバー側にあり、brain_id（人が付ける名前）で区別します。クライアントが保存するのは表示用の履歴だけです。",
      "h.privacy.i5": "クライアントとサーバー間の認証は任意の Bearer トークンで、空ならそのデプロイは認証なしという意味です。",

      "h.quick.title": "はじめに",
      "h.quick.req": "前提：Flutter 3.47 以上、Android NDK、Rust ツールチェーン。新しくクローンした状態では NDK なしでビルドできます（jniLibs の .so はリポジトリに含まれています）。",
      "h.quick.rust": "tools/build_rust_android.sh を再実行するのは Rust のコードを変更したときだけです（生成物も一緒にコミットします）。",
      "h.quick.mock": "本物の brain がなくてもエンドツーエンドで確認できます。リポジトリにはプロトコルに沿って手書きで実装されたモック brain（独立した MessagePack 実装つき）が入っていて、プロトコルの解釈がずれていないかを確かめられます。",

      "h.enroll.title": "声紋登録ツール",
      "h.enroll.body": "話者ゲートには本人の声紋の登録が必要です。ブラウザで音声を録音するか音声ファイルを選ぶと、192 次元の声紋を計算して spkemb.f32（768 バイト、float32）をダウンロードできます。あとはアプリの 設定 → 一般 → 話者認識 でインポートするだけです。録音と推論はブラウザ内で完結し、音声はアップロードされません。",
      "h.enroll.button": "声紋登録ツールを開く",

      "h.footer.license": "PP Friend はオープンソースプロジェクトです。ライセンスは未定で、リポジトリの README を参照してください。",
      "h.footer.docs": "設計・プロトコル・引き継ぎの文書はリポジトリの docs/ にあります。",

      "vp.back": "← ホームに戻る",
      "vp.title": "声紋登録",
      "vp.sub": "音声を録音するか、音声ファイルを選んでください。",
      "vp.privacy": "計算はすべてブラウザ内で行われます。音声はブラウザの外に出ず、声紋はこの端末にのみ保存され、何もアップロードされません。ページは保存してローカルで実行できます。",
      "vp.model.loading": "モデルを読み込み中",
      "vp.model.ready": "準備完了",
      "vp.model.failed": "読み込み失敗",
      "vp.progress.wait": "モデル待ち",
      "vp.progress.connect": "モデルに接続中",
      "vp.progress.download": "モデルをダウンロード中 {pct}%",
      "vp.progress.mib": "{mib} MiB",
      "vp.progress.parse": "モデルを解析中",
      "vp.progress.load": "モデルを読み込み中",
      "vp.progress.modelReady": "モデルの準備ができました",
      "vp.progress.autoFail": "自動読み込みに失敗",
      "vp.progress.engine": "推論エンジンを読み込み中",
      "vp.progress.engineFail": "エンジンの読み込みに失敗",
      "vp.pickModel": "モデルファイルを選択",
      "vp.addVoice": "音声を追加",
      "vp.audio.wait": "音声待ち",
      "vp.audio.decoding": "デコード中",
      "vp.audio.ready": "準備完了",
      "vp.audio.bad": "使用できません",
      "vp.audio.infer": "推論中",
      "vp.audio.done": "完了",
      "vp.audio.failed": "推論失敗",
      "vp.drop.title": "音声ファイルを選択",
      "vp.drop.hint": "ここにドラッグ＆ドロップ · wav / mp3 / m4a / ogg",
      "vp.mic.start": "録音開始",
      "vp.mic.stop": "録音停止",
      "vp.mic.recording": "録音中 {s} 秒",
      "vp.infer.prepare": "推論を準備中",
      "vp.infer.progress": "推論中 {i}/{n}",
      "vp.result": "声紋の結果",
      "vp.result.done": "完了",
      "vp.result.duration": "長さ <b>{s}</b>",
      "vp.audioInfo": "<b>{name}</b> · {s} · {n}",
      "vp.seconds": "{s} 秒",
      "vp.windows": "{n} ウィンドウ",
      "vp.metric.minCos": "最小 cos",
      "vp.metric.windows": "ウィンドウ数",
      "vp.showValues": "192 次元の数値を表示",
      "vp.strip.aria": "192 次元声紋の値のヒートマップ",
      "vp.legend.neg": "負の値",
      "vp.legend.pos": "正の値",
      "vp.chip": "ウィンドウ {i} · {cos}",
      "vp.chip.title": "このウィンドウと平均ベクトルのコサイン類似度",
      "vp.consistency.low": "<strong>!</strong> 一貫性が低めです（最小 {cos}）。静かな環境で録り直すことをおすすめします。",
      "vp.consistency.ok": "一貫性は正常です（最小 {cos}）。",
      "vp.cell.aria": "次元 {i} の値 {v}",
      "vp.dl.f32": "spkemb.f32 をエクスポート",
      "vp.dl.json": "spkemb.json をエクスポート",
      "vp.err.sep": "。",
      "vp.err.engineMissing": "推論エンジンが読み込まれていません。ローカルの HTTP サーバー経由でページを開いてください",
      "vp.err.ioNames": "モデルの入力/出力名が wav/emb ではありません。モデルファイルを確認してください",
      "vp.err.modelLoad": "モデルの読み込みに失敗しました：{detail}",
      "vp.err.hintFile": "「モデルファイルを選択」をクリックして、上の階層にある models/ecapa.onnx を選んでください",
      "vp.err.hintHttp": "モデルファイルを手動で選ぶか、ローカルの HTTP サーバー経由でページを開いてください",
      "vp.err.audioShort": "音声が短すぎます。0.5 秒以上必要です",
      "vp.err.audioProcess": "音声の処理に失敗しました：{detail}",
      "vp.err.decode": "このファイルはブラウザでデコードできません。wav / mp3 / m4a / ogg を試してください",
      "vp.err.audioEmpty": "音声が空です",
      "vp.err.noEmbedding": "有効な声紋を得られませんでした。より明瞭な音声で試してください",
      "vp.err.compute": "計算に失敗しました：{detail}",
      "vp.err.outputDim": "モデルの出力が 192 次元ではありません",
      "vp.err.noRecording": "音声を録音できませんでした",
      "vp.err.mic": "マイクを開けません：{detail}。権限を確認するか、音声ファイルを選んでください",
      "vp.err.micUnsupported": "このブラウザは録音に対応していません。音声ファイルを選んでください",
      "vp.err.engineFail": "推論エンジンの読み込みに失敗しました。ネットワークを確認してページを再読み込みしてください",
      "vp.log.scriptTimeout": "スクリプトの読み込みがタイムアウトしました",
      "vp.log.scriptFail": "スクリプトのダウンロードに失敗しました",
      "vp.log.wasmUnreachable": "wasm に到達できません",
      "vp.log.ortNotRegistered": "ort が登録されませんでした",
      "vp.log.ortFail": "onnxruntime の読み込みに失敗（{src}）：{detail}",
      "vp.src.cdn": "CDN",
      "vp.src.local": "ローカル",
    },
  };

  let current = detect();
  const listeners = [];

  function detect() {
    try {
      const stored = localStorage.getItem(STORE_KEY);
      if (LANGS.includes(stored)) return stored;
    } catch (_) { /* localStorage 不可用时忽略 */ }
    const nav = (navigator.language || "en").toLowerCase();
    if (nav.indexOf("zh") === 0) return "zh";
    if (nav.indexOf("ja") === 0) return "ja";
    return "en";
  }

  function t(key, vars) {
    let s;
    if (dict[current] && Object.prototype.hasOwnProperty.call(dict[current], key)) {
      s = dict[current][key];
    } else if (Object.prototype.hasOwnProperty.call(dict.en, key)) {
      s = dict.en[key];
    } else {
      return key;
    }
    if (vars) {
      for (const k of Object.keys(vars)) {
        s = s.split("{" + k + "}").join(String(vars[k]));
      }
    }
    return s;
  }

  function apply(root) {
    const scope = root || document;
    document.documentElement.lang = HTML_LANG[current];
    scope.querySelectorAll("[data-i18n]").forEach((el) => {
      el.textContent = t(el.getAttribute("data-i18n"));
    });
    scope.querySelectorAll("[data-i18n-html]").forEach((el) => {
      el.innerHTML = t(el.getAttribute("data-i18n-html"));
    });
    scope.querySelectorAll("[data-i18n-attr]").forEach((el) => {
      el.getAttribute("data-i18n-attr").split(";").forEach((pair) => {
        const idx = pair.indexOf(":");
        if (idx < 0) return;
        const attr = pair.slice(0, idx).trim();
        const key = pair.slice(idx + 1).trim();
        if (attr && key) el.setAttribute(attr, t(key));
      });
    });
    document.querySelectorAll(".lang-btn").forEach((btn) => {
      const active = btn.getAttribute("data-lang") === current;
      btn.classList.toggle("active", active);
      btn.setAttribute("aria-pressed", active ? "true" : "false");
    });
  }

  function setLang(lang) {
    if (!LANGS.includes(lang) || lang === current) return;
    current = lang;
    try { localStorage.setItem(STORE_KEY, lang); } catch (_) { /* 忽略 */ }
    apply();
    listeners.forEach((f) => {
      try { f(lang); } catch (err) { console.error(err); }
    });
  }

  function onChange(f) { listeners.push(f); }
  function lang() { return current; }

  // 在指定容器里渲染语言切换按钮组。
  function mountSwitcher(container) {
    const group = document.createElement("div");
    group.className = "lang-switch";
    group.setAttribute("role", "group");
    LANGS.forEach((l) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "lang-btn";
      btn.setAttribute("data-lang", l);
      btn.textContent = LANG_NAMES[l];
      btn.addEventListener("click", () => setLang(l));
      group.appendChild(btn);
    });
    container.appendChild(group);
    return group;
  }

  return { t, apply, setLang, onChange, lang, mountSwitcher, LANGS, LANG_NAMES };
})();

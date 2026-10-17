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
      "meta.title.brain": "Brain API · PP Friend",
      "meta.desc.brain": "PP Friend 客户端与服务端（brain）之间的协议：HTTP + MessagePack 的两个端点、音频格式、打断记账与重试约定。",
      "meta.title.enroll": "声纹注册 · PP Friend",
      "meta.desc.enroll": "在浏览器本地为 PP Friend 注册声纹：录音或选择音频文件，计算 192 维 ECAPA 声纹并导出 spkemb.f32。音频不上传。",

      "nav.home": "主页",
      "nav.brainApi": "Brain API",
      "nav.enroll": "声纹注册",
      "nav.github": "GitHub",
      "nav.lang": "语言",

      "h.hero.tag": "一个一直开着的语音搭子。你随时开口它都在，它有进展了也会主动来找你。",
      "h.hero.ppAria": "用户把语音推给 brain，再把回复拉回手机；agent 把文本推给 brain，再把人的文本拉回去。四条通道同时开着。",
      "h.hero.ppYou": "用户",
      "h.hero.ppUserSub": "随时开口",
      "h.hero.ppClient": "手机客户端",
      "h.hero.ppClientSub": "PP Friend · 录音 / 放音",
      "h.hero.ppServer": "brain 服务端",
      "h.hero.ppServerSub": "消息枢纽",
      "h.hero.ppAgent": "agent",
      "h.hero.ppAgentSub": "理解 · 执行",
      "h.hero.ppHumanPush": "你的语音",
      "h.hero.ppHumanPull": "它的回复",
      "h.hero.ppAgentPush": "agent 文本",
      "h.hero.ppAgentPull": "人类文本",
      "h.hero.ppCaption": "PP 是 Push and Pull",
      "h.hero.ppCaptionSub": "四路并行：两边各推各拉，不是一问一答。",
      "h.hero.made": "这个项目本身的开发就是用 PP Friend 跑的：对着手机说话来驱动编码，需求、审查和修复一路靠语音说完。",
      "h.hero.ctaEnroll": "打开声纹注册工具",
      "h.hero.ctaGithub": "GitHub 仓库",

      "h.mot.title": "什么时候用",
      "h.mot.lead": "agent 能干长活了，人不用一直坐在电脑前。",
      "h.mot.i1": "走路、做饭、手上忙着别的，开口就行。",
      "h.mot.i2": "离开电脑，不用回来看进度；它有话会说。",
      "h.mot.i3": "手腕疼，不想打字，也不想举手机。",
      "h.mot.close": "它一直在旁边，不用打开，也不用盯着。",

      "h.feat.title": "主要能力",
      "h.feat.duplex.t": "全双工",
      "h.feat.duplex.d": "它说话时也竖着耳朵。两边同时开着，像打电话，不像对讲机。",
      "h.feat.barge.t": "可打断",
      "h.feat.barge.d": "它讲到一半你开口，确认是人在说话就立刻停，并把没讲完的部分报给服务端。默认关，开关在设置里。",
      "h.feat.bg.t": "后台不中断",
      "h.feat.bg.d": "切去别的 App、锁屏，对话都还在继续。",
      "h.feat.vad.t": "本地断句",
      "h.feat.vad.d": "一句话说完才上传整句，不是把麦克风一直推流上去。",
      "h.feat.vp.t": "声纹门控",
      "h.feat.vp.d": "先比对是不是你的声音，不像就整段丢掉，家人的话不会发出去。",
      "h.feat.profiles.t": "多档案",
      "h.feat.profiles.d": "同时挂着好几个 brain，各记各的账；只有当前这个会出声。",

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
      "h.quick.fetchNote": "# 宿主跑 cargo test 才需要",
      "h.quick.rust": "只有改了 Rust 源码才需要重跑 tools/build_rust_android.sh（产物要一起提交）。",
      "h.quick.mock": "没有 brain 也能端到端自测：仓库带了一个按协议手写实现的假 brain，内含一份独立的 MessagePack 实现，用来验证协议理解有没有跑偏。",

      "h.brain.title": "自己实现一个 brain",
      "h.brain.body": "服务端就是两个 HTTP 端点，MessagePack 载荷。协议不长，一页写得完，照着就能写一个自己的 brain。",
      "h.brain.button": "看 Brain API 协议",

      "h.enroll.title": "声纹注册工具",
      "h.enroll.body": "说话人识别需要一份本人声纹。在浏览器里录一段话或选一个音频文件，算出 192 维声纹并下载 spkemb.f32（768 字节，float32），再到 App 的设置 → 通用 → 说话人识别里导入。录音和推理都在浏览器本地完成，音频不上传。",
      "h.enroll.button": "打开声纹注册工具",

      "h.footer.license": "PP Friend 是开源项目。许可证尚未确定，以仓库 README 为准。",
      "h.footer.docs": "设计、协议与交接文档见仓库的 docs/ 目录。",

      "b.hero.title": "Brain API",
      "b.hero.sub": "手机只采音和放音；识别、对话、合成都由 brain（你自己的服务端）承担。这一页是协议本身，照着就能写一个自己的 brain。",
      "b.hero.note": "与仓库里的 docs/brain-api.md 同源，以它为准。",

      "b.ov.title": "概览",
      "b.ov.body": "协议里一共四个端点，客户端只用前两个。后两个是给 agent 的纯文本通道，和客户端这套音频进、音频出不是一回事。",
      "b.ov.th.ep": "端点",
      "b.ov.th.req": "请求",
      "b.ov.th.resp": "响应",
      "b.ov.th.used": "客户端",
      "b.ov.yes": "使用",
      "b.ov.no": "未使用",
      "b.ov.kind": "kind 是载荷判别符：empty 是没有内容，text 是有文本。它不代表操作成败，那是 HTTP 状态码的事。",
      "b.ov.loops": "客户端跑两条互相独立的循环：一条在 /brain-to-human 上长轮询，挂住直到 brain 有话说；另一条把断句切出来的语音按顺序串行发到 /human-to-brain。",

      "b.auth.title": "鉴权",
      "b.auth.body": "两个端点都支持 Bearer token：",
      "b.auth.i1": "token 是用户配置项，和 brain_id 一样，不是生成的。",
      "b.auth.i2": "token 可以为空，表示这个部署没开鉴权。空的时候客户端不发 Authorization 头，而不是发一个空的 Bearer。",
      "b.auth.i3": "401 是配置错误，不要当网络问题无限重试。提示 token 无效，停掉轮询。",

      "b.enc.title": "载荷编码：MessagePack",
      "b.enc.body": "请求和响应都是裸的 MessagePack，不是 JSON，也不是 multipart。上行音频放在 map 里，类型是 bin：不是 base64，不是字符串，二进制原样进出。",
      "b.enc.ct": "Content-Type / Accept 用 application/msgpack。规范没写明这个取值，客户端把它收在一个常量里，改一处即可。",
      "b.enc.warn": "不要把响应当 UTF-8 解，里面是二进制音频。先按 MessagePack 解出 map，再取字段。",

      "b.th.key": "键",
      "b.th.type": "类型",
      "b.th.desc": "说明",

      "b.up.body": "把一段人类语音交给 brain，只等转写。断句切出一句话就发一次。请求是一个 MessagePack map：",
      "b.up.f.brainId": "会话句柄，人起的名字，比如 \"员工3\"。两个端点里必须一致。",
      "b.up.f.audio": "整句语音，Ogg Opus 16 kHz。没有 WAV 回落。",
      "b.up.f.heardMs": "可选。上一段回复实际被听到的毫秒数，见「打断记账」。",
      "b.up.f.unheardText": "可选。上一段回复没被听到的那部分文字，见「打断记账」。",
      "b.up.resp": "响应：",

      "b.down.body": "长轮询：请求挂住，直到 brain 有话说或者超时。请求只有 brain_id 一个字段。响应是两种之一：",
      "b.down.empty": "empty 只是「暂时没话说」，客户端立刻再发一次，不停不等。",
      "b.down.spans": "spans 是可选的按句时间账，用来支持「哪几句没听到」的上报。不给也能用，只是被打断时客户端只能估一个断点。",

      "b.audio.title": "音频格式",
      "b.audio.th.dir": "方向",
      "b.audio.th.fmt": "格式",
      "b.audio.th.rate": "采样率",
      "b.audio.up": "上行 /human-to-brain",
      "b.audio.down": "下行 /brain-to-human",
      "b.audio.why": "两个方向采样率不同，是跟着模型走的：识别吃 16 kHz，合成出 24 kHz。",
      "b.audio.trap": "实现时注意：Opus 内部固定跑 48 kHz，解码出来的采样率未必等于声明的采样率。要读解码器的实际输出再重采样，写死会变速。",

      "b.int.title": "打断记账：heard_ms 与 unheard_text",
      "b.int.body": "brain 说到一半被打断，客户端要告诉它「哪一段没进到用户耳朵里」。报的是文字不是时间点：光给一个毫秒数，brain 还得自己把文本和音频对齐。",
      "b.int.spans": "所以回复里可以带一份按句的时间账 spans。它顺序拼起来就是整条音频，句间不许有没记账的静音：",
      "b.int.f.spanText": "这一小段的文字，按句切最好。",
      "b.int.f.spanMs": "这一小段在 audio 里占的毫秒数。",
      "b.int.fallback": "spans 是可选的。没给、或格式不对，客户端按 heard_ms / 总长 的比例估断点，再对齐到最近的句子边界。",
      "b.int.fields": "被打断之后，下一句 /human-to-brain 多带两个字段：",
      "b.int.f1": "unheard_text：没听到的那部分文字，包括正在播的那条没听完的尾巴，加上播放队列里还没轮到播的整段。",
      "b.int.f2": "heard_ms：实际听到的毫秒数，纯粹方便服务端诊断。",
      "b.int.f3": "只在真的被打断过才出现。没打断就一个键都不发：「没值」和「听到了 0 ms」是两件事。",
      "b.int.f4": "账是累加的，挂在下一句用户的话上一起走，上传成功才清，失败留着。",

      "b.err.title": "错误与重试",
      "b.err.body": "协议层没有错误响应，失败只来自网络和 HTTP 状态码：",
      "b.err.th.case": "情况",
      "b.err.th.act": "处理",
      "b.err.r1.k": "网络错误 / 超时 / 5xx",
      "b.err.r1.v": "客户端退避重试：500 ms 起，翻倍，15 s 封顶。",
      "b.err.r2.v": "不重试。提示 token 无效，停止轮询。",
      "b.err.r3.k": "响应不是合法 MessagePack",
      "b.err.r3.v": "协议错误，重试大概率还是错。",

      "b.ex.title": "最小示例",
      "b.ex.body": "字段名就这些。一个能跑的 brain 只需要接两种请求、回三种 map。仓库里有一个按这个协议手写的假 brain（tools/mock_brain.py，含一份独立的 MessagePack 实现），可以拿来对照。",

      "b.pending.title": "还没定的事",
      "b.pending.i1": "Content-Type 的确切取值规范没写，客户端用 application/msgpack。",
      "b.pending.i2": "brain 收到 unheard_text 之后怎么处理（当场重说还是以后避开）还没定。",

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
      "meta.title.brain": "Brain API · PP Friend",
      "meta.desc.brain": "The protocol between the PP Friend client and your server (the brain): two HTTP + MessagePack endpoints, audio formats, interruption accounting, and retry rules.",
      "meta.title.enroll": "Voiceprint enrollment · PP Friend",
      "meta.desc.enroll": "Enroll a voiceprint for PP Friend entirely in your browser: record or pick an audio file, compute a 192-dimensional ECAPA embedding, and export spkemb.f32. Audio is never uploaded.",

      "nav.home": "Home",
      "nav.brainApi": "Brain API",
      "nav.enroll": "Voiceprint",
      "nav.github": "GitHub",
      "nav.lang": "Language",

      "h.hero.tag": "A voice companion that stays on. Speak whenever; it picks up. When it has news, it comes to you.",
      "h.hero.ppAria": "The user pushes voice to the brain and pulls replies back to the phone; the agent pushes text to the brain and pulls the human's text back. All four channels stay open at once.",
      "h.hero.ppYou": "User",
      "h.hero.ppUserSub": "just speak",
      "h.hero.ppClient": "Phone client",
      "h.hero.ppClientSub": "PP Friend · mic / speaker",
      "h.hero.ppServer": "brain server",
      "h.hero.ppServerSub": "message hub",
      "h.hero.ppAgent": "agent",
      "h.hero.ppAgentSub": "reason · act",
      "h.hero.ppHumanPush": "your voice",
      "h.hero.ppHumanPull": "its reply",
      "h.hero.ppAgentPush": "agent text",
      "h.hero.ppAgentPull": "human text",
      "h.hero.ppCaption": "PP is Push and Pull",
      "h.hero.ppCaptionSub": "Four lanes at once: both sides push and pull, not a turn-by-turn exchange.",
      "h.hero.made": "PP Friend was built with PP Friend itself: requirements, reviews, and fixes were dictated to the coding agent by voice, through the phone.",
      "h.hero.ctaEnroll": "Open the enrollment tool",
      "h.hero.ctaGithub": "GitHub repository",

      "h.mot.title": "When you need it",
      "h.mot.lead": "An agent can now work for a long time. You don't have to sit at the desk.",
      "h.mot.i1": "Walking, cooking, hands busy: just talk.",
      "h.mot.i2": "Away from the desk, no need to check back. It speaks up.",
      "h.mot.i3": "Your wrist hurts. You don't want to type or hold a phone.",
      "h.mot.close": "It stays nearby. No app to open, no screen to watch.",

      "h.feat.title": "What it does",
      "h.feat.duplex.t": "Full duplex",
      "h.feat.duplex.d": "It keeps listening while it talks. Both directions stay open, like a phone call, not a walkie-talkie.",
      "h.feat.barge.t": "Barge-in",
      "h.feat.barge.d": "Start talking mid-reply and it stops right away, then tells the server which part you never heard. Off by default; there is a switch in settings.",
      "h.feat.bg.t": "Runs in the background",
      "h.feat.bg.d": "Switch apps or lock the screen; the conversation keeps going.",
      "h.feat.vad.t": "On-device endpointing",
      "h.feat.vad.d": "A sentence is uploaded only after you finish it; the microphone is never streamed raw.",
      "h.feat.vp.t": "Voiceprint gate",
      "h.feat.vp.d": "Each utterance is checked against your voice first; if it is not you, the whole segment is dropped and never sent.",
      "h.feat.profiles.t": "Multiple profiles",
      "h.feat.profiles.d": "Keep several brains connected at once, each with its own history. Only the focused one speaks out loud.",

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
      "h.quick.fetchNote": "# only needed for cargo test on the host",
      "h.quick.rust": "Re-run tools/build_rust_android.sh only after changing Rust code, and commit the artifacts together.",
      "h.quick.mock": "You can test the whole chain without a real brain: the repo ships a mock brain implemented by hand against the protocol, including a standalone MessagePack implementation, to check that the protocol understanding has not drifted.",

      "h.brain.title": "Build your own brain",
      "h.brain.body": "The server side is two HTTP endpoints with MessagePack payloads. The protocol fits on one page, enough to write a brain of your own.",
      "h.brain.button": "Read the Brain API",

      "h.enroll.title": "Voiceprint enrollment tool",
      "h.enroll.body": "Speaker gating needs an enrolled voiceprint. Record a clip or pick an audio file in the browser; the tool computes a 192-dimensional embedding and offers spkemb.f32 (768 bytes, float32) for download. Import it in the app under Settings → General → Speaker verification. Recording and inference stay in the browser; audio is never uploaded.",
      "h.enroll.button": "Open the enrollment tool",

      "h.footer.license": "PP Friend is an open-source project. The license is not decided yet; see the repository README.",
      "h.footer.docs": "Design, protocol, and handoff documents live in the docs/ directory of the repository.",

      "b.hero.title": "Brain API",
      "b.hero.sub": "The phone only records and plays audio; recognition, dialogue, and synthesis are all done by the brain (your own server). This page is the protocol itself, enough to write a brain of your own.",
      "b.hero.note": "Kept in sync with docs/brain-api.md in the repository, which is the source of truth.",

      "b.ov.title": "Overview",
      "b.ov.body": "The protocol has four endpoints in total; the client only uses the first two. The other two are a text-only channel for agents, a different thing from the client's audio-in, audio-out.",
      "b.ov.th.ep": "Endpoint",
      "b.ov.th.req": "Request",
      "b.ov.th.resp": "Response",
      "b.ov.th.used": "Client",
      "b.ov.yes": "Used",
      "b.ov.no": "Not used",
      "b.ov.kind": "kind is a payload discriminator: empty means no content, text means there is text. It does not report success or failure; that is what HTTP status codes are for.",
      "b.ov.loops": "The client runs two independent loops: one long-polls /brain-to-human, hanging until the brain has something to say; the other uploads endpointed utterances to /human-to-brain, one at a time, in order.",

      "b.auth.title": "Authentication",
      "b.auth.body": "Both endpoints accept a Bearer token:",
      "b.auth.i1": "The token is a user setting, like brain_id, not generated.",
      "b.auth.i2": "The token may be empty, meaning the deployment has no authentication. When empty, the client omits the Authorization header instead of sending a bare \"Bearer \".",
      "b.auth.i3": "A 401 is a configuration error. Do not retry it like a network problem: report an invalid token and stop polling.",

      "b.enc.title": "Payload encoding: MessagePack",
      "b.enc.body": "Requests and responses are bare MessagePack, not JSON, not multipart. The uplink audio lives inside the map as a bin value: not base64, not a string; bytes go in and out untouched.",
      "b.enc.ct": "Use application/msgpack for Content-Type / Accept. The spec does not pin down this value; the client keeps it in a single constant so it can be changed in one place.",
      "b.enc.warn": "Do not decode the response as UTF-8; it contains binary audio. Unpack the MessagePack map first, then read the fields.",

      "b.th.key": "Key",
      "b.th.type": "Type",
      "b.th.desc": "Meaning",

      "b.up.body": "Hands one human utterance to the brain and waits only for the transcript. One request per endpointed sentence. The request is a MessagePack map:",
      "b.up.f.brainId": "Conversation handle, a human-chosen name such as \"员工3\". Must match in both endpoints.",
      "b.up.f.audio": "The whole utterance, Ogg Opus 16 kHz. There is no WAV fallback.",
      "b.up.f.heardMs": "Optional. How many milliseconds of the previous reply were actually heard; see Interruption accounting.",
      "b.up.f.unheardText": "Optional. The part of the previous reply the user never heard; see Interruption accounting.",
      "b.up.resp": "Response:",

      "b.down.body": "Long polling: the request hangs until the brain has something to say or times out. brain_id is the only request field. The response is one of two shapes:",
      "b.down.empty": "empty only means \"nothing to say right now\"; the client re-polls immediately, without pausing.",
      "b.down.spans": "spans is an optional per-sentence time ledger that supports \"which sentences were not heard\" reporting. Without it things still work; the client can only estimate a cut point when interrupted.",

      "b.audio.title": "Audio formats",
      "b.audio.th.dir": "Direction",
      "b.audio.th.fmt": "Format",
      "b.audio.th.rate": "Sample rate",
      "b.audio.up": "Uplink /human-to-brain",
      "b.audio.down": "Downlink /brain-to-human",
      "b.audio.why": "The two directions use different sample rates because the models do: recognition takes 16 kHz, synthesis produces 24 kHz.",
      "b.audio.trap": "When implementing: Opus internally always runs at 48 kHz, and the decoded sample rate may not equal the declared one. Read the decoder's actual output rate and resample accordingly; hardcoding causes pitch and speed shifts.",

      "b.int.title": "Interruption accounting: heard_ms and unheard_text",
      "b.int.body": "When a reply is cut short, the client tells the brain which part never reached the user's ears. It reports text, not a timestamp: a millisecond number alone would force the brain to align text and audio itself.",
      "b.int.spans": "That is why a reply can carry spans, a per-sentence time ledger. Concatenated in order it covers the whole audio; no silence between sentences may go unaccounted:",
      "b.int.f.spanText": "The text of this piece, ideally one sentence.",
      "b.int.f.spanMs": "How many milliseconds of audio this piece occupies.",
      "b.int.fallback": "spans is optional. If it is missing or malformed, the client estimates the cut point from heard_ms / total duration and snaps to the nearest sentence boundary.",
      "b.int.fields": "After an interruption, the next /human-to-brain request carries two extra fields:",
      "b.int.f1": "unheard_text: the unheard text: the unplayed tail of the reply that was cut off, plus the full text of replies still queued for playback.",
      "b.int.f2": "heard_ms: how many milliseconds were actually heard, purely for server-side diagnostics.",
      "b.int.f3": "The keys appear only after a real interruption. If nothing was interrupted, neither key is sent; \"absent\" and \"heard 0 ms\" are different things.",
      "b.int.f4": "The ledger accumulates and rides along with the next user utterance; it is cleared only after a successful upload, and kept on failure.",

      "b.err.title": "Errors and retries",
      "b.err.body": "There are no protocol-level error responses; failures come only from the network and HTTP status codes:",
      "b.err.th.case": "Case",
      "b.err.th.act": "What to do",
      "b.err.r1.k": "Network error / timeout / 5xx",
      "b.err.r1.v": "The client retries with backoff: starting at 500 ms, doubling, capped at 15 s.",
      "b.err.r2.v": "Do not retry. Report an invalid token and stop polling.",
      "b.err.r3.k": "Response is not valid MessagePack",
      "b.err.r3.v": "Protocol error; retrying will most likely fail again.",

      "b.ex.title": "Minimal examples",
      "b.ex.body": "These are all the field names. A working brain only needs to accept two kinds of requests and return three kinds of maps. The repository ships a mock brain handwritten against this protocol (tools/mock_brain.py, with its own standalone MessagePack implementation) for cross-checking.",

      "b.pending.title": "Open questions",
      "b.pending.i1": "The exact Content-Type value is not pinned by the spec; the client uses application/msgpack.",
      "b.pending.i2": "What the brain should do with unheard_text (repeat it right away vs. avoid it later) is undecided.",

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
      "meta.title.brain": "Brain API · PP Friend",
      "meta.desc.brain": "PP Friend クライアントとサーバー（brain）の間のプロトコル。HTTP + MessagePack の 2 つのエンドポイント、音声フォーマット、割り込みの記帳、リトライの取り決め。",
      "meta.title.enroll": "声紋登録 · PP Friend",
      "meta.desc.enroll": "PP Friend の声紋をブラウザ内だけで登録します。録音または音声ファイルから 192 次元の ECAPA 声紋を計算し、spkemb.f32 を書き出します。音声はアップロードされません。",

      "nav.home": "ホーム",
      "nav.brainApi": "Brain API",
      "nav.enroll": "声紋登録",
      "nav.github": "GitHub",
      "nav.lang": "言語",

      "h.hero.tag": "ずっと繋がっている音声の相棒。いつ話しかけても応えますし、向こうからも用があれば声をかけてきます。",
      "h.hero.ppAria": "ユーザーはスマホから音声を brain に push し、返事を pull します。エージェントはテキストを brain に push し、人のテキストを pull します。4 本の回線が同時に開いています。",
      "h.hero.ppYou": "ユーザー",
      "h.hero.ppUserSub": "いつでも話す",
      "h.hero.ppClient": "スマホアプリ",
      "h.hero.ppClientSub": "PP Friend・録音 / 再生",
      "h.hero.ppServer": "brain サーバー",
      "h.hero.ppServerSub": "メッセージの中枢",
      "h.hero.ppAgent": "エージェント",
      "h.hero.ppAgentSub": "理解・実行",
      "h.hero.ppHumanPush": "あなたの声",
      "h.hero.ppHumanPull": "返事",
      "h.hero.ppAgentPush": "agent のテキスト",
      "h.hero.ppAgentPull": "人のテキスト",
      "h.hero.ppCaption": "PP は Push and Pull",
      "h.hero.ppCaptionSub": "4 本の回線が同時に開いています。双方が push と pull をしていて、一問一答ではありません。",
      "h.hero.made": "このプロジェクト自体の開発も PP Friend で回しています。スマホに向かって話すことでコーディングを駆動し、要件もレビューも修正も音声で進めました。",
      "h.hero.ctaEnroll": "声紋登録ツールを開く",
      "h.hero.ctaGithub": "GitHub リポジトリ",

      "h.mot.title": "どんなときに使うか",
      "h.mot.lead": "エージェントが長く働けるようになり、人はずっと机の前にいる必要はなくなりました。",
      "h.mot.i1": "歩いているときも、料理中も、手がふさがっていても、そのまま話せばいい。",
      "h.mot.i2": "机を離れても、進捗を見に戻らなくていい。向こうから声をかけてくれます。",
      "h.mot.i3": "手首が痛くて、タイピングもスマホを持つこともつらい。",
      "h.mot.close": "そばにいるだけで、開くアプリも見張る画面もありません。",

      "h.feat.title": "主な機能",
      "h.feat.duplex.t": "全二重",
      "h.feat.duplex.d": "話している間もこちらの声を聞いています。トランシーバーではなく、電話と同じ双方向です。",
      "h.feat.barge.t": "割り込み",
      "h.feat.barge.d": "返答の途中で話し始めるとすぐに再生を止め、聞こえなかった部分をサーバーに伝えます。既定はオフで、設定にスイッチがあります。",
      "h.feat.bg.t": "バックグラウンドで継続",
      "h.feat.bg.d": "別アプリに切り替えても、画面をロックしても、会話は続きます。",
      "h.feat.vad.t": "端末上の区間検出",
      "h.feat.vad.d": "文を話し終えてからまとめて送ります。マイクの音を垂れ流しにはしません。",
      "h.feat.vp.t": "声紋ゲート",
      "h.feat.vp.d": "まず本人の声かどうかを確かめ、違えばその区間はまるごと破棄。家族の発話は送信されません。",
      "h.feat.profiles.t": "複数プロファイル",
      "h.feat.profiles.d": "複数の brain を同時につないでおけます。履歴は別々で、声を出すのは今開いている一つだけです。",

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
      "h.quick.fetchNote": "# ホストで cargo test を回すときだけ必要",
      "h.quick.rust": "tools/build_rust_android.sh を再実行するのは Rust のコードを変更したときだけです（生成物も一緒にコミットします）。",
      "h.quick.mock": "本物の brain がなくてもエンドツーエンドで確認できます。リポジトリにはプロトコルに沿って手書きで実装されたモック brain（独立した MessagePack 実装つき）が入っていて、プロトコルの解釈がずれていないかを確かめられます。",

      "h.brain.title": "brain を自分で実装する",
      "h.brain.body": "サーバー側は HTTP エンドポイント 2 本と MessagePack ペイロードだけ。プロトコルは 1 ページに収まり、これだけで自分の brain が書けます。",
      "h.brain.button": "Brain API を読む",

      "h.enroll.title": "声紋登録ツール",
      "h.enroll.body": "話者ゲートには本人の声紋の登録が必要です。ブラウザで音声を録音するか音声ファイルを選ぶと、192 次元の声紋を計算して spkemb.f32（768 バイト、float32）をダウンロードできます。あとはアプリの 設定 → 一般 → 話者認識 でインポートするだけです。録音と推論はブラウザ内で完結し、音声はアップロードされません。",
      "h.enroll.button": "声紋登録ツールを開く",

      "h.footer.license": "PP Friend はオープンソースプロジェクトです。ライセンスは未定で、リポジトリの README を参照してください。",
      "h.footer.docs": "設計・プロトコル・引き継ぎの文書はリポジトリの docs/ にあります。",

      "b.hero.title": "Brain API",
      "b.hero.sub": "スマホは録音と再生だけ。認識・対話・合成はすべて brain（自分のサーバー）が担当します。このページはプロトコルそのもので、これだけで自分の brain が書けます。",
      "b.hero.note": "リポジトリの docs/brain-api.md と同源で、そちらが正です。",

      "b.ov.title": "概要",
      "b.ov.body": "プロトコルにはエンドポイントが 4 つあり、クライアントが使うのは最初の 2 つだけです。残りの 2 つはエージェント向けのテキスト専用チャネルで、クライアントの音声入出力とは別物です。",
      "b.ov.th.ep": "エンドポイント",
      "b.ov.th.req": "リクエスト",
      "b.ov.th.resp": "レスポンス",
      "b.ov.th.used": "クライアント",
      "b.ov.yes": "使用",
      "b.ov.no": "未使用",
      "b.ov.kind": "kind はペイロードの判別子です。empty は中身なし、text はテキストあり。処理の成否は表しません。それは HTTP ステータスコードの仕事です。",
      "b.ov.loops": "クライアントは独立した 2 本のループを回します。1 本は /brain-to-human をロングポーリングし、brain に話すことができるまでぶら下がります。もう 1 本は区間検出で切り出した発話を順番どおりに 1 件ずつ /human-to-brain へ送ります。",

      "b.auth.title": "認証",
      "b.auth.body": "両方のエンドポイントで Bearer トークンを受け付けます：",
      "b.auth.i1": "トークンは brain_id と同じくユーザーが設定するもので、生成されるものではありません。",
      "b.auth.i2": "トークンは空でも構いません。そのデプロイに認証がないという意味です。空のときクライアントは Authorization ヘッダーを送らず、空の Bearer を送ることもしません。",
      "b.auth.i3": "401 は設定ミスです。ネットワーク障害のようにリトライを続けず、トークンが無効であることを表示してポーリングを止めてください。",

      "b.enc.title": "ペイロード：MessagePack",
      "b.enc.body": "リクエストもレスポンスも裸の MessagePack で、JSON でも multipart でもありません。上りの音声は map の中に bin 型で入ります。base64 でも文字列でもなく、バイト列がそのまま行き来します。",
      "b.enc.ct": "Content-Type / Accept には application/msgpack を使います。仕様ではこの値が明記されていないため、クライアントは 1 か所の定数にまとめています。",
      "b.enc.warn": "レスポンスを UTF-8 としてデコードしないでください。中身はバイナリの音声です。先に MessagePack として map を取り出し、それからフィールドを読みます。",

      "b.th.key": "キー",
      "b.th.type": "型",
      "b.th.desc": "意味",

      "b.up.body": "人間の発話を 1 つ brain に渡し、転写だけを待ちます。区間検出で 1 文切れるごとに 1 回送ります。リクエストは MessagePack の map です：",
      "b.up.f.brainId": "会話ハンドル。人が付ける名前で、例えば \"员工3\"。2 つのエンドポイントで一致している必要があります。",
      "b.up.f.audio": "発話全体。Ogg Opus 16 kHz。WAV へのフォールバックはありません。",
      "b.up.f.heardMs": "任意。直前の返答が実際に聞かれたミリ秒数。「割り込みの記帳」を参照。",
      "b.up.f.unheardText": "任意。直前の返答で聞かれなかった部分のテキスト。「割り込みの記帳」を参照。",
      "b.up.resp": "レスポンス：",

      "b.down.body": "ロングポーリングです。brain に話すことができるか、タイムアウトするまでリクエストがぶら下がります。リクエストのフィールドは brain_id のみ。レスポンスは次の 2 通りのどちらかです：",
      "b.down.empty": "empty は「今は話すことがない」というだけで、クライアントは間を置かずすぐにもう一度送ります。",
      "b.down.spans": "spans は任意の文ごとの時間帳で、「どの文が聞かれなかったか」の報告を支えます。なくても動きますが、割り込まれたときクライアントは区切り位置を推測するしかありません。",

      "b.audio.title": "音声フォーマット",
      "b.audio.th.dir": "方向",
      "b.audio.th.fmt": "フォーマット",
      "b.audio.th.rate": "サンプルレート",
      "b.audio.up": "上り /human-to-brain",
      "b.audio.down": "下り /brain-to-human",
      "b.audio.why": "方向ごとにサンプルレートが違うのはモデルに合わせたもので、認識は 16 kHz を受け、合成は 24 kHz を出します。",
      "b.audio.trap": "実装上の注意：Opus は内部で常に 48 kHz で動くため、デコード結果のサンプルレートは宣言値と一致するとは限りません。デコーダーの実際の出力レートを読んでリサンプルしてください。決め打ちするとピッチと速度がずれます。",

      "b.int.title": "割り込みの記帳：heard_ms と unheard_text",
      "b.int.body": "返答が途中で切られたとき、クライアントは「どの部分がユーザーの耳に届かなかったか」を brain に伝えます。伝えるのは時刻ではなくテキストです。ミリ秒数だけでは、brain が自分でテキストと音声を突き合わせる羽目になります。",
      "b.int.spans": "そのために返答には文ごとの時間帳 spans を載せられます。順につなげると音声全体を覆い、文の間に帳簿に載っていない無音があってはいけません：",
      "b.int.f.spanText": "この区間のテキスト。文単位が望ましい。",
      "b.int.f.spanMs": "この区間が audio の中で占めるミリ秒数。",
      "b.int.fallback": "spans は任意です。ない、または形式が不正な場合、クライアントは heard_ms / 全体の長さ の比率で区切り位置を推測し、最も近い文の境界に合わせます。",
      "b.int.fields": "割り込みのあと、次の /human-to-brain には 2 つのフィールドが増えます：",
      "b.int.f1": "unheard_text：聞かれなかったテキスト。再生中に切れた返答の残りと、再生キューでまだ番が回っていない返答の全文。",
      "b.int.f2": "heard_ms：実際に聞かれたミリ秒数。サーバー側の診断のためだけのもの。",
      "b.int.f3": "本当に割り込まれたときだけ現れます。割り込みがなければキー自体を送りません。「値がない」と「0 ms 聞いた」は別のことです。",
      "b.int.f4": "帳は累積し、次のユーザーの発話に乗せて一緒に送ります。アップロードが成功して初めて消え、失敗したら残ります。",

      "b.err.title": "エラーとリトライ",
      "b.err.body": "プロトコル層にエラーレスポンスはありません。失敗はネットワークと HTTP ステータスコードだけから来ます：",
      "b.err.th.case": "状況",
      "b.err.th.act": "対処",
      "b.err.r1.k": "ネットワークエラー / タイムアウト / 5xx",
      "b.err.r1.v": "クライアントがバックオフでリトライ。500 ms から始め、倍々で、上限 15 s。",
      "b.err.r2.v": "リトライしません。トークンが無効と表示し、ポーリングを止めます。",
      "b.err.r3.k": "レスポンスが正しい MessagePack ではない",
      "b.err.r3.v": "プロトコルエラー。リトライしてもたぶんまた失敗します。",

      "b.ex.title": "最小の例",
      "b.ex.body": "フィールド名はこれだけです。動く brain は 2 種類のリクエストを受け、3 種類の map を返せばよいだけです。リポジトリにはこのプロトコルどおりに手書きしたモック brain（tools/mock_brain.py、独立した MessagePack 実装つき）があり、突き合わせに使えます。",

      "b.pending.title": "未定のこと",
      "b.pending.i1": "Content-Type の正確な値は仕様に明記されていません。クライアントは application/msgpack を使っています。",
      "b.pending.i2": "unheard_text を受け取った brain がどう振る舞うか（その場で言い直すか、後で避けるか）は未定です。",

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

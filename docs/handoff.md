# 对齐结论 · 交接文档

记录本轮讨论中**已经对齐**的决定，以及**尚未决定**的部分。
供主会话接手，避免两边理解不一致。

> ⚠️ **协议细节以 [`brain-api.md`](./brain-api.md) 为准。**
> 本文档 §A 里关于载荷格式的描述**已过时** —— 协议后来从
> multipart/JSON 改成了 **MessagePack**。下面只保留了结论性内容，
> 具体格式不再重复，避免两处说法不一致。

---

## A. 架构：brain API 取代手机端 STT/TTS

**核心转变**：手机端只做两件事 —— 采音、放音。
识别、对话、合成全部由 brain 承担。对话状态全在服务端，
手机端不持有任何对话状态。

### A0. `brain_id` 是什么 —— **不是生成的，是人起的名字**

像人的名字一样有语义，标识"你在跟哪个 brain 说话"，由用户在客户端配置。

```
brain_id = "员工3"
```

推论：

- 客户端只要一个**文本输入框**，不需要 UUID 生成器，
  也不需要服务端发号接口
- 状态按名字存在服务端，**同一个 `brain_id` 跨 App 重启仍是同一段对话**
- 想开一段全新对话，换个名字就行
- 它同时出现在 `/human-to-brain` 和 `/brain-to-human` 里，两边必须一致

### A0b. 认证 —— Bearer token

`/human-to-brain` 和 `/brain-to-human` 都支持：

```http
Authorization: Bearer <token>
```

- token 是**用户配置项**（和 `brain_id` 一样），不是生成的
- **token 可能为空** —— 即该部署未启用鉴权。
  为空时客户端**不发送**该 header（而不是发空的 `Bearer `，
  那样容易被判成格式错误）
- 401 **不要**当网络问题无限重试 —— 那是配置错误，
  应当直接提示"token 无效"

### A1 / A2 / A3. 端点与载荷格式 —— **已变更为 MessagePack**

原方案是 `/human-to-brain` 走 multipart、`/brain-to-human` 按顶层
`Content-Type` 分派 JSON 或 multipart。

**服务端最终给的规范是：请求和响应都是裸 MessagePack**，
没有 multipart、没有 boundary、没有 Content-Type 分派。

```
/human-to-brain   req { brain_id: str, audio: bin }              // Ogg Opus 16k
                  ret { kind: "text", text: str }
/brain-to-human   req { brain_id: str }
                  ret { kind: "empty" }
                    | { kind: "text", text: str, audio: bin }    // Ogg Opus 24k
```

`kind` 的取值是 `empty` / `text`（不是早先写的 `response`）。

详细字段、Content-Type 取值、以及客户端实现要点见 `brain-api.md` §2–§3。

### A4. 音频格式 —— 已定

| 方向 | 格式 | 采样率 |
|---|---|---|
| 上行（`/human-to-brain`） | `audio/ogg`，Ogg Opus | **16kHz** |
| 下行（`/brain-to-human`） | `audio/ogg`，Ogg Opus | **24kHz** |

两个方向都是 Ogg Opus，但**采样率不同** —— 跟着两端的模型走：
STT 吃 16k，TTS 出 24k。
（有实测佐证：现有 MOSS-TTS 的 `pcm` 输出就是 24000Hz。）

对客户端意味着**两个方向都要做 Opus 编解码**，且下行还要重采样：

| 方向 | 客户端要做的事 |
|---|---|
| 上行 | PCM16 16k → **Opus 编码** → Ogg 封装 |
| 下行 | Ogg 解封装 → **Opus 解码** → **重采样到引擎速率（16k）** |

纯 Dart 没有可用的 Opus 编解码器，两块都得走原生：
解码用 `MediaExtractor` + `MediaCodec`，
编码用 `MediaCodec`（`audio/opus`）+ `MediaMuxer`（`MUXER_OUTPUT_OGG`）。

> ⚠️ **别假设解码出来的采样率等于声明的采样率。**
> Opus 内部固定跑 48kHz，Ogg Opus 头里的 "input sample rate" 只是提示。
> Android 的 `MediaCodec` 解码 Opus 通常**直接给 48000Hz**。
> 必须**读解码器实际输出的采样率**再重采样，写死 24k 会变速
> （音调变低、语速变慢），而且很难查。

**上行压缩选型**（3 秒语音）：WAV 96KB / µ-law 48KB / gzip 40KB / **Opus ~6KB**。
选 Opus —— 16x vs 2x 不是一个量级，且下行本来就要写 Opus 解码。

**minSdk 提到 29**（原方案是 24，已推翻）：

| 能力 | 最低 API |
|---|---|
| Opus 解码 | **21** |
| Opus 编码 | **29** |
| `MUXER_OUTPUT_OGG` | **29** |

原方案保留 24 的前提是"`/human-to-brain` 收 WAV，没编码器就回落"。
**服务端规范只收 `audio/ogg`**，这个前提不成立了 ——
与其留一个"看起来成功实际失败"的回落，不如把门槛提到 29。

即使提到 29，客户端**仍然在运行时用 `MediaCodecList` 探测**编码器，
不是只判 API 级别 —— OEM 差异真实存在。探测失败就明确报错。

### A5. 打断语义 —— 已对齐（我原先的理解是错的）

- response 的**文本永远进入消息流**，无论是否被打断
- 只有 **AI 语音**会被清空
- 因此 **服务端不需要加 `since` 字段**。客户端本地已有的 `epoch` 机制就够：
  在途的音频分块全部作废，文本该进流照样进流
- **不要自动打断（barge-in）**：收到就播，不做双讲检测

→ 可以删除：`playbackLevel` 参考电平、打断阈值、双讲余量、以及对应的 UI。
（这套是之前为了"自动打断"做的，现在不需要了。）

**A5 修订（2026-10-15）**：`docs/需求-闭麦与打断.md` 把这条推翻了半个 ——
打断不再"不做"，而是做成**用户可见的独立开关，默认关**（关着就是 A5 原文）。

- **关着**：收到就播。此时仍保留那道**双讲余量**门（AI 在出声、麦克风没明显
  高过播放电平时喂数字静音）—— 目的是防回声自激，不是做自动打断。
  它以前是隐形的，现在挂在开关的默认态上，有据可查。
- **开着**：本地断句一判到人声就停播，不设双讲门槛。代价是 AEC 不干净时
  它自己的声音可能把人声吵醒（等于自己打断自己）。
  但「判到人声」不是「刚听到有声那一瞬间」—— Silero 那个 `speaking` 标志
  要静满 `vadMinSilenceMs` 才落回，一声咳嗽也能扛出 700ms+。所以还要
  **连续说够 350ms** 才认（`bargeInMinSpeechMs`），否则咳嗽就打断。
- 被打断时要**上报"我哪一段没听到"**：`/human-to-brain` 加 `unheard_text`
  （没听到的那部分文字）+ `heard_ms`（见 `brain-api.md` §5.3b）。
  否则 brain 以为自己讲完了，下一轮接着"刚才说的那个"往下讲，
  用户只能装懂。**报文字而不是毫秒** —— 给 brain 一个时间点，它还得
  自己对一遍；要翻成文字，得它在 `/brain-to-human` 里给一份按句的
  时间账（`spans`，可选字段）。
- 另有「闭麦」开关：麦克风帧在本地换成静音，一个字节都不上传。
  闭麦期间打断天然失效（本地断句听不到东西）。

### A5b. 已确认（原待确认项）

- ✅ `/brain-to-human` 收到 `empty` 就**继续轮询**，不停不等
- ✅ **不存在协议层错误响应**，只有网络问题，客户端自己重试（退避 + 上限）
- ✅ 上行音频格式：`audio/ogg`，Ogg Opus，16kHz

### A6. 清空播放队列的触发方式 —— **已定**

**通知栏按钮 + 音量减键，两个都做。**

- 通知栏「停止说话」按钮 —— 覆盖后台/锁屏（这是设计目标场景）
- 音量减键 —— 只在 App 前台、且正在播 AI 语音时拦截，其余时候放行

只清音频，文本照样进消息流。


## B. UI

### B1. 应用名

`pp_friend` → **PP Friend**（只改显示名；`applicationId` 保持 `com.ppfriend.pp_friend` 不动）

### B2. 主页面需要消息流界面

人说了什么 / AI 说了什么，按时间排列。

### B3. 说话图标移到屏幕**靠上居中**

有了消息流之后，下方留给消息列表。

### B4. 说话图标在圆内未居中 —— 已修

实测（从真机截图量像素）：字形墨迹中心相对圆心**垂直偏上 4px**
（约 1.5 逻辑像素），水平完全对齐。

原因不只是位置 —— `mic` 字形的视觉重量集中在上半部
（上方是粗胶囊，下方只有细弧和细杆），所以即使包围盒居中，看起来仍偏上。

修法：显式 `alignment: Alignment.center` + 光学补偿 `Offset(0, 2)`。
（`graphic_eq` 上下对称，不补。）

### B5. 事件日志

保留，但**上限 120 条**（环形保留最近 N 条），
UI 显示 `N / 120`，固定 240px 高、内部滚动 —— 不会无限扩展。

### B6. 页面结构

| 页面 | 内容 |
|---|---|
| 主页面 | **只有一个按钮** + 消息流 |
| 调试页 | 电平表、AEC 自测音、试听、清空队列、事件日志、AEC 实测面板 |
| 设置页 | 原来的 STT/TTS 配置 → **改为 brain API 配置** |

---

## C. 未决问题

1. **brain API 的 base URL** —— 还没给，无法实测。
   （已确认 `192.168.0.113:8082` 和 `192.168.0.102:6677` 上
   只有原来的 STT/TTS 接口，`/human-to-brain` 和 `/brain-to-human` 都是 404，
   brain 服务还没落地。）
### 已不再是问题

- ✅ `brain_id` 是人起的名字（如 `"员工3"`），不是生成的
- ✅ `/human-to-brain` 和 `/brain-to-human` 用 Bearer token 鉴权，**token 可能为空**
- ✅ 上行 Ogg Opus **16kHz**、下行 Ogg Opus **24kHz**（采样率不同）
- ✅ 载荷是 **MessagePack**（不是 multipart，也不是 JSON）
- ✅ `kind` 取值是 `empty` / `text`
- ✅ `/brain-to-human` 收到 `empty` → 立刻再发一次，不停不等
- ✅ 无协议层错误响应，只有网络与 HTTP 状态码
- ✅ 上行只收 `audio/ogg`，**没有 WAV 回落** → **minSdk 提到 29（Android 10）**
- ✅ 打断语义：文本永远进消息流，只有语音被清空；不需要 `since`

---

## D. 现有代码状态

- 项目：`~/Git/pp-friend`，Flutter，Android 原生语音引擎
- **仓库尚无任何 commit**，所有文件都是未跟踪状态
- 已实现并验证：
  - 前台服务 + 常驻通知，`foregroundServiceType=0x82`（microphone|mediaPlayback），
    通知带「停止说话」「结束」两个 action
  - AEC 配置：`AudioSource.VOICE_COMMUNICATION` + `USAGE_VOICE_COMMUNICATION` +
    `CONTENT_TYPE_SPEECH` + `MODE_IN_COMMUNICATION`，已确认 `aec` effect 挂上
  - 采集/播放跑在独立原生线程，drop-oldest 背压
  - 原生 **Opus 编码**（MediaCodec + MediaMuxer OGG）与 **Opus 解码**
    （MediaExtractor + MediaCodec），实测 1.5s 语音 48000B → 5128B
  - `BrainClient`（MessagePack），两条独立循环 + 串行上传队列
  - 消息流界面、调试面板、AEC 实测面板、事件日志
  - 清空播放队列：通知栏按钮 + 音量减键
  - 静音失效检测（`MicSilentlyDead`）、音频焦点中断处理
- 验证方式：47 个单元测试 + 一个按规范实现的假 brain
  （`tools/mock_brain.py`，含独立的手写 MessagePack 实现）端到端跑通
- 未做：
  - iOS 原生实现（Dart 契约已就绪，原生侧没写）
  - `/agent-to-brain`、`/brain-to-agent`（客户端不使用）
  - 真实 brain 的联调（base URL 还没给）

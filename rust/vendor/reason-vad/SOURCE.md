# 来源

`reason-vad` 是从下面这个路径复制过来的：

```
~/backups/projects/hola/spellbench-linux/crates/reason-vad
```

复制日期：2026-10-15

## 为什么复制而不是路径依赖

让本仓库自包含 —— 新克隆的仓库不用依赖 `~/backups` 下的那个目录就能构建。
（cargo 允许跨 workspace 的 path 依赖，因为那边把 `reason-vad` 列进了
`members`，而且它没有用 `workspace = true` 继承依赖；所以路径依赖技术上也能跑，
但任何一个 `spellbench-linux` 的改动都会静默改变这个 App 的切句行为。）

## 本地改动（相对于上游）

只有一处，为了让调试面板能观测模型判定：

- `src/vad.rs`：`StreamVad` 新增 `last_probability: f32` 字段，在
  `update_with_probability` 里每帧记录，`reset()` 清零，并暴露
  `last_probability()` 访问器。
- `src/lib.rs`：`ReasonVad` 转发一个 `pub fn last_probability(&self) -> f32`。

上游没暴露语音概率，而调 VAD 阈值时它是唯一能看的数。

## 同步方式

```bash
bash tools/sync_reason_vad.sh
```

会重新复制并保留上面的改动（脚本里会用 `git diff` 提示手工改动，需要手动重新应用）。

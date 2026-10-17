mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
mod detector;
mod ecapa;
pub mod api;
pub mod dsp;
// 不放进 `api`：frb 只扫 `api`，这里面的 `ort` 类型不该出现在生成的 Dart 里。
mod pvad;

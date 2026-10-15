//! 采样率转换和环形缓冲。
//!
//! 这两个东西放在 Rust 里而不是 Dart 里，理由很具体：
//!
//! - **重采样必须跨块保持相位连续。** 麦克风一帧 20ms 送到 Dart，如果逐帧独立
//!   重采样，48000→16000 这种整数比还算干净，但 44100→16000 每个块都会丢掉
//!   一小截相位，累积成明显的漂移。这里带着小数位置和上一块的末采样跨块推进。
//! - **环形缓冲**是为了能把 VAD 的采样下标还原成音频。`reason-vad` 只返回
//!   `start_sample`/`end_sample` 这样的偏移量，不返回音频本身。

/// 跨块相位连续的线性插值重采样。
///
/// 不是高质量重采样（降采样前没有抗混叠低通），对语音和 VAD 够用。
/// 真要提升正确做法是在原生侧做带回溯的重采样，不在这一层。
pub struct LinearResampler {
    from: u32,
    to: u32,
    /// 下一个输出采样在**源域**里的位置（以源采样为单位，从流开始算起）。
    /// 小数部分就是相位，跨块保留，这是不做逐帧独立重采样的关键。
    next_pos: f64,
    /// 已经喂进来的源采样总数。当前这一块覆盖绝对下标 `[consumed, consumed + n)`。
    consumed: usize,
    /// 上一块的最后一个源采样。用于 `next_pos` 落在上一块时的插值左端点。
    prev: i16,
}

impl LinearResampler {
    pub fn new(from: u32, to: u32) -> Self {
        Self {
            from,
            to,
            next_pos: 0.0,
            consumed: 0,
            prev: 0,
        }
    }

    /// 输入输出同率时直通 —— 设备通常就是 16k，这条路径要保持零开销。
    pub fn is_identity(&self) -> bool {
        self.from == self.to
    }

    pub fn reset(&mut self) {
        self.next_pos = 0.0;
        self.consumed = 0;
        self.prev = 0;
    }

    /// 把 `src` 追加进流，把能确定输出的采样推进 `out`。
    ///
    /// 注意：需要 `src[i+1]` 才能插值的那个位置，本次**不会**输出，会留到下一块。
    /// 这是刻意的 —— 拿不到右端点就不能插值，延后一块（约 20ms）比用错的端点强。
    pub fn process(&mut self, src: &[i16], out: &mut Vec<i16>) {
        let n = src.len();
        if n == 0 {
            return;
        }

        if self.is_identity() {
            out.extend_from_slice(src);
            self.consumed += n;
            self.prev = src[n - 1];
            return;
        }

        let step = self.from as f64 / self.to as f64;
        let end = (self.consumed + n) as i64;

        while self.next_pos + 1.0 < end as f64 {
            let idx = self.next_pos.floor() as i64;
            let (a, b) = if idx + 1 == self.consumed as i64 {
                // 位置落在上一块的最后两个采样之间。上一块只留了最后一个，
                // 右端点是当前块的头一个。
                (self.prev as f64, src[0] as f64)
            } else {
                debug_assert!(idx >= self.consumed as i64, "重采样位置落后于窗口");
                let i = (idx - self.consumed as i64) as usize;
                debug_assert!(i + 1 < n, "重采样位置超出当前块");
                (src[i] as f64, src[i + 1] as f64)
            };
            let frac = self.next_pos - idx as f64;
            let v = a + (b - a) * frac;
            out.push(v.round().clamp(-32768.0, 32767.0) as i16);
            self.next_pos += step;
        }

        self.consumed += n;
        self.prev = src[n - 1];
    }
}

/// 只保留最近 `cap` 个采样的环形缓冲，带绝对下标。
///
/// "保留最近 cap 个"就是全部的裁剪策略：满了就从最旧的丢。因为
/// `max_speech_ms` 会强制把说话切成不超过那个长度的段，只要
/// `cap > max_speech + 余量`，正在说的那一段就永远丢不掉 —— 见
/// `capacity_for()`。`dropped` 是兜底的账目，真丢到了就是配置不对。
pub struct SampleRing {
    buf: Vec<i16>,
    head: usize,
    len: usize,
    /// `buf[head]` 对应的绝对采样下标。
    start: usize,
    /// 累计被挤掉的采样数。
    dropped: usize,
    /// 历史最大占用。调容量时用得上。
    peak: usize,
}

impl SampleRing {
    pub fn new(capacity: usize) -> Self {
        let cap = capacity.max(1);
        Self {
            buf: vec![0; cap],
            head: 0,
            len: 0,
            start: 0,
            dropped: 0,
            peak: 0,
        }
    }

    pub fn capacity(&self) -> usize {
        self.buf.len()
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// 缓冲区里第一个采样对应的绝对下标。
    pub fn start(&self) -> usize {
        self.start
    }

    /// 下一个将要写入的绝对下标（= 已见过的采样总数）。
    pub fn end(&self) -> usize {
        self.start + self.len
    }

    pub fn dropped(&self) -> usize {
        self.dropped
    }

    pub fn peak(&self) -> usize {
        self.peak
    }

    pub fn reset(&mut self) {
        self.head = 0;
        self.len = 0;
        self.start = 0;
        self.dropped = 0;
        self.peak = 0;
    }

    pub fn push_slice(&mut self, src: &[i16]) {
        let cap = self.buf.len();
        for &s in src {
            if self.len == cap {
                // 满了：丢最旧的
                self.head = (self.head + 1) % cap;
                self.start += 1;
                self.len -= 1;
                self.dropped += 1;
            }
            let idx = (self.head + self.len) % cap;
            self.buf[idx] = s;
            self.len += 1;
        }
        if self.len > self.peak {
            self.peak = self.len;
        }
    }

    /// 取出绝对下标 `[from, to)` 的采样。越界部分夹到现有范围内。
    ///
    /// 返回的 `(样本, 是否被夹过)` —— 夹过说明这一段的开头已经被挤掉了，
    /// 调用方据此置 `truncated`。
    pub fn slice(&self, from: usize, to: usize) -> (Vec<i16>, bool) {
        let lo = from.max(self.start);
        let hi = to.min(self.end()).max(lo);
        let truncated = lo != from;

        let lo_rel = lo - self.start;
        let n = hi - lo;
        let mut out = Vec::with_capacity(n);
        for i in 0..n {
            out.push(self.buf[(self.head + lo_rel + i) % self.buf.len()]);
        }
        (out, truncated)
    }
}

/// 环形缓冲该开多大：必须装得下一整段"正在说"的音频。
pub fn capacity_for(cfg: &crate::api::vad::SegmenterConfig, sample_rate: u32) -> usize {
    // 说话最长 max_speech_ms 就会被 flush 强制切段，所以活动段不会超过它。
    // 再多留 2 倍 speech_pad 和 1 秒余量，`truncated` 就成了永远不该出现的兜底。
    let ms = cfg
        .ring_capacity_ms
        .max(cfg.max_speech_ms + 2 * cfg.speech_pad_ms + 1000);
    (ms as u64 * sample_rate as u64 / 1000) as usize
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 内容可预测的测试信号：线性锯齿，任何位置都能反推期望值。
    fn ramp(n: usize, start: usize) -> Vec<i16> {
        (0..n)
            .map(|i| (((start + i) * 37) % 20000) as i16 - 10000)
            .collect()
    }

    fn resample_chunked(from: u32, to: u32, src: &[i16], chunk: usize) -> Vec<i16> {
        let mut r = LinearResampler::new(from, to);
        let mut out = Vec::new();
        for c in src.chunks(chunk) {
            r.process(c, &mut out);
        }
        out
    }

    fn resample_whole(from: u32, to: u32, src: &[i16]) -> Vec<i16> {
        let mut r = LinearResampler::new(from, to);
        let mut out = Vec::new();
        r.process(src, &mut out);
        out
    }

    #[test]
    fn identity_is_passthrough() {
        let src = ramp(1000, 0);
        let mut r = LinearResampler::new(16000, 16000);
        assert!(r.is_identity());
        let mut out = Vec::new();
        r.process(&src, &mut out);
        assert_eq!(out, src);
    }

    #[test]
    fn chunked_matches_whole_48k() {
        let src = ramp(48000, 0);
        let whole = resample_whole(48000, 16000, &src);
        for chunk in [320, 480, 960, 1920, 4096] {
            let chunked = resample_chunked(48000, 16000, &src, chunk);
            assert_eq!(chunked, whole, "48000→16000 分块 {chunk} 和整块不一致");
        }
        assert_eq!(whole.len(), 16000);
    }

    #[test]
    fn chunked_matches_whole_44k1() {
        // 非整数比，逐帧独立重采样会在这里累积漂移。
        let src = ramp(44100, 0);
        let whole = resample_whole(44100, 16000, &src);
        for chunk in [320, 441, 882, 4410, 4001] {
            let chunked = resample_chunked(44100, 16000, &src, chunk);
            assert_eq!(chunked, whole, "44100→16000 分块 {chunk} 和整块不一致");
        }
        assert_eq!(whole.len(), 16000);
    }

    #[test]
    fn chunked_matches_whole_8k_upsample() {
        let src = ramp(8000, 0);
        let whole = resample_whole(8000, 16000, &src);
        for chunk in [160, 320, 777] {
            let chunked = resample_chunked(8000, 16000, &src, chunk);
            assert_eq!(chunked, whole, "8000→16000 分块 {chunk} 和整块不一致");
        }
        // 升采样时最后两个输出位置需要 src[8000] 才能插值，而输入只有 0..8000。
        // 流式场景下它们会在下一块被产出，所以这里允许最多 2 个的滞后。
        assert!((15998..=16000).contains(&whole.len()), "{}", whole.len());
    }

    #[test]
    fn resample_preserves_constant_signal() {
        let src = vec![1234i16; 48000];
        let out = resample_chunked(48000, 16000, &src, 960);
        assert!(out.iter().all(|&v| v == 1234));
    }

    #[test]
    fn resample_reset_restarts_stream() {
        let src = ramp(960, 0);
        let mut r = LinearResampler::new(48000, 16000);
        let mut first = Vec::new();
        r.process(&src, &mut first);
        let mut second = Vec::new();
        r.process(&src, &mut second);
        assert!(first.len() <= 320);
        // 第二块是紧接着的流，位置继续往前走
        assert!(second.is_empty() || second.len() == 320);
        r.reset();
        let mut third = Vec::new();
        r.process(&src, &mut third);
        assert_eq!(third, first);
    }

    #[test]
    fn ring_slices_by_absolute_index() {
        let mut ring = SampleRing::new(100);
        let a = ramp(60, 0);
        let b = ramp(60, 60);
        ring.push_slice(&a);
        ring.push_slice(&b);

        assert_eq!(ring.start(), 20); // 前 20 个被挤掉了
        assert_eq!(ring.end(), 120);
        assert_eq!(ring.len(), 100); // 只留最近 100 个
        assert_eq!(ring.dropped(), 20);

        let (s, truncated) = ring.slice(20, 40);
        assert!(!truncated);
        assert_eq!(s, ramp(60, 0)[20..40].to_vec());

        let (s, truncated) = ring.slice(60, 80);
        assert!(!truncated);
        assert_eq!(s, ramp(60, 60)[0..20].to_vec());
    }

    #[test]
    fn ring_reports_truncation_when_start_evicted() {
        let mut ring = SampleRing::new(50);
        ring.push_slice(&ramp(200, 0));
        let (s, truncated) = ring.slice(10, 30);
        assert!(truncated, "起点已被挤掉，必须报出来");
        assert_eq!(ring.start(), 150);
        assert!(s.is_empty(), "整段都被挤掉了");

        // 部分重叠：起点还在缓冲里（190 >= start 150），只把尾巴夹到 200
        let (s, truncated) = ring.slice(190, 210);
        assert!(!truncated, "起点没丢，不该报截断");
        assert_eq!(s, ramp(200, 0)[190..200].to_vec());
    }

    #[test]
    fn ring_slice_degenerate_ranges_are_safe() {
        let mut ring = SampleRing::new(10);
        ring.push_slice(&ramp(4, 0));
        let (s, _) = ring.slice(10, 2); // from > to
        assert!(s.is_empty());
        let (s, _) = ring.slice(100, 200); // 完全在范围外
        assert!(s.is_empty());
    }

    #[test]
    fn ring_wraps_correctly_across_many_pushes() {
        let mut ring = SampleRing::new(7);
        for i in 0..100 {
            ring.push_slice(&[i as i16]);
        }
        let (s, truncated) = ring.slice(93, 100);
        assert!(!truncated);
        assert_eq!(s, (93..100).map(|i| i as i16).collect::<Vec<_>>());
        assert_eq!(ring.dropped(), 93);
    }
}

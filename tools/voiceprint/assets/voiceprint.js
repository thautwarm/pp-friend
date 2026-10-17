/* PP Friend 声纹注册工具逻辑。
 * 由 tools/voiceprint/index.html 的内联脚本迁移而来：
 * 行为保持一致，所有界面文案走 PP_I18N 字典，路径改为相对站点根目录
 * （本页位于 enroll/，模型与 vendor 在站点根的 models/ 和 vendor/ 下）。
 */
(() => {
  "use strict";

  const I = window.PP_I18N;
  const t = I.t;

  const SR = 16000;
  const WIN_SECONDS = 3;
  const MIN_SECONDS = 0.5;
  const MAX_RECORD_SECONDS = 30;
  const EMB_DIM = 192;
  const WIN = WIN_SECONDS * SR;
  const MIN = MIN_SECONDS * SR;
  // onnxruntime-web 版本固定为 1.30.0；站点根目录下应有
  // vendor/onnxruntime-web/dist/（js 和 wasm 必须同一个版本）。

  const $ = (id) => document.getElementById(id);
  const el = {
    modelStatus: $("modelStatus"),
    modelProgressRow: $("modelProgressRow"),
    modelProgress: $("modelProgress"),
    modelProgressText: $("modelProgressText"),
    modelPickerRow: $("modelPickerRow"),
    modelFile: $("modelFile"),
    audioStatus: $("audioStatus"),
    drop: $("drop"),
    audioFile: $("audioFile"),
    micBtn: $("micBtn"),
    micTimer: $("micTimer"),
    audioInfo: $("audioInfo"),
    computeRow: $("computeRow"),
    computeProgress: $("computeProgress"),
    computeProgressText: $("computeProgressText"),
    resultCard: $("resultCard"),
    resultPill: $("resultPill"),
    windowInfo: $("windowInfo"),
    consistency: $("consistency"),
    minCos: $("minCos"),
    rawNorm: $("rawNorm"),
    windowCount: $("windowCount"),
    strip: $("strip"),
    values: $("values"),
    dlF32: $("dlF32"),
    dlJson: $("dlJson"),
    error: $("error"),
  };

  const state = {
    session: null,
    inputName: "wav",
    outputName: "emb",
    samples: null,
    audioMeta: null,
    result: null,
    busy: false,
    recording: false,
    // 以下用于语言切换时重渲染动态文案。
    modelStatus: { key: "vp.model.loading", kind: "pending" },
    audioStatus: { key: "vp.audio.wait", kind: "" },
    modelProgress: { ratio: 0, key: "vp.progress.wait", vars: null },
    computeProgress: { ratio: 0, key: "vp.audio.infer", vars: null },
    error: null, // { key, vars, hintKey }
  };

  let sharedCtx = null;
  let recorder = null;
  let recordChunks = [];
  let recordStream = null;
  let recordStart = 0;
  let recordTimer = 0;
  let recordAutoStop = 0;

  // ------------------------------------------------------------------
  // 基础 UI
  // ------------------------------------------------------------------
  function setModelStatus(key, kind, vars) {
    state.modelStatus = { key, kind, vars };
    el.modelStatus.textContent = t(key, vars);
    el.modelStatus.className = "pill" + (kind ? " " + kind : "");
  }
  function setAudioStatus(key, kind, vars) {
    state.audioStatus = { key, kind, vars };
    el.audioStatus.textContent = t(key, vars);
    el.audioStatus.className = "pill" + (kind ? " " + kind : "");
  }
  function setProgress(bar, textEl, ratio, key, vars, store) {
    const pct = Math.max(0, Math.min(1, ratio)) * 100;
    bar.style.width = pct.toFixed(1) + "%";
    if (key != null) {
      textEl.textContent = t(key, vars);
      if (store) {
        store.ratio = ratio; store.key = key; store.vars = vars || null;
      }
    }
  }
  function setModelProgress(ratio, key, vars) {
    setProgress(el.modelProgress, el.modelProgressText, ratio, key, vars,
      state.modelProgress);
  }
  function setComputeProgress(ratio, key, vars) {
    setProgress(el.computeProgress, el.computeProgressText, ratio, key, vars,
      state.computeProgress);
  }
  function showError(key, vars, hintKey) {
    state.error = { key, vars: vars || null, hintKey: hintKey || null };
    el.error.hidden = false;
    el.error.textContent = t(key, vars) +
      (hintKey ? t("vp.err.sep") + t(hintKey) : "");
  }
  function clearError() {
    state.error = null;
    el.error.hidden = true;
    el.error.textContent = "";
  }

  // ------------------------------------------------------------------
  // onnxruntime-web
  // ------------------------------------------------------------------
  // 版本写死：js 和 wasm 必须同一个版本，换一个就得一起换。
  const ORT_VERSION = "1.30.0";
  const ORT_CDN_BASE = "https://cdn.jsdelivr.net/npm/onnxruntime-web@" +
    ORT_VERSION + "/dist/";
  // 必须是绝对 URL：ORT 会用动态 import() 去加载 .mjs，
  // 相对路径会被当成裸模块名，解析失败。
  // 本页在 enroll/ 下，vendor 在站点根目录，所以是 ../vendor/。
  const ORT_LOCAL_BASE = new URL(
    "../vendor/onnxruntime-web/dist/", document.baseURI).href;
  const MODEL_URL = "../models/ecapa.onnx";

  function loadScript(src, timeoutMs) {
    return new Promise((resolve, reject) => {
      const script = document.createElement("script");
      const timer = setTimeout(() => {
        script.remove();
        reject(new Error(t("vp.log.scriptTimeout")));
      }, timeoutMs);
      script.src = src;
      script.onload = () => { clearTimeout(timer); resolve(); };
      script.onerror = () => {
        clearTimeout(timer);
        script.remove();
        reject(new Error(t("vp.log.scriptFail")));
      };
      document.head.appendChild(script);
    });
  }

  // 只探一下 wasm 在不在。必须先探再加载 js：js 一旦跑起来 ort 就注册了，
  // 这时候再换 wasmPaths 重来会留下半初始化的状态。
  async function wasmReachable(url, timeoutMs) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetch(url, {
        method: "HEAD",
        signal: controller.signal,
      });
      return response.ok;
    } catch (_) {
      return false;
    } finally {
      clearTimeout(timer);
    }
  }

  // 线上：先 CDN，失败退本地。本地开发：先本地，省得每次都要联网。
  async function setupOrt() {
    const isFile = location.protocol === "file:";
    const isLocalDev =
      /^(localhost|127\.0\.0\.1|\[::1\]|0\.0\.0\.0)?$/.test(location.hostname);
    // file:// 下浏览器禁止 fetch 同目录的 wasm，本地 vendor 用不了，
    // 所以先走 CDN；本地开发（localhost）反过来，先本地。
    const bases = isFile
      ? [ORT_CDN_BASE, ORT_LOCAL_BASE]
      : isLocalDev
        ? [ORT_LOCAL_BASE, ORT_CDN_BASE]
        : [ORT_CDN_BASE, ORT_LOCAL_BASE];
    for (const base of bases) {
      const fromCdn = base === ORT_CDN_BASE;
      try {
        if (fromCdn) {
          const ok = await wasmReachable(
            base + "ort-wasm-simd-threaded.wasm", 6000);
          if (!ok) throw new Error(t("vp.log.wasmUnreachable"));
        }
        if (!window.ort) {
          await loadScript(base + "ort.wasm.min.js", fromCdn ? 8000 : 4000);
        }
        if (!window.ort) throw new Error(t("vp.log.ortNotRegistered"));
        ort.env.wasm.wasmPaths = base;
        // 单线程：不需要 SharedArrayBuffer / COOP-COEP，
        // python -m http.server 也能直接跑。
        ort.env.wasm.numThreads = 1;
        ort.env.logLevel = "error";
        state.ortSource = fromCdn ? "cdn" : "local";
        return true;
      } catch (err) {
        console.warn(t("vp.log.ortFail", {
          src: t(fromCdn ? "vp.src.cdn" : "vp.src.local"),
          detail: err && err.message ? err.message : String(err),
        }));
      }
    }
    return false;
  }

  async function fetchWithProgress(url, barSetter) {
    const response = await fetch(url);
    if (!response.ok) throw new Error("HTTP " + response.status);
    const total = Number(response.headers.get("content-length")) || 0;
    if (!response.body) return await response.arrayBuffer();

    const reader = response.body.getReader();
    const chunks = [];
    let received = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      received += value.length;
      if (total > 0) {
        barSetter(received / total, "vp.progress.download",
          { pct: Math.round(received / total * 100) });
      } else {
        barSetter(0, "vp.progress.mib",
          { mib: (received / 1024 / 1024).toFixed(1) });
      }
    }
    const bytes = new Uint8Array(received);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    return bytes.buffer;
  }

  async function createSession(buffer) {
    if (!window.ort) {
      throw new Error(t("vp.err.engineMissing"));
    }
    setModelStatus("vp.model.loading", "pending");
    setModelProgress(0.05, "vp.progress.load");
    const session = await ort.InferenceSession.create(buffer, {
      executionProviders: ["wasm"],
      graphOptimizationLevel: "all",
    });
    state.session = session;
    state.inputName = session.inputNames.includes("wav") ? "wav" : session.inputNames[0];
    state.outputName = session.outputNames.includes("emb") ? "emb" : session.outputNames[0];
    if (!session.inputNames.includes("wav") || !session.outputNames.includes("emb")) {
      showError("vp.err.ioNames");
    }
    setModelStatus("vp.model.ready", "ok");
    setModelProgress(1, "vp.progress.modelReady");
    el.modelProgressRow.classList.add("hidden");
    el.modelPickerRow.classList.add("hidden");
    maybeCompute();
  }

  async function initModel() {
    clearError();
    try {
      setModelStatus("vp.model.loading", "pending");
      setModelProgress(0, "vp.progress.connect");
      const buffer = await fetchWithProgress(MODEL_URL, setModelProgress);
      setModelProgress(0.02, "vp.progress.parse");
      await createSession(buffer);
    } catch (err) {
      setModelStatus("vp.model.failed", "error");
      setModelProgress(0, "vp.progress.autoFail");
      el.modelPickerRow.classList.remove("hidden");
      // 不一定是致命错误：用户还可以手动选择模型文件。
      // file:// 下这是必经之路：浏览器不允许 fetch 同目录的 onnx。
      const hintKey = location.protocol === "file:"
        ? "vp.err.hintFile"
        : "vp.err.hintHttp";
      showError("vp.err.modelLoad",
        { detail: err && err.message ? err.message : String(err) }, hintKey);
    }
  }

  el.modelFile.addEventListener("change", async () => {
    const file = el.modelFile.files && el.modelFile.files[0];
    if (!file) return;
    clearError();
    try {
      setModelProgress(0.1, "vp.progress.load");
      const buffer = await file.arrayBuffer();
      await createSession(buffer);
    } catch (err) {
      setModelStatus("vp.model.failed", "error");
      showError("vp.err.modelLoad",
        { detail: err && err.message ? err.message : String(err) });
    }
  });

  // ------------------------------------------------------------------
  // 音频解码 / 下混 / 重采样
  // ------------------------------------------------------------------
  function getAudioContext() {
    if (!sharedCtx) {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) throw new Error(t("vp.err.micUnsupported"));
      sharedCtx = new AC();
    }
    return sharedCtx;
  }

  async function decodeTo16k(file) {
    const arrayBuffer = await file.arrayBuffer();
    let decoded = null;
    let ctx = null;

    // 优先直接在一个 16 kHz 的 OfflineAudioContext 里解码：
    // decodeAudioData 会用浏览器原生重采样器一步转到上下文采样率，
    // 避免 16k -> 48k -> 16k 的往返（那会白白损失高频细节）。
    try {
      const decodeCtx = new OfflineAudioContext(1, 1, SR);
      decoded = await decodeCtx.decodeAudioData(arrayBuffer.slice(0));
    } catch (_) {
      // 少数浏览器不支持在 OfflineAudioContext 上解码；退回普通 AudioContext。
    }

    if (!decoded) {
      ctx = getAudioContext();
      if (ctx.state === "suspended") {
        try { await ctx.resume(); } catch (_) { /* 用户手势之外可能失败 */ }
      }
      try {
        decoded = await ctx.decodeAudioData(arrayBuffer.slice(0));
      } catch (err) {
        throw new Error(t("vp.err.decode"));
      }
    }
    if (!decoded || !decoded.length) throw new Error(t("vp.err.audioEmpty"));

    // 1) 手动下混成单声道（不用 OfflineAudioContext 的隐式混音规则）。
    const mono = new Float32Array(decoded.length);
    const channels = decoded.numberOfChannels;
    for (let c = 0; c < channels; c++) {
      const data = decoded.getChannelData(c);
      for (let i = 0; i < data.length; i++) mono[i] += data[i];
    }
    if (channels > 1) {
      for (let i = 0; i < mono.length; i++) mono[i] /= channels;
    }

    // 2) 若解码器没有给出 16 kHz（回退路径），再用 OfflineAudioContext
    //    的原生重采样器转一次。正常路径下这里已经是 16 kHz。
    let samples;
    if (decoded.sampleRate === SR) {
      samples = mono;
    } else {
      const targetLength = Math.max(1, Math.round(decoded.duration * SR));
      const offline = new OfflineAudioContext(1, targetLength, SR);
      const source = offline.createBufferSource();
      const monoBuffer = (ctx || getAudioContext()).createBuffer(
        1, mono.length, decoded.sampleRate);
      monoBuffer.copyToChannel(mono, 0);
      source.buffer = monoBuffer;
      source.connect(offline.destination);
      source.start(0);
      const rendered = await offline.startRendering();
      samples = new Float32Array(rendered.length);
      samples.set(rendered.getChannelData(0));
    }

    return {
      samples,
      duration: decoded.duration,
      sourceChannels: channels,
      resampled: decoded.sampleRate !== SR,
    };
  }

  function planWindows(n) {
    if (n < MIN) return null;
    if (n <= WIN) return [{ start: 0, end: n }];
    const windows = [];
    let start = 0;
    while (start + WIN <= n) {
      windows.push({ start, end: start + WIN });
      start += WIN;
    }
    // 最后一段不足 3 秒：如果至少 0.5 秒，就向前重叠成一个完整 3 秒窗。
    if (n - start >= MIN) {
      windows.push({ start: n - WIN, end: n });
    }
    return windows;
  }

  function setBusy(busy) {
    state.busy = busy;
    el.micBtn.disabled = busy || state.recording;
    el.audioFile.disabled = busy;
  }

  async function handleAudioFile(file) {
    if (!file) return;
    if (state.busy) return;
    clearError();
    resetResult();
    setAudioStatus("vp.audio.decoding", "pending");
    try {
      const decoded = await decodeTo16k(file);
      if (decoded.samples.length < MIN) {
        throw new Error(t("vp.err.audioShort"));
      }
      state.samples = decoded.samples;
      state.audioMeta = { name: file.name || "microphone", ...decoded };
      setAudioStatus("vp.audio.ready", "ok");
      renderAudioInfo();
      await maybeCompute();
    } catch (err) {
      state.samples = null;
      state.audioMeta = null;
      el.audioInfo.textContent = "";
      el.resultCard.hidden = true;
      setAudioStatus("vp.audio.bad", "error");
      showError("vp.err.audioProcess",
        { detail: err && err.message ? err.message : String(err) });
    }
  }

  function renderAudioInfo() {
    const meta = state.audioMeta;
    if (!meta) { el.audioInfo.textContent = ""; return; }
    const windows = planWindows(meta.samples.length) || [];
    el.audioInfo.innerHTML = t("vp.audioInfo", {
      name: escapeHtml(meta.name),
      s: t("vp.seconds", { s: meta.duration.toFixed(2) }),
      n: t("vp.windows", { n: windows.length }),
    });
  }

  // ------------------------------------------------------------------
  // 推理
  // ------------------------------------------------------------------
  async function maybeCompute() {
    if (!state.session || !state.samples || state.busy) return;
    await computeEmbedding();
  }

  async function computeEmbedding() {
    const windows = planWindows(state.samples.length);
    if (!windows || !windows.length) {
      showError("vp.err.audioShort");
      return;
    }
    setBusy(true);
    el.computeRow.classList.remove("hidden");
    el.resultCard.hidden = true;
    setAudioStatus("vp.audio.infer", "pending");
    setComputeProgress(0, "vp.infer.prepare");

    try {
      const raw = [];
      for (let i = 0; i < windows.length; i++) {
        const win = windows[i];
        const data = state.samples.slice(win.start, win.end);
        const tensor = new ort.Tensor("float32", data, [1, data.length]);
        const feeds = {};
        feeds[state.inputName] = tensor;
        const outputs = await state.session.run(feeds);
        const out = outputs[state.outputName];
        if (!out || !out.data || out.data.length !== EMB_DIM) {
          throw new Error(t("vp.err.outputDim"));
        }
        raw.push(Float32Array.from(out.data));
        setComputeProgress((i + 1) / windows.length, "vp.infer.progress",
          { i: i + 1, n: windows.length });
        await new Promise((resolve) => setTimeout(resolve, 0));
      }

      // 平均原始 embedding，再 L2 归一化。
      const mean = new Float64Array(EMB_DIM);
      for (const emb of raw) {
        for (let i = 0; i < EMB_DIM; i++) mean[i] += emb[i];
      }
      for (let i = 0; i < EMB_DIM; i++) mean[i] /= raw.length;

      let rawNorm = 0;
      for (let i = 0; i < EMB_DIM; i++) rawNorm += mean[i] * mean[i];
      rawNorm = Math.sqrt(rawNorm);
      if (!Number.isFinite(rawNorm) || rawNorm < 1e-8) {
        throw new Error(t("vp.err.noEmbedding"));
      }
      const normed = new Float32Array(EMB_DIM);
      for (let i = 0; i < EMB_DIM; i++) normed[i] = mean[i] / rawNorm;

      const cosines = raw.map((emb) => cosineToMean(emb, mean));
      state.result = {
        normed,
        rawNorm,
        cosines,
        windows,
        rawWindowNorm: raw.map(normOf),
        duration: state.samples.length / SR,
      };
      renderResult(state.result);
      setAudioStatus("vp.audio.done", "ok");
      setComputeProgress(1, "vp.audio.done");
    } catch (err) {
      el.resultCard.hidden = true;
      setAudioStatus("vp.audio.failed", "error");
      showError("vp.err.compute",
        { detail: err && err.message ? err.message : String(err) });
    } finally {
      setBusy(false);
      setTimeout(() => { el.computeRow.classList.add("hidden"); }, 600);
    }
  }

  function normOf(vec) {
    let sum = 0;
    for (let i = 0; i < vec.length; i++) sum += vec[i] * vec[i];
    return Math.sqrt(sum);
  }
  function cosineToMean(vec, mean) {
    let dot = 0, na = 0, nb = 0;
    for (let i = 0; i < vec.length; i++) {
      dot += vec[i] * mean[i];
      na += vec[i] * vec[i];
      nb += mean[i] * mean[i];
    }
    const denom = Math.sqrt(na) * Math.sqrt(nb);
    return denom > 0 ? dot / denom : NaN;
  }

  // ------------------------------------------------------------------
  // 结果渲染
  // ------------------------------------------------------------------
  function mix(a, b, t_) {
    return [
      Math.round(a[0] + (b[0] - a[0]) * t_),
      Math.round(a[1] + (b[1] - a[1]) * t_),
      Math.round(a[2] + (b[2] - a[2]) * t_),
    ];
  }

  function heatColor(value, maxAbs) {
    const dark = window.matchMedia &&
      window.matchMedia("(prefers-color-scheme: dark)").matches;
    const neg = dark ? [57, 135, 229] : [42, 120, 214];
    const mid = dark ? [56, 56, 53] : [240, 239, 236];
    const pos = dark ? [230, 103, 103] : [227, 73, 72];
    const t_ = Math.max(-1, Math.min(1, value / maxAbs));
    const rgb = t_ < 0 ? mix(mid, neg, -t_) : mix(mid, pos, t_);
    return "rgb(" + rgb[0] + "," + rgb[1] + "," + rgb[2] + ")";
  }

  /// 开始一次新的录音/选文件时，先把上一次的结果彻底作废。
  /// 否则新录音失败时，下载按钮仍然可用，会把上一段声音的声纹
  /// 当成这一次的结果导出去（已经踩过一次：两个人的文件字节相同）。
  function resetResult() {
    state.result = null;
    el.resultCard.hidden = true;
    el.consistency.textContent = "";
    el.minCos.textContent = "—";
    el.windowCount.textContent = "—";
    el.rawNorm.textContent = "—";
    el.dlF32.disabled = true;
    el.dlJson.disabled = true;
  }

  function renderResult(result) {
    const minCos = Math.min(...result.cosines);
    const multipleWindows = result.cosines.length > 1;

    el.resultCard.hidden = false;
    el.rawNorm.textContent = result.rawNorm.toFixed(4);
    el.windowCount.textContent = String(result.windows.length);
    el.minCos.textContent = multipleWindows ? minCos.toFixed(4) : "—";
    el.resultPill.textContent = t("vp.result.done");
    el.resultPill.className = "pill ok";

    el.windowInfo.innerHTML = t("vp.result.duration",
      { s: t("vp.seconds", { s: result.duration.toFixed(2) }) });

    // 一致性：只有多窗口时才有意义。
    el.consistency.textContent = "";
    if (multipleWindows) {
      const chips = document.createElement("div");
      chips.className = "chips";
      result.cosines.forEach((cos, i) => {
        const chip = document.createElement("span");
        chip.className = "chip " + (cos >= 0.8 ? "good" : "warn");
        chip.textContent = t("vp.chip", { i: i + 1, cos: cos.toFixed(4) });
        chip.title = t("vp.chip.title");
        chips.appendChild(chip);
      });
      el.consistency.appendChild(chips);

      if (minCos < 0.8) {
        const warn = document.createElement("div");
        warn.className = "warn-note";
        warn.innerHTML = t("vp.consistency.low", { cos: minCos.toFixed(3) });
        el.consistency.appendChild(warn);
      } else {
        const note = document.createElement("div");
        note.className = "ok-note";
        note.textContent = t("vp.consistency.ok", { cos: minCos.toFixed(3) });
        el.consistency.appendChild(note);
      }
    }

    // 热力条
    let maxAbs = 0;
    for (let i = 0; i < result.normed.length; i++) {
      maxAbs = Math.max(maxAbs, Math.abs(result.normed[i]));
    }
    maxAbs = Math.max(maxAbs, 0.01);
    el.strip.textContent = "";
    const frag = document.createDocumentFragment();
    for (let i = 0; i < result.normed.length; i++) {
      const v = result.normed[i];
      const cell = document.createElement("div");
      cell.className = "cell";
      cell.style.background = heatColor(v, maxAbs);
      cell.title = "#" + i + "  " + v.toFixed(6);
      cell.setAttribute("aria-label",
        t("vp.cell.aria", { i: i, v: v.toFixed(6) }));
      frag.appendChild(cell);
    }
    el.strip.appendChild(frag);

    // 数值表
    el.values.textContent = "";
    const valuesFrag = document.createDocumentFragment();
    for (let i = 0; i < result.normed.length; i++) {
      const row = document.createElement("span");
      const idx = document.createElement("i");
      idx.textContent = String(i).padStart(3, "0") + "  ";
      row.appendChild(idx);
      row.appendChild(document.createTextNode(result.normed[i].toFixed(6)));
      valuesFrag.appendChild(row);
    }
    el.values.appendChild(valuesFrag);

    el.dlF32.disabled = false;
    el.dlJson.disabled = false;
  }

  // ------------------------------------------------------------------
  // 下载
  // ------------------------------------------------------------------
  function download(blob, filename) {
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 2000);
  }

  el.dlF32.addEventListener("click", () => {
    const result = state.result;
    if (!result) return;
    const buffer = new ArrayBuffer(EMB_DIM * 4);
    const view = new DataView(buffer);
    for (let i = 0; i < EMB_DIM; i++) {
      view.setFloat32(i * 4, result.normed[i], true); // little-endian
    }
    download(new Blob([buffer], { type: "application/octet-stream" }), "spkemb.f32");
  });

  el.dlJson.addEventListener("click", () => {
    const result = state.result;
    if (!result) return;
    const payload = {
      format: "spkemb-v1",
      dim: EMB_DIM,
      dtype: "float32",
      endianness: "little",
      normalized: true,
      l2_norm_before_normalization: result.rawNorm,
      model: "FireRedTeam/FireRedChat-pvad spkrec-ecapa-voxceleb (ECAPA-TDNN)",
      sample_rate: SR,
      window_seconds: WIN_SECONDS,
      duration_seconds: result.duration,
      window_count: result.windows.length,
      window_ranges_seconds: result.windows.map((w) => [
        Number((w.start / SR).toFixed(4)),
        Number((w.end / SR).toFixed(4)),
      ]),
      window_cosine_to_mean: result.cosines,
      embedding: Array.from(result.normed, (v) => Number(v.toFixed(9))),
    };
    download(
      new Blob([JSON.stringify(payload, null, 2) + "\n"], { type: "application/json" }),
      "spkemb.json"
    );
  });

  // ------------------------------------------------------------------
  // 文件选择 / 拖放
  // ------------------------------------------------------------------
  el.drop.addEventListener("click", () => el.audioFile.click());
  el.drop.addEventListener("keydown", (event) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      el.audioFile.click();
    }
  });
  el.audioFile.addEventListener("change", () => {
    const file = el.audioFile.files && el.audioFile.files[0];
    el.audioFile.value = "";
    if (file) handleAudioFile(file);
  });
  ["dragenter", "dragover"].forEach((type) => {
    el.drop.addEventListener(type, (event) => {
      event.preventDefault();
      el.drop.classList.add("over");
    });
  });
  ["dragleave", "dragend"].forEach((type) => {
    el.drop.addEventListener(type, () => el.drop.classList.remove("over"));
  });
  el.drop.addEventListener("drop", (event) => {
    event.preventDefault();
    el.drop.classList.remove("over");
    const file = event.dataTransfer && event.dataTransfer.files &&
      event.dataTransfer.files[0];
    if (file) handleAudioFile(file);
  });
  window.addEventListener("dragover", (event) => event.preventDefault());
  window.addEventListener("drop", (event) => event.preventDefault());

  // ------------------------------------------------------------------
  // 麦克风录音
  // ------------------------------------------------------------------
  function pickMime() {
    if (!window.MediaRecorder) return "";
    const candidates = [
      "audio/webm;codecs=opus",
      "audio/webm",
      "audio/ogg;codecs=opus",
      "audio/mp4",
    ];
    for (const mime of candidates) {
      try {
        if (MediaRecorder.isTypeSupported(mime)) return mime;
      } catch (_) { /* 忽略 */ }
    }
    return "";
  }

  function updateMicTimer() {
    const seconds = (performance.now() - recordStart) / 1000;
    el.micTimer.innerHTML = '<span class="mic-dot"></span>' +
      escapeHtml(t("vp.mic.recording", { s: seconds.toFixed(1) }));
    if (seconds >= MAX_RECORD_SECONDS - 0.05) stopRecording();
  }

  async function startRecording() {
    clearError();
    resetResult();
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      showError("vp.err.micUnsupported");
      return;
    }
    try {
      recordStream = await navigator.mediaDevices.getUserMedia({
        audio: {
          channelCount: 1,
          echoCancellation: false,
          noiseSuppression: false,
          autoGainControl: false,
        },
      });
      const mime = pickMime();
      recorder = mime ? new MediaRecorder(recordStream, { mimeType: mime })
                      : new MediaRecorder(recordStream);
      recordChunks = [];
      recorder.addEventListener("dataavailable", (event) => {
        if (event.data && event.data.size) recordChunks.push(event.data);
      });
      recorder.addEventListener("stop", async () => {
        const mimeType = recorder.mimeType || "audio/webm";
        const blob = new Blob(recordChunks, { type: mimeType });
        recordChunks = [];
        if (recordStream) {
          recordStream.getTracks().forEach((track) => track.stop());
          recordStream = null;
        }
        clearInterval(recordTimer);
        clearTimeout(recordAutoStop);
        state.recording = false;
        el.micBtn.disabled = false;
        el.micBtn.textContent = t("vp.mic.start");
        el.micTimer.textContent = "";
        el.audioFile.disabled = false;
        if (blob.size === 0) {
          showError("vp.err.noRecording");
          return;
        }
        await handleAudioFile(new File([blob], "microphone.webm", { type: mimeType }));
      });

      recordStart = performance.now();
      state.recording = true;
      el.micBtn.textContent = t("vp.mic.stop");
      el.micBtn.disabled = false;
      el.audioFile.disabled = true;
      recordTimer = setInterval(updateMicTimer, 100);
      recordAutoStop = setTimeout(stopRecording, MAX_RECORD_SECONDS * 1000);
      recorder.start();
    } catch (err) {
      showError("vp.err.mic",
        { detail: err && err.message ? err.message : String(err) });
      if (recordStream) {
        recordStream.getTracks().forEach((track) => track.stop());
        recordStream = null;
      }
      state.recording = false;
      el.micBtn.disabled = false;
      el.micBtn.textContent = t("vp.mic.start");
      el.audioFile.disabled = false;
    }
  }

  function stopRecording() {
    if (recorder && recorder.state === "recording") {
      recorder.stop();
    }
  }

  el.micBtn.addEventListener("click", () => {
    if (state.recording) stopRecording();
    else startRecording();
  });

  // ------------------------------------------------------------------
  // 小工具
  // ------------------------------------------------------------------
  function escapeHtml(text) {
    return String(text)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  // 暗色模式切换时重绘热力条，保证颜色继续按当前表面取值。
  if (window.matchMedia) {
    const query = window.matchMedia("(prefers-color-scheme: dark)");
    const rerender = () => { if (state.result) renderResult(state.result); };
    if (query.addEventListener) query.addEventListener("change", rerender);
    else if (query.addListener) query.addListener(rerender);
  }

  // 语言切换：静态部分由 PP_I18N.apply 处理，这里重渲染动态部分。
  I.onChange(() => {
    setModelStatus(state.modelStatus.key, state.modelStatus.kind,
      state.modelStatus.vars);
    setAudioStatus(state.audioStatus.key, state.audioStatus.kind,
      state.audioStatus.vars);
    setModelProgress(state.modelProgress.ratio, state.modelProgress.key,
      state.modelProgress.vars);
    setComputeProgress(state.computeProgress.ratio,
      state.computeProgress.key, state.computeProgress.vars);
    if (state.error) {
      const e = state.error;
      el.error.textContent = t(e.key, e.vars) +
        (e.hintKey ? t("vp.err.sep") + t(e.hintKey) : "");
    }
    if (state.audioMeta) renderAudioInfo();
    if (state.result) renderResult(state.result);
    el.micBtn.textContent = t(state.recording ? "vp.mic.stop" : "vp.mic.start");
  });

  // ------------------------------------------------------------------
  // 启动
  // ------------------------------------------------------------------
  I.mountSwitcher(document.getElementById("langSwitch"));
  I.apply();

  el.dlF32.disabled = true;
  el.dlJson.disabled = true;
  setModelStatus("vp.model.loading", "pending");
  setModelProgress(0, "vp.progress.engine");
  setupOrt().then((ok) => {
    if (!ok) {
      setModelStatus("vp.model.failed", "error");
      setModelProgress(0, "vp.progress.engineFail");
      showError("vp.err.engineFail");
      return;
    }
    initModel();
  });
})();

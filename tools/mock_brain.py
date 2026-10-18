#!/usr/bin/env python3
"""按规范实现一个假 brain，用来端到端验证 PP Friend 客户端。

  POST /human-to-brain   msgpack{brain_id, audio}   -> msgpack{kind:"text", text}
  POST /brain-to-human   msgpack{brain_id, skip_before?}
                         -> application/octet-stream:
                            [u32 大端文本长度][UTF-8 文本][1 字节 flags][Ogg…]

响应语义（见 docs/brain-api.md）：

  文本长度 0   这一轮没内容；flags 字节照发，后面没有音频
   flags bit0   1 = 这条是 skip_before 跳过的旧消息，只回文本、没有音频
  body 结束     这条说完了；合成失败发生在出声之前时直接回 502

**一条响应只回答一条消息。** `skip_before`（UTC epoch 毫秒）之前的旧消息
一条占一条响应（flags bit0 = 1），客户端会带着同一个 `skip_before` 重发，
直到积压排空、拿到真正的回复。

跑法：
  python3 tools/mock_brain.py [port] [token]
  python3 tools/mock_brain.py --fast        # 不阻塞、音频紧跟文本
  python3 tools/mock_brain.py --no-audio    # 只发前导，不发音频
  python3 tools/mock_brain.py --truncate    # 故意截断前导，验客户端重发
  python3 tools/mock_brain.py --failed      # 出声前失败，直接回 502
  python3 tools/mock_brain.py --selftest    # 只验编解码字节格式
"""

from __future__ import annotations

import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mini_msgpack as mp  # noqa: E402

OGG_PATH = Path(__file__).resolve().parent.parent / "build" / "reply.opus"

MSGPACK = "application/msgpack"

# 每隔这么久让 /brain-to-human 返回一次内容，其余时间返回 empty。
REPLY_PERIOD_SECONDS = 9.0
BLOCK_SECONDS = 2.5
# 前导（文本）之后隔多久音频才到。给客户端留出"先上屏"的窗口，
# 也让日志里能看出文本不用等合成。
AUDIO_GAP_SECONDS = 1.0

# 会话开始前就压在服务端的旧消息条数。带上 skip_before 时它们会以
# skipped 帧一条一条回来。
OLD_MESSAGE_COUNT = 2

REQUIRED_TOKEN: str | None = None

_start = time.monotonic()
_lock = threading.Lock()
_last_reply_at = -REPLY_PERIOD_SECONDS  # 负值让首次调用立刻就有内容
_utterance_count = 0
_old_messages: list[dict] = []


def _now_ms() -> int:
    return int(time.time() * 1000)


def ogg_prelude(text: str, *, skipped: bool = False) -> bytes:
    """`[u32 大端文本长度][UTF-8 文本][1 字节 flags]`。"""
    raw = text.encode("utf-8")
    flags = 1 if skipped else 0
    return struct.pack(">I", len(raw)) + raw + bytes([flags])


def _enqueue_old_messages() -> None:
    for i in range(OLD_MESSAGE_COUNT):
        _old_messages.append({
            "text": f"这是会话开始前的旧消息 {i + 1}，不该再念出来。",
            "at_ms": _now_ms() - (OLD_MESSAGE_COUNT - i) * 60_000,
        })


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[mock-brain] " + (fmt % args) + "\n")

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        try:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            # 客户端主动断开了 —— 这正是 abort() 该有的效果：
            # 服务端的 handler 带 AbortSignal，连接一断它就取消自己的工作，
            # 不用一直挂到超时。
            print("[断开] 客户端在响应前断开了连接（预期行为）", flush=True)

    def _send_msgpack(self, obj) -> None:
        self._send(200, mp.pack(obj), MSGPACK)

    def _write_chunk(self, data: bytes) -> None:
        self.wfile.write(f"{len(data):X}\r\n".encode() + data + b"\r\n")

    def _send_reply(
        self,
        text: str,
        *,
        skipped: bool = False,
        audio: bytes | None = None,
    ) -> None:
        """把「前导 + Ogg 流」写出去。一条响应只承载一条消息。"""
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Transfer-Encoding", "chunked")
            # 反代别攒着先发：前导要能立刻过。
            self.send_header("x-accel-buffering", "no")
            self.send_header("cache-control", "no-store")
            self.end_headers()

            prelude = ogg_prelude(text, skipped=skipped)
            if TRUNCATE and text:
                # 只写半截前导：客户端读到"长度说还有、body 却结束了"，
                # 应当按截断处理并立刻重发。空轮询不受影响。
                cut = max(1, len(prelude) // 2)
                self._write_chunk(prelude[:cut])
                self.wfile.flush()
            else:
                # 文本和 flags 先到，音频可以晚一点。
                self._write_chunk(prelude)
                self.wfile.flush()
                if audio is not None:
                    time.sleep(0.0 if FAST else AUDIO_GAP_SECONDS)
                    self._write_chunk(audio)
                    self.wfile.flush()

            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            print("[断开] 客户端在流中间断开了连接（预期行为）", flush=True)

    def _send_empty(self) -> None:
        """这一轮没有内容：文本长度 0，flags 照发，没有音频。"""
        self._send_reply("")

    def _check_auth(self) -> bool:
        if REQUIRED_TOKEN is None:
            return True
        got = self.headers.get("Authorization") or ""
        if got != f"Bearer {REQUIRED_TOKEN}":
            print(f"[auth] 拒绝：Authorization={got!r}", flush=True)
            self._send(401, b'{"detail":"unauthorized"}', "application/json")
            return False
        return True

    def do_POST(self) -> None:
        global _utterance_count, _last_reply_at

        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""

        if not self._check_auth():
            return

        path = self.path.rstrip("/")

        if path == "/human-to-brain":
            self._handle_human_to_brain(body)
            return

        if path == "/brain-to-human":
            self._handle_brain_to_human(body)
            return

        self._send(404, b'{"error":"unknown path"}', "application/json")

    def _handle_human_to_brain(self, body: bytes) -> None:
        global _utterance_count

        try:
            payload = mp.unpack(body)
        except Exception as e:
            print(f"[human-to-brain] MessagePack 解析失败：{e}", flush=True)
            self._send(400, b"bad msgpack", "text/plain")
            return

        brain_id = payload.get("brain_id", "")
        audio = payload.get("audio") or b""
        is_ogg = audio[:4] == b"OggS"

        _utterance_count += 1
        fmt = "Ogg Opus" if is_ogg else f"未知格式 {audio[:4]!r}"
        text = f"第 {_utterance_count} 句：收到 {len(audio) / 1024:.1f}KB {fmt}"
        print(
            f"[human-to-brain] brain_id={brain_id!r} 字段={sorted(payload)} "
            f"audio={len(audio)}B {fmt} → {text}",
            flush=True,
        )
        self._send_msgpack({"kind": "text", "text": text})

    def _handle_brain_to_human(self, body: bytes) -> None:
        global _last_reply_at

        try:
            payload = mp.unpack(body)
        except Exception as e:
            print(f"[brain-to-human] MessagePack 解析失败：{e}", flush=True)
            self._send(400, b"bad msgpack", "text/plain")
            return

        brain_id = payload.get("brain_id", "")
        skip_before = payload.get("skip_before")
        print(
            f"[brain-to-human] brain_id={brain_id!r} "
            f"skip_before={skip_before!r}",
            flush=True,
        )

        # 先把 skip_before 之前的旧消息逐条以 skipped 帧回掉。
        #
        # 注意：**先记下、发完再出队**。写响应时可能被截断（--truncate）
        # 或者客户端断线，真实服务端这时会把消息留在队列里；mock 也不能
        # 把它弄丢，否则客户端的"立刻重发同一个 skip_before"永远收不到。
        if skip_before is not None:
            with _lock:
                skipped = next(
                    (msg for msg in _old_messages
                     if msg["at_ms"] < skip_before),
                    None,
                )
            if skipped is not None:
                print(
                    f"[brain-to-human] → skipped 旧消息：{skipped['text']}",
                    flush=True,
                )
                # 一条响应只有这一条消息：文本 + flags bit0，没有音频。
                self._send_reply(skipped["text"], skipped=True)
                if not TRUNCATE:
                    with _lock:
                        _old_messages.remove(skipped)
                return

        # 没有 skip_before 时，旧消息也按正常回复发出去（mock 的简化处理）。
        text = None
        served_old = None
        if skip_before is None:
            with _lock:
                if _old_messages:
                    served_old = _old_messages[0]
                    text = served_old["text"]

        if text is None:
            time.sleep(0.0 if FAST else BLOCK_SECONDS)

            now = time.monotonic()
            with _lock:
                due = (now - _start) - _last_reply_at >= REPLY_PERIOD_SECONDS

            if not due:
                print("[brain-to-human] → empty", flush=True)
                self._send_empty()
                return

            # 真回复要不要算"发过了"，等确定不会 502 再推进。
            text = "你好，我是 PP Friend 的测试语音。今天天气不错。"

        if FAILED:
            # 出声之前就失败：回 502，这条消息应当留在队列里。
            print("[brain-to-human] → 502 合成失败（消息放回队列）", flush=True)
            self._send(502, b'{"detail":"tts failed"}', "application/json")
            return

        with _lock:
            _last_reply_at = time.monotonic() - _start

        audio = None
        if not NO_AUDIO and OGG_PATH.exists():
            audio = OGG_PATH.read_bytes()
        elif not OGG_PATH.exists():
            print(f"[brain-to-human] 缺少音频 {OGG_PATH}，只发文本",
                  flush=True)

        print(
            f"[brain-to-human] → text={text!r}，前导立即发，"
            f"音频 {len(audio) if audio else 0}B 随后",
            flush=True,
        )
        self._send_reply(text, audio=audio)
        # 截断模式下这条算没送达，留在队列里等客户端重发。
        if served_old is not None and not TRUNCATE:
            with _lock:
                try:
                    _old_messages.remove(served_old)
                except ValueError:
                    pass


# ---------------------------------------------------------------- 自检

FAST = False
NO_AUDIO = False
TRUNCATE = False
FAILED = False


def selftest() -> int:
    """用规范里的已知字节序列校验编解码和分帧。"""
    vectors = [
        # (值, 期望的十六进制)
        (None, "c0"),
        (True, "c3"),
        (False, "c2"),
        (0, "00"),
        (127, "7f"),
        (128, "cc80"),
        (255, "ccff"),
        (256, "cd0100"),
        (-1, "ff"),
        (-32, "e0"),
        (-33, "d0df"),
        ("", "a0"),
        ("a", "a161"),
        ("你好", "a6e4bda0e5a5bd"),
        (b"", "c400"),
        (b"\x01\x02\x03", "c403010203"),
        ({}, "80"),
        ({"kind": "empty"}, "81a46b696e64a5656d707479"),
        ({"a": 1, "b": 2}, "82a16101a16202"),
    ]

    failed = 0
    for value, expected in vectors:
        got = mp.pack(value).hex()
        ok = got == expected
        if not ok:
            failed += 1
        print(f"  {'ok ' if ok else 'FAIL'} {value!r:>24} → {got}"
              f"{'' if ok else f'  期望 {expected}'}")

    # 前导：u32 大端文本长度 + UTF-8 文本 + 1 字节 flags。
    got = ogg_prelude("你好").hex()
    ok = got == "00000006e4bda0e5a5bd00"
    if not ok:
        failed += 1
    print(f"  {'ok ' if ok else 'FAIL'} {'前导 你好':>24} → {got}"
          f"{'' if ok else '  期望 00000006e4bda0e5a5bd00'}")

    got = ogg_prelude("旧消息。", skipped=True).hex()
    ok = (
        got
        == "0000000c" + "e697a7e6b688e681afe38082" + "01"
    )
    if not ok:
        failed += 1
    print(f"  {'ok ' if ok else 'FAIL'} {'前导 skipped':>24} → {got}"
          f"{'' if ok else '  文本后 flags=01'}")

    got = ogg_prelude("").hex()
    ok = got == "0000000000"
    if not ok:
        failed += 1
    print(f"  {'ok ' if ok else 'FAIL'} {'前导 empty':>24} → {got}"
          f"{'' if ok else '  期望 0000000000'}")

    # 往返
    for value in [{"brain_id": "员工3", "audio": bytes(range(64))},
                  {"brain_id": "员工3", "skip_before": 1234567890},
                  {"nested": {"list": [1, 2, 3], "f": 1.5, "neg": -7}}]:
        if mp.unpack(mp.pack(value)) != value:
            failed += 1
            print(f"  FAIL 往返失败：{value!r}")

    print(f"\n{'全部通过' if failed == 0 else f'{failed} 项失败'}")
    return 1 if failed else 0


def main() -> int:
    global REQUIRED_TOKEN, FAST, NO_AUDIO, TRUNCATE, FAILED

    if "--selftest" in sys.argv:
        return selftest()

    FAST = "--fast" in sys.argv
    NO_AUDIO = "--no-audio" in sys.argv
    TRUNCATE = "--truncate" in sys.argv
    FAILED = "--failed" in sys.argv

    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    port = int(args[0]) if args else 8099
    if len(args) > 1 and args[1]:
        REQUIRED_TOKEN = args[1]
        print(f"已启用鉴权，要求 Bearer {REQUIRED_TOKEN}", flush=True)

    if not NO_AUDIO and not OGG_PATH.exists():
        print(f"缺少测试音频：{OGG_PATH}", file=sys.stderr)
        print("先用 TTS 服务生成一段 Ogg Opus 放到那里，"
              "或者加 --no-audio 只验文本链路", file=sys.stderr)
        return 1

    _enqueue_old_messages()

    print(
        f"mock brain 监听 0.0.0.0:{port}"
        f"（前导 + Ogg 流，音频 "
        f"{OGG_PATH.stat().st_size if OGG_PATH.exists() else 0}B）",
        flush=True,
    )
    if TRUNCATE:
        print("模式：前导故意截断（验客户端重发）", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

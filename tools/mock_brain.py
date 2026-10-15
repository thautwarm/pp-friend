#!/usr/bin/env python3
"""按规范实现一个假 brain，用来端到端验证 PP Friend 客户端。

  POST /human-to-brain   msgpack{brain_id, audio}          -> msgpack{kind:"text", text}
  POST /brain-to-human   msgpack{brain_id}                 -> msgpack{kind:"empty"}
                                                             | msgpack{kind:"text", text, audio}

服务端还有 /agent-to-brain（文本提交，返回 {kind:"empty"}）和
/brain-to-agent（长轮询，返回 {kind:"empty"} | {kind:"text", text}），
客户端不使用，这里也不实现。

跑法：
  python3 tools/mock_brain.py [port] [token]
  python3 tools/mock_brain.py --selftest        # 只验编解码字节格式
"""

from __future__ import annotations

import json
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

REQUIRED_TOKEN: str | None = None

_start = time.monotonic()
_lock = threading.Lock()
_last_reply_at = -REPLY_PERIOD_SECONDS  # 负值让首次调用立刻就有内容
_utterance_count = 0


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
            return

        if path == "/brain-to-human":
            try:
                payload = mp.unpack(body)
            except Exception as e:
                print(f"[brain-to-human] MessagePack 解析失败：{e}", flush=True)
                self._send(400, b"bad msgpack", "text/plain")
                return

            brain_id = payload.get("brain_id", "")
            time.sleep(BLOCK_SECONDS)

            now = time.monotonic()
            with _lock:
                due = (now - _start) - _last_reply_at >= REPLY_PERIOD_SECONDS
                if due:
                    _last_reply_at = now - _start

            if not due:
                self._send_msgpack({"kind": "empty"})
                return

            ogg = OGG_PATH.read_bytes()
            print(
                f"[brain-to-human] brain_id={brain_id!r} → text，{len(ogg)}B OGG",
                flush=True,
            )
            self._send_msgpack({
                "kind": "text",
                "text": "你好，我是 PP Friend 的测试语音。",
                "audio": ogg,
            })
            return

        self._send(404, b'{"error":"unknown path"}', "application/json")


# ---------------------------------------------------------------- 自检

def selftest() -> int:
    """用规范里的已知字节序列校验编解码。"""
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

    # 往返
    for value in [{"brain_id": "员工3", "audio": bytes(range(64))},
                  {"kind": "text", "text": "你好", "audio": b""},
                  {"nested": {"list": [1, 2, 3], "f": 1.5, "neg": -7}}]:
        if mp.unpack(mp.pack(value)) != value:
            failed += 1
            print(f"  FAIL 往返失败：{value!r}")

    print(f"\n{'全部通过' if failed == 0 else f'{failed} 项失败'}")
    return 1 if failed else 0


def main() -> int:
    global REQUIRED_TOKEN

    if "--selftest" in sys.argv:
        return selftest()

    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    port = int(args[0]) if args else 8099
    if len(args) > 1 and args[1]:
        REQUIRED_TOKEN = args[1]
        print(f"已启用鉴权，要求 Bearer {REQUIRED_TOKEN}", flush=True)

    if not OGG_PATH.exists():
        print(f"缺少测试音频：{OGG_PATH}", file=sys.stderr)
        print("先用 TTS 服务生成一段 Ogg Opus 放到那里", file=sys.stderr)
        return 1

    print(f"mock brain 监听 0.0.0.0:{port}"
          f"（音频 {OGG_PATH.stat().st_size}B，载荷 MessagePack）", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

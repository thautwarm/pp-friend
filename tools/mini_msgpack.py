"""最小 MessagePack 编解码 —— 只为 tools/mock_brain.py 服务。

**为什么不 pip install msgpack**：不想往使用者的 Python 环境里装东西。
而且这里的 Dart 侧用的是第三方 msgpack_dart，两边是**独立实现** ——
它们能互相解码，才说明字节格式没写错。

只覆盖协议用到的类型：map / str / bin / int / bool / nil，
外加 float 和 array 的读取（宽容一点，免得对面多塞个字段就崩）。
"""

from __future__ import annotations

import struct

# ---------------------------------------------------------------- 编码


def _pack_uint(n: int) -> bytes:
    if n < 0x80:
        return bytes([n])
    if n <= 0xFF:
        return b"\xcc" + struct.pack(">B", n)
    if n <= 0xFFFF:
        return b"\xcd" + struct.pack(">H", n)
    if n <= 0xFFFFFFFF:
        return b"\xce" + struct.pack(">I", n)
    return b"\xcf" + struct.pack(">Q", n)


def _pack_int(n: int) -> bytes:
    if n >= 0:
        return _pack_uint(n)
    if n >= -32:
        return bytes([0xE0 | (n + 32)])  # negative fixint
    if n >= -128:
        return b"\xd0" + struct.pack(">b", n)
    if n >= -32768:
        return b"\xd1" + struct.pack(">h", n)
    if n >= -2147483648:
        return b"\xd2" + struct.pack(">i", n)
    return b"\xd3" + struct.pack(">q", n)


def _pack_str(s: str) -> bytes:
    data = s.encode("utf-8")
    n = len(data)
    if n < 32:
        return bytes([0xA0 | n]) + data
    if n <= 0xFF:
        return b"\xd9" + struct.pack(">B", n) + data
    if n <= 0xFFFF:
        return b"\xda" + struct.pack(">H", n) + data
    return b"\xdb" + struct.pack(">I", n) + data


def _pack_bin(b: bytes) -> bytes:
    n = len(b)
    if n <= 0xFF:
        return b"\xc4" + struct.pack(">B", n) + b
    if n <= 0xFFFF:
        return b"\xc5" + struct.pack(">H", n) + b
    return b"\xc6" + struct.pack(">I", n) + b


def pack(value) -> bytes:
    if value is None:
        return b"\xc0"
    if value is True:
        return b"\xc3"
    if value is False:
        return b"\xc2"
    if isinstance(value, int):
        return _pack_int(value)
    if isinstance(value, float):
        return b"\xcb" + struct.pack(">d", value)
    if isinstance(value, str):
        return _pack_str(value)
    if isinstance(value, (bytes, bytearray, memoryview)):
        return _pack_bin(bytes(value))
    if isinstance(value, dict):
        n = len(value)
        out = bytearray()
        if n < 16:
            out.append(0x80 | n)
        elif n <= 0xFFFF:
            out += b"\xde" + struct.pack(">H", n)
        else:
            out += b"\xdf" + struct.pack(">I", n)
        for k, v in value.items():
            out += pack(k)
            out += pack(v)
        return bytes(out)
    if isinstance(value, (list, tuple)):
        n = len(value)
        out = bytearray()
        if n < 16:
            out.append(0x90 | n)
        elif n <= 0xFFFF:
            out += b"\xdc" + struct.pack(">H", n)
        else:
            out += b"\xdd" + struct.pack(">I", n)
        for item in value:
            out += pack(item)
        return bytes(out)
    raise TypeError(f"不能编码的类型：{type(value)}")


# ---------------------------------------------------------------- 解码


class _Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0

    def take(self, n: int) -> bytes:
        if self.pos + n > len(self.data):
            raise ValueError("MessagePack 数据被截断")
        chunk = self.data[self.pos : self.pos + n]
        self.pos += n
        return chunk

    def byte(self) -> int:
        return self.take(1)[0]


def _unpack(r: _Reader):
    b = r.byte()

    # positive fixint
    if b <= 0x7F:
        return b
    # fixmap
    if 0x80 <= b <= 0x8F:
        return _unpack_map(r, b & 0x0F)
    # fixarray
    if 0x90 <= b <= 0x9F:
        return [_unpack(r) for _ in range(b & 0x0F)]
    # fixstr
    if 0xA0 <= b <= 0xBF:
        return r.take(b & 0x1F).decode("utf-8")

    if b == 0xC0:
        return None
    if b == 0xC2:
        return False
    if b == 0xC3:
        return True
    if b == 0xC4:
        return r.take(r.byte())
    if b == 0xC5:
        return r.take(struct.unpack(">H", r.take(2))[0])
    if b == 0xC6:
        return r.take(struct.unpack(">I", r.take(4))[0])
    if b == 0xCA:
        return struct.unpack(">f", r.take(4))[0]
    if b == 0xCB:
        return struct.unpack(">d", r.take(8))[0]
    if b == 0xCC:
        return r.byte()
    if b == 0xCD:
        return struct.unpack(">H", r.take(2))[0]
    if b == 0xCE:
        return struct.unpack(">I", r.take(4))[0]
    if b == 0xCF:
        return struct.unpack(">Q", r.take(8))[0]
    if b == 0xD0:
        return struct.unpack(">b", r.take(1))[0]
    if b == 0xD1:
        return struct.unpack(">h", r.take(2))[0]
    if b == 0xD2:
        return struct.unpack(">i", r.take(4))[0]
    if b == 0xD3:
        return struct.unpack(">q", r.take(8))[0]
    if b == 0xD9:
        return r.take(r.byte()).decode("utf-8")
    if b == 0xDA:
        return r.take(struct.unpack(">H", r.take(2))[0]).decode("utf-8")
    if b == 0xDB:
        return r.take(struct.unpack(">I", r.take(4))[0]).decode("utf-8")
    if b == 0xDC:
        return [_unpack(r) for _ in range(struct.unpack(">H", r.take(2))[0])]
    if b == 0xDD:
        return [_unpack(r) for _ in range(struct.unpack(">I", r.take(4))[0])]
    if b == 0xDE:
        return _unpack_map(r, struct.unpack(">H", r.take(2))[0])
    if b == 0xDF:
        return _unpack_map(r, struct.unpack(">I", r.take(4))[0])
    # negative fixint
    if b >= 0xE0:
        return b - 256

    raise ValueError(f"不支持的 MessagePack 类型字节：0x{b:02x}")


def _unpack_map(r: _Reader, n: int) -> dict:
    out = {}
    for _ in range(n):
        k = _unpack(r)
        out[k] = _unpack(r)
    return out


def unpack(data: bytes):
    r = _Reader(data)
    value = _unpack(r)
    if r.pos != len(data):
        raise ValueError(f"MessagePack 尾部有多余字节（{len(data) - r.pos} 个）")
    return value

#!/usr/bin/env python3
"""Translate MCP Content-Length framing to Apple mcpbridge NDJSON."""
from __future__ import annotations

import json
import os
import select
import subprocess
import sys


def parse_inbound(buf: bytes) -> tuple[bytes | None, bytes]:
    stripped = buf.lstrip()
    if stripped.startswith(b"{"):
        nl = stripped.find(b"\n")
        if nl < 0:
            return None, buf
        prefix_len = len(buf) - len(stripped)
        return stripped[:nl], buf[prefix_len + nl + 1 :]
    sep = b"\r\n\r\n" if b"\r\n\r\n" in buf else (b"\n\n" if b"\n\n" in buf else None)
    if sep is None:
        return None, buf
    raw_headers, rest = buf.split(sep, 1)
    line_sep = b"\r\n" if sep == b"\r\n\r\n" else b"\n"
    length = None
    for line in raw_headers.split(line_sep):
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1].strip())
    if length is None:
        raise RuntimeError("missing Content-Length")
    if len(rest) < length:
        return None, buf
    return rest[:length], rest[length:]


def write_content_length(fd: int, body: bytes) -> None:
    os.write(fd, f"Content-Length: {len(body)}\r\n\r\n".encode() + body)


def main() -> int:
    cmd = sys.argv[1:] or ["xcrun", "mcpbridge"]
    child = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=sys.stderr,
        bufsize=0,
    )
    assert child.stdin is not None and child.stdout is not None
    stdin_fd = sys.stdin.fileno()
    out_fd = sys.stdout.fileno()
    child_out = child.stdout.fileno()
    inbound = b""
    outbound = b""
    try:
        while True:
            rfds, _, _ = select.select([stdin_fd, child_out], [], [])
            if stdin_fd in rfds:
                chunk = os.read(stdin_fd, 4096)
                if not chunk:
                    break
                inbound += chunk
                while True:
                    body, inbound = parse_inbound(inbound)
                    if body is None:
                        break
                    child.stdin.write(body + b"\n")
                    child.stdin.flush()
            if child_out in rfds:
                chunk = os.read(child_out, 8192)
                if not chunk:
                    break
                outbound += chunk
                while b"\n" in outbound:
                    line, outbound = outbound.split(b"\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    json.loads(line)
                    write_content_length(out_fd, line)
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
    return child.returncode or 0


def _self_test() -> int:
    body = b'{"jsonrpc":"2.0","id":1}'
    framed = f"Content-Length: {len(body)}\r\n\r\n".encode() + body + b"trailing"
    got, rest = parse_inbound(framed)
    assert got == body, got
    assert rest == b"trailing", rest
    ndjson = b'{"jsonrpc":"2.0"}\nnext'
    got, rest = parse_inbound(ndjson)
    assert got == b'{"jsonrpc":"2.0"}', got
    assert rest == b"next", rest
    incomplete, rest = parse_inbound(b"Content-Length: 4\r\n\r\nab")
    assert incomplete is None
    assert rest == b"Content-Length: 4\r\n\r\nab"
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        raise SystemExit(_self_test())
    raise SystemExit(main())

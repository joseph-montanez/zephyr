#!/usr/bin/env python3
"""mcp-bridge.py — stdio <-> Zephyr MCP HTTP bridge.

Standard MCP hosts (Claude Desktop, Cursor, Claude Code) speak stdio or
HTTP, not raw localhost TCP. Point the host at this script and it forwards
every JSON-RPC message to the live app:

    Zephyr.exe --mcp-port 17813
    python3 Tools/mcp-bridge.py --port 17813   # as the host's MCP command

Framing is LSP-style Content-Length on stdio, plain JSON bodies over
POST /mcp. Python standard library only.
"""
import http.client
import json
import sys

PORT = 17813


def read_stdin_message(stdin_buf):
    headers = {}
    while True:
        line = stdin_buf.readline()
        if not line:
            return None
        text = line.decode("ascii", errors="replace").strip()
        if not text:
            break
        if ":" in text:
            key, value = text.split(":", 1)
            headers[key.strip().lower()] = value.strip()
    length = int(headers.get("content-length", "0"))
    if length <= 0 or length > 8_000_000:
        return None
    body = b""
    while len(body) < length:
        chunk = stdin_buf.read(length - len(body))
        if not chunk:
            return None
        body += chunk
    return body


def write_stdout_message(stdout_buf, body: bytes):
    stdout_buf.write(b"Content-Length: %d\r\n\r\n" % len(body))
    stdout_buf.write(body)
    stdout_buf.flush()


def main():
    port = PORT
    args = sys.argv[1:]
    if "--port" in args:
        port = int(args[args.index("--port") + 1])
    stdin_buf = sys.stdin.buffer
    stdout_buf = sys.stdout.buffer
    while True:
        body = read_stdin_message(stdin_buf)
        if body is None:
            return
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=310)
            conn.request("POST", "/mcp", body=body,
                         headers={"Content-Type": "application/json"})
            response = conn.getresponse()
            payload = response.read()
            conn.close()
        except Exception as exc:  # keep the host session alive
            try:
                req_id = json.loads(body.decode("utf-8")).get("id")
            except Exception:
                req_id = None
            payload = json.dumps({
                "jsonrpc": "2.0", "id": req_id,
                "error": {"code": -32603, "message": f"bridge: {exc}"},
            }).encode("utf-8")
        write_stdout_message(stdout_buf, payload)


if __name__ == "__main__":
    main()

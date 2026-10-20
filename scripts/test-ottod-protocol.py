#!/usr/bin/env python3
"""Exercise the production ottod Unix-socket protocol end to end."""

from __future__ import annotations

import argparse
import base64
import json
import os
import socket
import sys
import time
import uuid
from pathlib import Path
from typing import Any


def exchange(socket_path: str, payload: dict[str, Any]) -> dict[str, Any]:
    frame = json.dumps(payload, separators=(",", ":")).encode() + b"\n"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(10)
        client.connect(socket_path)
        client.sendall(frame)
        response = bytearray()
        while b"\n" not in response:
            chunk = client.recv(8192)
            if not chunk:
                break
            response.extend(chunk)
            if len(response) > 8 * 1024 * 1024:
                raise AssertionError("remote response exceeded eight MiB")
    return json.loads(bytes(response).split(b"\n", 1)[0])


class Client:
    def __init__(self, socket_path: str, token: str) -> None:
        self.socket_path = socket_path
        self.token = token

    def request(
        self, method: str, parameters: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        request_id = str(uuid.uuid4())
        payload: dict[str, Any] = {
            "id": request_id,
            "token": self.token,
            "method": method,
        }
        if parameters is not None:
            payload["parameters"] = parameters
        response = exchange(self.socket_path, payload)
        assert response["id"] == request_id, response
        if response.get("error"):
            raise AssertionError(f"{method} failed: {response['error']}")
        return response["result"]


def wait_for_exit(client: Client, session_id: str, after: int = 0) -> dict[str, Any]:
    deadline = time.monotonic() + 10
    latest: dict[str, Any] = {"events": [], "latestSequence": after}
    while time.monotonic() < deadline:
        latest = client.request("events", {"afterSequence": after, "limit": 500})
        if any(
            event["kind"] == "session.exited" and event.get("sessionID") == session_id
            for event in latest["events"]
        ):
            return latest
        time.sleep(0.02)
    raise AssertionError(f"session {session_id} did not exit")


def output_text(page: dict[str, Any], session_id: str) -> str:
    chunks = []
    for event in page["events"]:
        if event["kind"] == "session.output" and event.get("sessionID") == session_id:
            chunks.append(base64.b64decode(event["payload"]["data"]))
    return b"".join(chunks).decode(errors="replace")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--workspace", required=True)
    arguments = parser.parse_args()

    token_file = Path(arguments.token_file)
    workspace = str(Path(arguments.workspace).resolve())
    token = token_file.read_text(encoding="utf-8").strip()
    assert len(token.encode()) >= 32
    assert os.stat(token_file).st_mode & 0o077 == 0

    unauthorized = exchange(
        arguments.socket,
        {"id": "unauthorized", "token": "invalid", "method": "heartbeat"},
    )
    assert unauthorized["error"]["code"] == "unauthorized", unauthorized

    client = Client(arguments.socket, token)
    hello = client.request("hello", {"afterSequence": 0, "limit": 500})
    heartbeat = client.request("heartbeat")
    assert hello["protocolVersion"] == 1
    assert hello["daemonID"] == heartbeat["daemonID"]

    transferred = b"linux-file-round-trip"
    write_result = client.request(
        "file.write",
        {
            "workspacePath": workspace,
            "relativePath": "remote-e2e.txt",
            "data": base64.b64encode(transferred).decode(),
            "overwrite": True,
        },
    )
    assert write_result["byteCount"] == len(transferred)
    read_result = client.request(
        "file.read",
        {"workspacePath": workspace, "relativePath": "remote-e2e.txt"},
    )
    assert base64.b64decode(read_result["data"]) == transferred

    one_shot = client.request(
        "launch",
        {
            "executable": "/bin/sh",
            "arguments": ["-lc", "printf 'linux-one-shot\\n'"],
            "workspacePath": workspace,
            "columns": 100,
            "rows": 30,
        },
    )["sessionID"]
    one_shot_page = wait_for_exit(client, one_shot)
    assert "linux-one-shot" in output_text(one_shot_page, one_shot)

    cursor = one_shot_page["latestSequence"]
    jit_probe = client.request(
        "launch",
        {
            "executable": sys.executable,
            "arguments": [
                "-c",
                "import mmap; region=mmap.mmap(-1,4096,prot=mmap.PROT_READ|mmap.PROT_WRITE|mmap.PROT_EXEC); region.write(b'x'); print('executable-memory-ok')",
            ],
            "workspacePath": workspace,
            "columns": 80,
            "rows": 24,
        },
    )["sessionID"]
    jit_page = wait_for_exit(client, jit_probe, cursor)
    assert "executable-memory-ok" in output_text(jit_page, jit_probe)
    assert any(
        event["kind"] == "session.exited"
        and event.get("sessionID") == jit_probe
        and event["payload"]["exitCode"] == 0
        for event in jit_page["events"]
    )

    cursor = jit_page["latestSequence"]
    interactive = client.request(
        "launch",
        {
            "executable": "/bin/sh",
            "arguments": [
                "-lc",
                "IFS= read -r line; stty size; printf 'interactive:%s\\n' \"$line\"",
            ],
            "workspacePath": workspace,
            "columns": 80,
            "rows": 24,
        },
    )["sessionID"]
    client.request(
        "resize", {"sessionID": interactive, "columns": 132, "rows": 47}
    )
    client.request(
        "input",
        {
            "sessionID": interactive,
            "data": base64.b64encode(b"resume\n").decode(),
        },
    )
    interactive_page = wait_for_exit(client, interactive, cursor)
    interactive_output = output_text(interactive_page, interactive)
    assert "47 132" in interactive_output, interactive_output
    assert "interactive:resume" in interactive_output, interactive_output

    cursor = interactive_page["latestSequence"]
    stoppable = client.request(
        "launch",
        {
            "executable": "/bin/sh",
            "arguments": ["-lc", "sleep 30"],
            "workspacePath": workspace,
            "columns": 80,
            "rows": 24,
        },
    )["sessionID"]
    client.request("stop", {"sessionID": stoppable})
    stopped_page = wait_for_exit(client, stoppable, cursor)
    assert any(
        event["kind"] == "session.stopped" and event.get("sessionID") == stoppable
        for event in stopped_page["events"]
    )

    new_token = uuid.uuid4().hex + uuid.uuid4().hex
    client.request("token.rotate", {"newToken": new_token})
    revoked = exchange(
        arguments.socket,
        {"id": "revoked", "token": token, "method": "heartbeat"},
    )
    assert revoked["error"]["code"] == "unauthorized", revoked
    rotated = Client(arguments.socket, new_token)
    assert rotated.request("heartbeat")["daemonID"] == hello["daemonID"]
    assert token_file.read_text(encoding="utf-8").strip() == new_token

    print(
        json.dumps(
            {
                "authentication_rejected": True,
                "cursor_replay_events": len(interactive_page["events"]),
                "daemon_identity_stable": True,
                "file_round_trip_bytes": len(transferred),
                "interactive_resize_input_stop": True,
                "jit_compatible_child": True,
                "latest_sequence": stopped_page["latestSequence"],
                "one_shot_output": "linux-one-shot",
                "token_rotation_revoked_old_token": True,
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()

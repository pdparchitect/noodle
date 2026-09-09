"""Opt-in native MSP checks: isolated temporary sessions, no prompts or credentials."""
import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time
import uuid


def command_id():
    value = bytearray(uuid.uuid4().bytes)
    value[:6] = int(time.time() * 1000).to_bytes(6, "big")
    value[6] = (value[6] & 15) | 112
    return str(uuid.UUID(bytes=bytes(value)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", help="Already verified native Muse binary (not its launcher)")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="noodle-muse-probe-") as workspace:
        environment = dict(os.environ)
        environment["XDG_DATA_HOME"] = workspace + "/data"
        environment["XDG_CONFIG_HOME"] = workspace + "/config"
        skill = Path(workspace) / ".agents/skills/noodle-fixture/SKILL.md"
        skill.parent.mkdir(parents=True)
        skill.write_text("---\nname: noodle-fixture\ndescription: Isolated Noodle discovery fixture.\n---\nNo actions are required.\n")
        skills = subprocess.run([args.executable, "skills", "list", "--source", "project",
            "--workspace", workspace, "--trust-workspace", "--json"],
            env=environment, capture_output=True, timeout=15, check=True)
        assert "noodle-fixture" in skills.stdout.decode(), "Muse did not discover shared .agents/skills"
        process = subprocess.Popen(
            [args.executable, "serve", "--disable-write", "--disable-shell"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=environment,
        )
        buffer = bytearray()

        def rpc(identifier, method, params):
            message = {"jsonrpc": "2.0", "method": method, "params": params}
            if identifier is not None:
                message["id"] = identifier
            process.stdin.write(json.dumps(message).encode() + b"\n")
            process.stdin.flush()
            if identifier is None:
                return None
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if b"\n" not in buffer:
                    if not select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))[0]:
                        break
                    chunk = process.stdout.read1(65536)
                    if not chunk:
                        raise RuntimeError("Muse closed its output")
                    buffer.extend(chunk)
                    continue
                line, _, remaining = buffer.partition(b"\n")
                buffer[:] = remaining
                response = json.loads(line)
                if response.get("id") != identifier:
                    continue
                if "error" in response:
                    raise RuntimeError(f"{method}: {response['error']}")
                return response["result"]
            raise RuntimeError(f"Timed out: {method}")

        try:
            initialized = rpc(1, "initialize", {"clientInfo": {"name": "noodle", "version": "1"}})
            assert initialized["schema"]["version"] == 1
            assert initialized["sessionDurability"] == "durable"
            assert initialized["museHome"].startswith(workspace + "/"), "Refusing to create a session outside the fixture"
            rpc(None, "initialized", {})
            catalogue = rpc(2, "model/list", {})
            model = next((row["modelId"] for row in catalogue["models"] if row["providerId"] == "meta"), None)
            start = {"commandId": command_id(), "workspaceRoot": workspace}
            if model:
                start.update({"providerId": "meta", "modelId": model})
            opened = rpc(3, "session/start", start)
            session = opened["session"]["sessionId"]
            assert opened["session"]["path"].startswith(workspace + "/")
            if model:
                rpc(4, "session/setModel", {"sessionId": session, "commandId": command_id(),
                    "model": {"providerId": "meta", "modelId": model}})
            process.terminate()
            process.wait(timeout=2)
            process = subprocess.Popen(
                [args.executable, "serve", "--disable-write", "--disable-shell"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=environment)
            buffer.clear()
            rpc(5, "initialize", {"clientInfo": {"name": "noodle", "version": "1"}})
            rpc(None, "initialized", {})
            resumed = rpc(6, "session/resume", {"sessionId": session, "commandId": command_id(), "excludeItems": True})
            assert resumed["session"]["sessionId"] == session
            print("Muse native MSP: skills, initialization, catalogue, session creation and resume after process restart passed; no model calls.")
        finally:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    main()

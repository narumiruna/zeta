#!/usr/bin/env -S uv run python
"""Verify interactive signal exits restore the controlling pseudo-terminal."""

from __future__ import annotations

import os
import pty
import select
import signal
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path


def run(binary: str, signum: int, expected: int) -> None:
    master, slave = pty.openpty()
    before = termios.tcgetattr(slave)
    with tempfile.TemporaryDirectory(prefix="zeta-signal-") as temporary:
        environment = os.environ.copy()
        environment["PI_CODING_AGENT_DIR"] = str(Path(temporary) / "agent")
        process = subprocess.Popen(
            [binary, "--no-session"],
            stdin=slave,
            stdout=slave,
            stderr=subprocess.PIPE,
            env=environment,
            close_fds=True,
        )
        output = bytearray()
        deadline = time.monotonic() + 5
        while b"\x1b[?2004h" not in output and time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                output.extend(os.read(master, 65536))
        if b"\x1b[?2004h" not in output:
            process.kill()
            raise RuntimeError("interactive terminal did not enter raw mode")
        process.send_signal(signum)
        exit_deadline = time.monotonic() + 5
        while process.poll() is None and time.monotonic() < exit_deadline:
            ready, _, _ = select.select([master], [], [], 0.05)
            if ready:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    break
        if process.poll() is None:
            process.kill()
            raise RuntimeError(f"signal {signum} did not terminate the process")
        return_code = process.wait()
        while True:
            ready, _, _ = select.select([master], [], [], 0.05)
            if not ready:
                break
            try:
                output.extend(os.read(master, 65536))
            except OSError:
                break
        after = termios.tcgetattr(slave)
        os.close(master)
        os.close(slave)
        if return_code != expected:
            raise RuntimeError(f"signal {signum} exited {return_code}, expected {expected}")
        if before != after:
            raise RuntimeError(f"signal {signum} did not restore termios")
        if b"\x1b[?2004l" not in output or b"\x1b[?25h" not in output:
            raise RuntimeError(f"signal {signum} omitted terminal restoration bytes")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: check-terminal-signals.py <zeta-binary>")
    run(sys.argv[1], signal.SIGTERM, 143)
    run(sys.argv[1], signal.SIGHUP, 129)
    print("terminal signal restoration verified")


if __name__ == "__main__":
    main()

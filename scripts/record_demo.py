#!/usr/bin/env python3
"""Record a terminal demo of the simulated CPU as an asciinema v2 cast (docs/demo.cast).

Runs real commands and stores their output with real timing (simulator output is streamed
as it is produced, so the UART text appears at the speed the CPU prints it). Play it with
`asciinema play docs/demo.cast`, or turn it into a GIF for the README with
`agg docs/demo.cast docs/demo.gif`.
"""
import json
import os
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COMMANDS = [
    "make run PROG=hello CORE=pipe_bp",
    "make run PROG=coremark CORE=pipe_bp",
    "make test 2>&1 | tail -3",
]
WIDTH, HEIGHT = 110, 32


def main():
    events = []
    t0 = time.time()

    def emit(text):
        events.append([round(time.time() - t0, 3), "o", text.replace("\n", "\r\n")])

    for cmd in COMMANDS:
        emit("$ ")
        for ch in cmd:  # type the command
            time.sleep(0.03)
            emit(ch)
        time.sleep(0.4)
        emit("\n")
        p = subprocess.Popen(cmd, shell=True, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             env={**os.environ, "MAKEFLAGS": "-s"})
        buf = b""
        while True:
            chunk = os.read(p.stdout.fileno(), 256)
            if not chunk:
                break
            buf += chunk
            try:
                text = buf.decode()
                buf = b""
            except UnicodeDecodeError:
                continue
            # hide the simulator command line echoed by make
            text = "\n".join(l for l in text.split("\n") if not l.startswith("build/")) if "Vsoc --imem" in text else text
            emit(text)
        p.wait()
        time.sleep(1.0)
    header = {"version": 2, "width": WIDTH, "height": HEIGHT, "timestamp": int(t0),
              "title": "RV32I 5-stage CPU running C over a simulated UART"}
    out = ROOT / "docs" / "demo.cast"
    out.write_text(json.dumps(header) + "\n" + "\n".join(json.dumps(e) for e in events) + "\n")
    print(f"wrote {out} ({events[-1][0]:.1f} s)")


if __name__ == "__main__":
    main()

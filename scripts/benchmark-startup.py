#!/usr/bin/env python3
import argparse
import json
import pathlib
import platform
import statistics
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--binary", required=True)
parser.add_argument("--iterations", type=int, default=20)
parser.add_argument("--output")
args = parser.parse_args()

samples = []
for _ in range(args.iterations):
    start = time.perf_counter()
    subprocess.run(
        [args.binary, "--help"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=True,
    )
    samples.append((time.perf_counter() - start) * 1000)
result = {
    "architecture": platform.machine(),
    "iterations": args.iterations,
    "minimumMilliseconds": min(samples),
    "medianMilliseconds": statistics.median(samples),
    "maximumMilliseconds": max(samples),
}
content = json.dumps(result, indent=2, sort_keys=True) + "\n"
if args.output:
    pathlib.Path(args.output).write_text(content)
else:
    print(content, end="")

#!/usr/bin/env python3
import os
import re
import sys
import subprocess

dir_a = sys.argv[1]
dir_b = sys.argv[2]

rx = re.compile(r"\((\d+)\)")

def audio_length(path):
    out = subprocess.check_output([
        "ffprobe",
        "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        path
    ])
    return float(out.strip())

def collect(dir_path):
    m = {}
    for name in os.listdir(dir_path):
        match = rx.search(name)
        if match:
            i = match.group(1)
            path = os.path.join(dir_path, name)
            if os.path.isfile(path):
                m[i] = audio_length(path)
    return m

a = collect(dir_a)
b = collect(dir_b)

for i in sorted(set(a) & set(b), key=int):
    if abs(a[i] - b[i]) > 1e-1:
        print(f"({i}) diff={a[i] - b[i]}")

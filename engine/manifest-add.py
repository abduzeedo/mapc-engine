#!/usr/bin/env python3
"""Adds or replaces one engine in engine-manifest.json, keeping the others.
usage: manifest-add.py <manifest> <version> <url> <sha256> <size> <backend>[,<backend>...]"""
import json, os, sys

path, version, url, sha, size, backends = sys.argv[1:]
m = json.load(open(path)) if os.path.exists(path) else {
    "engines": [], "steamArgs": ["-no-cef-sandbox", "-noverifyfiles"], "knownIssues": {}}
m["engines"] = [e for e in m["engines"] if e["version"] != version] + [{
    "version": version, "url": url, "sha256": sha, "size": int(size),
    "minAppVersion": "0.1", "backends": backends.split(",")}]
m["engines"].sort(key=lambda e: [(0, int(p), "") if p.isdigit() else (1, 0, p)
                                  for p in e["version"].replace("-", ".").split(".")])
with open(path, "w") as f:
    json.dump(m, f, indent=2)
    f.write("\n")

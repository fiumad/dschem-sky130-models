#!/usr/bin/env python3
"""Rebuild this repository's model files from the pinned sky130 PDK release.

Downloads the ciel release archives for the pinned open_pdks commit,
verifies their SHA-256, copies the ngspice model files into sky130A/, and
writes manifest.json: every file with its size and SHA-256, the corner names,
and the files ngspice opens for `.lib sky130.lib.spice <corner>` (the same
set for every corner).

Usage: scripts/build.py [--cache DIR]

Needs Python 3.9+, curl and tar with zstd support.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

# Same PDK as IIC-OSIC-TOOLS: sky130A from open_pdks 1.0.608.
OPEN_PDKS_COMMIT = "1689ac3f2dc763876eaf967227c7dfe831b031ae"
OPEN_PDKS_VERSION = "1.0.608"
RELEASE = ("https://github.com/fossi-foundation/ciel-releases/releases/download/"
           f"sky130-{OPEN_PDKS_COMMIT}/")
ARCHIVES = {
    "common.tar.zst": "92e3deed352b9a1aa53d47bc8f3de75e40dec013809c109d36ed4e8d13f74036",
    "sky130_fd_pr.tar.zst": "79ac105aa2710acf358572aa3762b065bcdd9ed408dc64f3c32d9fb71cdd287e",
}
# Directories copied from the PDK, relative to sky130A/.
COPY = ["libs.tech/ngspice", "libs.ref/sky130_fd_pr/spice"]
LIB = "sky130A/libs.tech/ngspice/sky130.lib.spice"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(cache):
    os.makedirs(cache, exist_ok=True)
    for name, want in ARCHIVES.items():
        path = os.path.join(cache, name)
        if not os.path.exists(path) or sha256(path) != want:
            subprocess.run(["curl", "-fsSL", "-o", path, RELEASE + name], check=True)
        got = sha256(path)
        if got != want:
            sys.exit(f"{name}: SHA-256 {got}, expected {want}")
    return [os.path.join(cache, n) for n in ARCHIVES]


# --- which files does `.lib sky130.lib.spice <corner>` open? -------------

DIRECTIVE = re.compile(r"^\s*\.(lib|include|inc)\s+(.*)$", re.IGNORECASE)


def logical_lines(path):
    """Lines with '+' continuations joined and comments dropped."""
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if line.startswith("+") and out:
                out[-1] += " " + line[1:]
            elif line.startswith("*"):
                continue
            else:
                out.append(line)
    return out


def split_args(rest):
    rest = rest.strip()
    if rest.startswith('"'):
        end = rest.index('"', 1)
        return rest[1:end], rest[end + 1:].split()
    parts = rest.split()
    return (parts[0], parts[1:]) if parts else ("", [])


def required_files(lib_file):
    """Files ngspice opens for `.lib lib_file <any corner>`.

    ngspice reads the include files of every section of a library, not only
    the selected one (checked with strace against ngspice 47), so the set is
    the same for every corner: everything reachable from lib_file through
    `.include` and `.lib file section`.
    """
    seen = set()

    def visit(path):
        if path in seen:
            return
        seen.add(path)
        for line in logical_lines(os.path.join(ROOT, path)):
            m = DIRECTIVE.match(line)
            if not m:
                continue
            target, extra = split_args(m.group(2))
            if m.group(1).lower() == "lib" and not extra:
                continue  # `.lib name`: a section header, not a reference
            ref = os.path.normpath(os.path.join(os.path.dirname(path), target))
            if not os.path.exists(os.path.join(ROOT, ref)):
                sys.exit(f"{path}: missing {target}")
            visit(ref.replace(os.sep, "/"))

    visit(lib_file)
    return sorted(seen)


def corners(lib_file):
    names = []
    for line in logical_lines(os.path.join(ROOT, lib_file)):
        m = re.match(r"^\s*\.lib\s+(\S+)\s*$", line, re.IGNORECASE)
        if m:
            names.append(m.group(1))
    return names


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--cache", default=os.path.join(ROOT, ".cache"))
    args = ap.parse_args()

    archives = fetch(args.cache)
    with tempfile.TemporaryDirectory() as tmp:
        for a in archives:
            subprocess.run(["tar", "--zstd", "-xf", a, "-C", tmp], check=True)
        shutil.rmtree(os.path.join(ROOT, "sky130A"), ignore_errors=True)
        for d in COPY:
            shutil.copytree(os.path.join(tmp, "sky130A", d), os.path.join(ROOT, "sky130A", d))

    files = {}
    for d in COPY:
        for dirpath, _, names in os.walk(os.path.join(ROOT, "sky130A", d)):
            for n in names:
                full = os.path.join(dirpath, n)
                rel = os.path.relpath(full, ROOT).replace(os.sep, "/")
                files[rel] = {"size": os.path.getsize(full), "sha256": sha256(full)}
    manifest = {
        "pdk": "sky130A",
        "open_pdks_version": OPEN_PDKS_VERSION,
        "open_pdks_commit": OPEN_PDKS_COMMIT,
        "lib": LIB,
        "corners": corners(LIB),
        # Load all of these before `.lib <lib> <corner>`, whatever the corner.
        "required": required_files(LIB),
        "files": dict(sorted(files.items())),
    }
    with open(os.path.join(ROOT, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
        f.write("\n")
    req = manifest["required"]
    print(f"{len(files)} files, {sum(v['size'] for v in files.values()) / 2**20:.1f} MiB; "
          f"{len(manifest['corners'])} corners; required: {len(req)} files, "
          f"{sum(files[p]['size'] for p in req) / 2**20:.1f} MiB")


if __name__ == "__main__":
    main()

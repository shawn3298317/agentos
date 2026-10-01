#!/usr/bin/env python3
"""Download pinned upstream prompts into vendor/ and record their sha256 in pins.json."""
import hashlib, json, os, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GH_AXI = os.environ.get("GH_AXI", "npx -y gh-axi").split()


def fetch_raw(repo, path, sha):
    """File bytes at a commit, via gh-axi (it prints the body as a JSON-quoted `body:` line).
    gh-axi trims one trailing newline; that is the only known difference from the raw file."""
    out = subprocess.run(
        GH_AXI + ["api", f"repos/{repo}/contents/{path}?ref={sha}",
                  "--header", "Accept: application/vnd.github.raw", "--full"],
        capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        if line.startswith("  body: "):
            return json.loads(line[len("  body: "):]).encode()
    raise RuntimeError(f"no body in gh-axi output for {repo}/{path}: {out[:200]}")


pins = json.loads((ROOT / "pins.json").read_text())
(ROOT / "vendor").mkdir(exist_ok=True)
for name, p in pins["vendor"].items():
    raw = fetch_raw(p["repo"], p["path"], p["sha"])
    (ROOT / "vendor" / name).write_bytes(raw)
    pins["sha256"][name] = hashlib.sha256(raw).hexdigest()
    print(f"{name}: {p['repo']}@{p['sha']} {pins['sha256'][name][:12]}", file=sys.stderr)
(ROOT / "pins.json").write_text(json.dumps(pins, indent=2) + "\n")

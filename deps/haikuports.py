#!/usr/bin/env python3
"""Resolve and fetch HaikuPorts packages for an air/OS architecture.

    haikuports.py fetch ARCH REQ...            download what REQ needs; print the files
    haikuports.py stage ARCH PREFIX REQ...     same, and extract them into PREFIX
                                               (a boot/system tree)

REQ is a package name (curl_devel) or a resolvable (devel:libcurl >= 8).
What the Haiku base already provides (haiku, haiku_devel and the build
packages of the air/OS SDK) is never fetched. The repository index is cached
for a day in $AIROS_CACHE/haikuports/ARCH; packages are cached by file name.
Every run writes the resolved list (name-version-arch.hpkg and sha256) next
to the files, so a build records exactly which HaikuPorts packages it used.

Environment: AIROS_SDK, AIROS_CACHE (as lib/env.sh sets them).
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

BASE = os.environ.get("HAIKUPORTS_URL", "https://eu.hpkg.haiku-os.org/haikuports/master")
CACHE = os.environ.get("AIROS_CACHE", "/data2/airos/cache")
SDK = os.environ.get("AIROS_SDK", "/data1/airos/sdk")


def sdk_env(arch):
    env = {}
    for line in open(os.path.join(SDK, arch, "env.sh")):
        m = re.match(r"(\w+)=(.*)", line.strip())
        if m:
            env[m.group(1)] = m.group(2)
    return env


def tool(arch, name):
    t = sdk_env(arch)["TOOLS"]
    return os.path.join(t, name, name) if os.path.isdir(os.path.join(t, name)) else os.path.join(t, name)


def download(url, path):
    req = urllib.request.Request(url, headers={"User-Agent": "airos-ci"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=120) as r, open(path + ".part", "wb") as f:
                while True:
                    chunk = r.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
            os.rename(path + ".part", path)
            return
        except Exception as e:  # noqa: BLE001 - retry any transfer error
            print(f"warning: {url}: {e}", file=sys.stderr)
            time.sleep(5 * (attempt + 1))
    sys.exit(f"error: cannot download {url}")


def parse_listing(text):
    pkgs, cur = [], None
    for line in text.splitlines():
        m = re.match(r"\t(name|version|architecture|provides|requires): (.*)", line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if key == "name":
            cur = {"name": val, "provides": [], "requires": []}
            pkgs.append(cur)
        elif cur is not None:
            if key in ("provides", "requires"):
                cur[key].append(val)
            else:
                cur[key] = val
    return pkgs


def repository(arch):
    d = os.path.join(CACHE, "haikuports", arch)
    os.makedirs(d, exist_ok=True)
    repo, listing = os.path.join(d, "repo"), os.path.join(d, "repo.txt")
    if not os.path.exists(listing) or time.time() - os.path.getmtime(listing) > 86400:
        download(f"{BASE}/{arch}/current/repo", repo)
        text = subprocess.run([tool(arch, "package_repo"), "list", "-v", repo], check=True,
                              stdout=subprocess.PIPE, text=True, errors="replace").stdout
        with open(listing, "w") as f:
            f.write(text)
    return parse_listing(open(listing, errors="replace").read())


def vkey(v):
    return [(0, int(x)) if x.isdigit() else (1, x) for x in re.split(r"[._~-]", v or "0")]


def split(expr):
    m = re.match(r"\s*([^<>=!\s]+)\s*(>=|<=|==|!=|<|>|=)?\s*([^\s]*)(?:\s+compat\s*>=\s*(\S+))?", expr)
    return m.group(1), m.group(2), m.group(3) or None, m.group(4)


def satisfies(provide, require):
    pn, _, pv, pcompat = split(provide)
    rn, op, rv, _ = split(require)
    if pn != rn:
        return False
    if not op:
        return True
    if not pv:
        return False
    c = (vkey(pv) > vkey(rv)) - (vkey(pv) < vkey(rv))
    ok = {"==": c == 0, "=": c == 0, ">=": c >= 0, "<=": c <= 0, ">": c > 0, "<": c < 0, "!=": c != 0}[op]
    if not ok and op in (">=", ">") and pcompat and vkey(rv) >= vkey(pcompat) and c <= 0:
        return True
    return ok


def installed_provides(arch):
    """Provides of the SDK's base: haiku, haiku_devel and the build packages."""
    env = sdk_env(arch)
    build = env["HAIKU_BUILD"]
    package = tool(arch, "package")
    provides = []
    pkgdir = os.path.join(build, "objects", "haiku", arch, "packaging", "packages")
    for name in ("haiku.hpkg", "haiku_devel.hpkg"):
        out = subprocess.run([package, "list", "-i", os.path.join(pkgdir, name)], check=True,
                             stdout=subprocess.PIPE, text=True).stdout
        provides += re.findall(r"(?m)^\s*provides:\s*(.*)$", out)
    for entry in os.listdir(os.path.join(build, "build_packages")):
        info = os.path.join(build, "build_packages", entry, ".PackageInfo")
        if os.path.exists(info):
            text = open(info).read()
            m = re.search(r"provides\s*\{(.*?)\}", text, re.S)
            if m:
                provides += [l.strip().strip('"') for l in m.group(1).splitlines() if l.strip()]
    return provides


def resolve(arch, requirements):
    pkgs = [p for p in repository(arch) if p.get("architecture") in (arch, "any")
            and not p["name"].endswith(("_debuginfo", "_source"))]
    base = installed_provides(arch)
    chosen, todo = {}, list(requirements)
    while todo:
        req = todo.pop(0)
        rn, op, rv, _ = split(req)
        if not op and any(p["name"] == rn for p in pkgs) and rn not in chosen:
            candidates = [p for p in pkgs if p["name"] == rn]
        else:
            if any(satisfies(p, req) for p in base):
                continue
            if any(satisfies(prov, req) for c in chosen.values() for prov in c["provides"]):
                continue
            candidates = [p for p in pkgs if any(satisfies(prov, req) for prov in p["provides"])]
        if not candidates:
            sys.exit(f"error: nothing in HaikuPorts {arch} provides {req}")
        best = max(candidates, key=lambda p: vkey(p["version"]))
        if best["name"] in chosen:
            continue
        chosen[best["name"]] = best
        todo += best["requires"]
    return list(chosen.values())


def fetch(arch, requirements):
    d = os.path.join(CACHE, "haikuports", arch, "packages")
    os.makedirs(d, exist_ok=True)
    files = []
    for p in sorted(resolve(arch, requirements), key=lambda p: p["name"]):
        fname = f"{p['name']}-{p['version']}-{p['architecture']}.hpkg"
        path = os.path.join(d, fname)
        if not os.path.exists(path):
            print(f"  download {fname}", file=sys.stderr)
            download(f"{BASE}/{arch}/current/packages/{fname}", path)
        files.append(path)
    return files


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("fetch", "stage"):
        sys.exit(__doc__)
    cmd, arch = sys.argv[1], sys.argv[2]
    if cmd == "stage":
        prefix, reqs = sys.argv[3], sys.argv[4:]
    else:
        prefix, reqs = None, sys.argv[3:]
    files = fetch(arch, reqs)
    record = [{"file": os.path.basename(f), "sha256": hashlib.sha256(open(f, "rb").read()).hexdigest()}
              for f in files]
    if prefix:
        os.makedirs(prefix, exist_ok=True)
        package = tool(arch, "package")
        for f in files:
            subprocess.run([package, "extract", "-C", prefix, f], check=True)
        for junk in (".PackageInfo",):
            p = os.path.join(prefix, junk)
            if os.path.exists(p):
                os.remove(p)
        with open(os.path.join(prefix, ".haikuports.json"), "w") as f:
            json.dump(record, f, indent=1)
    for f in files:
        print(f)


if __name__ == "__main__":
    main()

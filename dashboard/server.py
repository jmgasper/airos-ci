#!/usr/bin/env python3
"""air/OS build dashboard: the latest images, buttons that start image builds,
and the progress of the builds running (whoever started them).

Serves on 127.0.0.1:8090 behind the build server's nginx
(images/nginx-artifacts.conf), which serves the image files themselves under
/images/. Builds started here run images/build-image.sh and
images/smoke-test.sh from a clone of jmgasper/airos-ci updated to main first;
every image build records itself in $AIROS_DATA/builds (lib/status.py).

  GET  /                 the page (dashboard/index.html)
  GET  /api/status       targets, latest images, builds in progress, history
  GET  /api/log?id=ID    the tail of a build's log (&lines=N)
  POST /api/build        {"targets": ["x86_64", "arm64", "rpi4"], "clean": false}
  POST /api/cancel       {"id": ID}: builds started here only
"""
import datetime
import fcntl
import glob
import http.server
import json
import os
import re
import shutil
import signal
import statistics
import subprocess
import sys
import threading
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
CI = os.path.dirname(HERE)
DATA = os.environ.get("AIROS_DATA", "/data2/airos")
ROOT = os.environ.get("AIROS_ROOT", "/data1/airos")
BUILDS = os.path.join(DATA, "builds")
ARTIFACTS = os.path.join(DATA, "artifacts", "images")
LOCKS = os.path.join(DATA, "locks")
# The airos-ci clone web builds run from (updated to origin/main for each).
CHECKOUT = os.environ.get("DASHBOARD_CHECKOUT", CI)
PORT = int(os.environ.get("DASHBOARD_PORT", "8090"))

TARGETS = {
    "x86_64": {"label": "x86_64", "for": "PCs and the X399 workstation (USB stick or DVD, EFI and BIOS)",
               "arch": "x86_64"},
    "arm64": {"label": "ARM64 / EFI", "for": "ROCK 5 ITX and other UEFI arm64 boards (USB stick)",
              "arch": "arm64"},
    "rpi4": {"label": "Raspberry Pi 4", "for": "SD card for Balena Etcher; boots with no install",
             "arch": "arm64"},
}
# Until there is history: rough active build times in seconds.
DEFAULT_SECONDS = {("x86_64", False): 900, ("arm64", False): 1000, ("rpi4", False): 700,
                   ("x86_64", True): 3000, ("arm64", True): 3300, ("rpi4", True): 3300}
PASSIVE = ("queued", "done", "failed", "cancelled")
start_lock = threading.Lock()


def parse_time(text):
    return datetime.datetime.fromisoformat(text) if text else None


def utcnow():
    return datetime.datetime.now(datetime.timezone.utc)


def alive(pid):
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def read_record(build_id):
    try:
        return json.load(open(os.path.join(BUILDS, build_id, "status.json")))
    except (OSError, ValueError):
        return None


def all_records():
    records = []
    for d in glob.glob(os.path.join(BUILDS, "2*")):
        record = read_record(os.path.basename(d))
        if record:
            records.append(record)
    records.sort(key=lambda r: r.get("started") or "")
    return records


def stage_durations(record):
    """{stage: seconds} for a record, the waiting stages and end markers left out."""
    stages = record.get("stages") or []
    out = {}
    for stage, following in zip(stages, stages[1:]):
        name = stage["name"]
        if name in PASSIVE or name.startswith("waiting"):
            continue
        seconds = (parse_time(following["start"]) - parse_time(stage["start"])).total_seconds()
        out[name] = out.get(name, 0) + seconds
    return out


def active_start(record):
    for stage in record.get("stages") or []:
        if stage["name"] not in PASSIVE and not stage["name"].startswith("waiting"):
            return parse_time(stage["start"])
    return None


def history_for(records, target, clean):
    done = [r for r in records if r.get("target") == target and bool(r.get("clean")) == clean
            and r.get("state") == "done"]
    return done[-6:]


def estimate(records, record):
    """Seconds expected for the rest of a running build, and its usual length."""
    target, clean = record["target"], bool(record.get("clean"))
    history = history_for(records, target, clean)
    if not history:
        typical_total = DEFAULT_SECONDS.get((target, clean), 1200)
        start = active_start(record)
        elapsed = (utcnow() - start).total_seconds() if start else 0
        return max(typical_total - elapsed, 30), typical_total, False
    per_stage = {}
    order = []
    for past in history:
        for name, seconds in stage_durations(past).items():
            per_stage.setdefault(name, []).append(seconds)
            if name not in order:
                order.append(name)
    typical = {name: statistics.median(v) for name, v in per_stage.items()}
    common = [n for n in order if len(per_stage[n]) * 2 >= len(history)]
    typical_total = sum(typical[n] for n in common)
    current = record.get("stage")
    stages = record.get("stages") or []
    in_stage = (utcnow() - parse_time(stages[-1]["start"])).total_seconds() if stages else 0
    if current not in order:
        remaining = sum(typical[n] for n in common)
        return remaining, typical_total, True
    rest = common[common.index(current) + 1:] if current in common else \
        [n for n in common if order.index(n) > order.index(current)]
    left_here = max(typical.get(current, 0) - in_stage, min(30, typical.get(current, 30) * 0.1))
    return left_here + sum(typical[n] for n in rest), typical_total, True


def jam_progress(log_path):
    """(done, total) of the latest jam run in the log, if one is running."""
    try:
        size = os.path.getsize(log_path)
        with open(log_path, "rb") as f:
            f.seek(max(0, size - 24 * 1024 * 1024))
            text = f.read().decode("utf-8", "replace")
    except OSError:
        return None
    marks = list(re.finditer(r"\.\.\.updating (\d+) target\(s\)\.\.\.", text))
    if not marks:
        return None
    last = marks[-1]
    total = int(last.group(1))
    after = text[last.end():]
    if re.search(r"\.\.\.updated \d+ target\(s\)\.\.\.|\.\.\.failed updating", after):
        return None
    # jam prints one line per action: "ActionName target"
    done = sum(1 for line in after.splitlines() if re.match(r"^[A-Z][\w+]* \S", line))
    return min(done, total), total


def lock_users(lock_name):
    """Who holds a lock and who waits for it: the scripts with the lock file
    open (the runners and the dashboard run as the same user, so /proc
    shows them), described for people."""
    path = os.path.realpath(os.path.join(LOCKS, f"{lock_name}.lock"))
    holders, waiters = [], []
    for fd_dir in glob.glob("/proc/[0-9]*/fd"):
        try:
            if not any(os.readlink(os.path.join(fd_dir, fd)) == path for fd in os.listdir(fd_dir)):
                continue
            pid = int(fd_dir.split("/")[2])
            argv = open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0")
            argv = [a.decode(errors="replace") for a in argv if a]
        except OSError:
            continue
        if not argv:
            continue
        program = os.path.basename(argv[0])
        if program == "flock":
            waiters.append(describe_job(argv[2:], pid))
        elif any(a.endswith(".sh") for a in argv[:3]):
            holders.append(describe_job(argv, pid))
    return holders, waiters


def describe_job(argv, pid):
    command = " ".join(argv)
    try:
        command += " " + os.readlink(f"/proc/{pid}/cwd") + "/"
    except OSError:
        pass
    script = next((os.path.basename(a) for a in argv if a.endswith(".sh")), os.path.basename(argv[0]))
    where = "a shell"
    m = re.search(r"/runner-work/([^/]+)/", command)
    if m:
        where = f"CI of {m.group(1)}"
    elif "/dashboard/" in command:
        where = "the dashboard"
    names = {"build-app-packages.sh": "app packages", "build-sdk.sh": "SDK", "build-deps.sh": "dependencies",
             "build-image.sh": "image", "build-gl.sh": "arm64 GL stack", "build-gl-x86_64.sh": "x86_64 GL stack",
             "build-nvidia.sh": "NVIDIA driver", "build-nvk.sh": "NVK", "build-zink.sh": "Zink",
             "build-firmware.sh": "firmware", "build-summit.sh": "Summit", "ci-build-app.sh": "app packages"}
    what = names.get(script, script)
    target = next((a for a in argv if a in TARGETS), None)
    if target and script == "build-image.sh":
        what = f"{TARGETS[target]['label']} image"
    return {"pid": pid, "what": what, "where": where}


def describe_build(records, record):
    out = dict(record)
    state = record.get("state")
    live = alive(record.get("pid")) or alive(record.get("smoke_pid")) or alive(record.get("pgid"))
    if state in ("waiting", "running", "built") and not live:
        out["state"] = "interrupted" if state != "built" else "built"
        out["note"] = "the build process is gone" if state != "built" else "built; no smoke test ran"
    started = parse_time(record.get("started"))
    finished = parse_time(record.get("finished"))
    out["elapsed"] = ((finished or utcnow()) - started).total_seconds() if started else 0
    start = active_start(record)
    out["active_elapsed"] = ((finished or utcnow()) - start).total_seconds() if start else 0
    if out["state"] == "waiting":
        holders, waiters = lock_users(f"haiku-{TARGETS[record['target']]['arch']}")
        seen = set()
        out["blocked_by"] = [h for h in holders if not (h["what"], h["where"]) in seen
                             and not seen.add((h["what"], h["where"]))]
        own = f"{TARGETS[record['target']]['label']} image"
        # (a holding flock has the lock open too: it is the holder, not queued)
        out["queue"] = [w for w in waiters if (w["what"], w["where"]) not in seen and w["what"] != own]
    if out["state"] in ("waiting", "running", "built"):
        left, typical, from_history = estimate(records, record)
        out["eta_seconds"] = left
        out["typical_seconds"] = typical
        out["estimate_from_history"] = from_history
        total = out["active_elapsed"] + left
        out["progress"] = 0.0 if out["state"] == "waiting" else min(0.99, out["active_elapsed"] / total) \
            if total > 0 else 0.0
        if record.get("stage") in ("Haiku packages", "image"):
            jam = jam_progress(record.get("log", ""))
            if jam:
                out["jam"] = {"done": jam[0], "total": jam[1]}
    return out


def latest_images(target):
    base = os.path.join(ARTIFACTS, target)
    stamps = sorted((d for d in os.listdir(base) if d[:1].isdigit()), reverse=True) if os.path.isdir(base) else []
    images = []
    for stamp in stamps[:5]:
        d = os.path.join(base, stamp)
        files = sorted(os.listdir(d))
        image = next((f for f in files if f.endswith(".xz")), None)
        if not image:
            continue
        info = {"stamp": stamp, "image": image, "url": f"/images/{target}/{stamp}/{image}",
                "bytes": os.path.getsize(os.path.join(d, image)),
                "sha256_url": f"/images/{target}/{stamp}/{image}.sha256" if image + ".sha256" in files else None,
                "manifest_url": f"/images/{target}/{stamp}/manifest.json" if "manifest.json" in files else None,
                "screen_url": f"/images/{target}/{stamp}/screen.png" if "screen.png" in files else None,
                "smoke": None}
        try:
            manifest = json.load(open(os.path.join(d, "manifest.json")))
            info.update({"built": manifest.get("built"), "haiku": manifest.get("haiku", {}).get("revision"),
                         "image_bytes": manifest.get("image_bytes"),
                         "packages": [p["file"] for p in manifest.get("packages", [])]})
        except (OSError, ValueError):
            pass
        try:
            first = open(os.path.join(d, "smoke.log")).read()
            m = re.search(r"SMOKE (PASS|FAIL)", first)
            info["smoke"] = m.group(1).lower() if m else None
        except OSError:
            pass
        images.append(info)
    return images


def locks():
    out = {}
    for name in ("haiku-x86_64", "haiku-arm64"):
        path = os.path.join(LOCKS, f"{name}.lock")
        try:
            with open(path, "a") as f:
                try:
                    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    fcntl.flock(f, fcntl.LOCK_UN)
                    out[name] = False
                except BlockingIOError:
                    out[name] = True
        except OSError:
            out[name] = None
    return out


def status():
    records = all_records()
    targets = {}
    for name, meta in TARGETS.items():
        current = None
        link = os.path.join(BUILDS, f"current-{name}")
        if os.path.islink(link):
            record = read_record(os.readlink(link))
            if record:
                current = describe_build(records, record)
        history = history_for(records, name, False)
        targets[name] = dict(meta, images=latest_images(name), current=current,
                             typical_seconds=statistics.median(
                                 [sum(stage_durations(r).values()) for r in history]) if history else None)
    recent = [describe_build(records, r) for r in records[-20:]][::-1]
    disk = shutil.disk_usage(DATA)
    load = os.getloadavg()
    return {"targets": targets, "recent": recent, "locks": locks(),
            "server": {"load": [round(x, 1) for x in load], "cpus": os.cpu_count(),
                       "disk_free_gb": round(disk.free / 1e9), "time": utcnow().isoformat(timespec="seconds")}}


def update_checkout():
    if CHECKOUT == CI and not os.path.isdir(os.path.join(CHECKOUT, ".git")):
        return
    subprocess.run(["git", "-C", CHECKOUT, "fetch", "-q", "origin", "main"], check=True, timeout=120)
    subprocess.run(["git", "-C", CHECKOUT, "reset", "-q", "--hard", "origin/main"], check=True)


def start_builds(targets, clean):
    started, skipped = [], []
    with start_lock:
        records = all_records()
        try:
            update_checkout()
        except (subprocess.SubprocessError, OSError) as e:
            return {"error": f"could not update airos-ci: {e}"}
        status_py = os.path.join(CHECKOUT, "lib", "status.py")
        for target in targets:
            link = os.path.join(BUILDS, f"current-{target}")
            if os.path.islink(link):
                record = read_record(os.readlink(link))
                if record and describe_build(records, record)["state"] in ("waiting", "running"):
                    skipped.append({"target": target, "reason": f"already building ({record['id']})"})
                    continue
            command = [sys.executable, status_py, "begin", target, "--origin", "web"]
            if clean:
                command.append("--clean")
            build_id = subprocess.run(command, check=True, capture_output=True, text=True).stdout.strip()
            env = dict(os.environ, BUILD_ID=build_id)
            env.pop("BUILD_LOGGING", None)
            if clean:
                env["CLEAN"] = "1"
            script = (f'"{CHECKOUT}/images/build-image.sh" {target} && '
                      f'"{CHECKOUT}/images/smoke-test.sh" {target}')
            process = subprocess.Popen(["bash", "-c", script], env=env, cwd=DATA, start_new_session=True,
                                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL)
            subprocess.run([sys.executable, status_py, "set", build_id, f"pgid={process.pid}"], check=True)
            threading.Thread(target=process.wait, daemon=True).start()
            started.append({"target": target, "id": build_id})
    return {"started": started, "skipped": skipped}


def cancel(build_id):
    record = read_record(build_id)
    if not record:
        return {"error": "no such build"}
    if record.get("origin") != "web":
        return {"error": "started outside the dashboard (CI or a shell): cancel it there"}
    pgid = record.get("pgid")
    if record.get("state") in ("done", "failed", "cancelled") or not alive(pgid):
        return {"error": "not running"}
    try:
        os.killpg(int(pgid), signal.SIGTERM)
        for _ in range(20):
            time.sleep(0.5)
            if not alive(pgid):
                break
        else:
            os.killpg(int(pgid), signal.SIGKILL)
    except ProcessLookupError:
        pass
    subprocess.run([sys.executable, os.path.join(CHECKOUT, "lib", "status.py"), "end", build_id, "cancelled"])
    return {"cancelled": build_id}


def log_tail(build_id, lines):
    if not re.fullmatch(r"[\w.-]+", build_id or ""):
        return None
    path = os.path.join(BUILDS, build_id, "log.txt")
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - 400 * 1024))
            text = f.read().decode("utf-8", "replace")
    except OSError:
        return ""
    return "\n".join(text.splitlines()[-lines:])


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "airos-dashboard"

    def log_message(self, fmt, *args):
        pass

    def send(self, code, body, content_type="application/json"):
        data = body if isinstance(body, bytes) else (
            json.dumps(body).encode() if content_type == "application/json" else body.encode())
        self.send_response(code)
        self.send_header("Content-Type", content_type + ("; charset=utf-8" if "text" in content_type
                                                         or "json" in content_type else ""))
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(url.query)
        if url.path in ("/", "/index.html"):
            self.send(200, open(os.path.join(HERE, "index.html"), "rb").read(), "text/html")
        elif url.path == "/api/status":
            self.send(200, status())
        elif url.path == "/api/log":
            text = log_tail(query.get("id", [""])[0], min(int(query.get("lines", ["200"])[0]), 2000))
            if text is None:
                self.send(400, {"error": "bad id"})
            else:
                self.send(200, text, "text/plain")
        else:
            self.send(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return self.send(400, {"error": "bad JSON"})
        url = urllib.parse.urlparse(self.path)
        if url.path == "/api/build":
            targets = [t for t in body.get("targets", []) if t in TARGETS]
            if not targets:
                return self.send(400, {"error": "no targets"})
            self.send(200, start_builds(targets, bool(body.get("clean"))))
        elif url.path == "/api/cancel":
            self.send(200, cancel(str(body.get("id", ""))))
        else:
            self.send(404, {"error": "not found"})


def main():
    os.makedirs(BUILDS, exist_ok=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"air/OS dashboard on 127.0.0.1:{PORT}, builds from {CHECKOUT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

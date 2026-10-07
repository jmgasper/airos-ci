#!/usr/bin/env python3
"""Records of image builds, for the build dashboard (dashboard/server.py).

Each build has a directory $AIROS_DATA/builds/<id> with status.json and the
build's output, log.txt. images/build-image.sh and images/smoke-test.sh keep
it up to date whoever started them (the dashboard, CI, a shell);
$AIROS_DATA/builds/current-<target> names the build of a target in progress.

  status.py begin TARGET [--origin ORIGIN] [--clean] [--ref REF]
                                      prints the new build's id
  status.py stage ID NAME [DETAIL]    the build has reached a stage
  status.py set ID KEY=VALUE...       more facts about it
  status.py end ID STATE [KEY=VALUE...]
                                      STATE: built (image published, the smoke
                                      test still to come), done, failed,
                                      cancelled
  status.py current TARGET            prints the id of the target's build in
                                      progress, if any
"""
import datetime
import fcntl
import json
import os
import socket
import sys

DATA = os.environ.get("AIROS_DATA", "/data2/airos")
BUILDS = os.path.join(DATA, "builds")
KEEP = 60


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def path(build_id):
    return os.path.join(BUILDS, build_id, "status.json")


def update(build_id, change):
    """Apply change(record) to a build's record under a lock, atomically."""
    p = path(build_id)
    with open(p + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        record = json.load(open(p)) if os.path.exists(p) else {}
        change(record)
        tmp = p + ".tmp"
        with open(tmp, "w") as f:
            json.dump(record, f, indent=1)
        os.replace(tmp, p)
    return record


def parse_pairs(pairs):
    out = {}
    for pair in pairs:
        key, _, value = pair.partition("=")
        out[key] = value
    return out


def current_link(target):
    return os.path.join(BUILDS, f"current-{target}")


def prune():
    """Keep the newest KEEP finished builds."""
    entries = sorted(e for e in os.listdir(BUILDS) if not e.startswith("current-"))
    finished = []
    for entry in entries:
        try:
            state = json.load(open(path(entry))).get("state")
        except (OSError, ValueError):
            continue
        if state in ("done", "failed", "cancelled"):
            finished.append(entry)
    for entry in finished[:-KEEP]:
        d = os.path.join(BUILDS, entry)
        for name in os.listdir(d):
            os.unlink(os.path.join(d, name))
        os.rmdir(d)


def begin(args):
    target, origin, clean, ref = args[0], "shell", False, "origin/master"
    rest = args[1:]
    while rest:
        option = rest.pop(0)
        if option == "--origin":
            origin = rest.pop(0)
        elif option == "--clean":
            clean = True
        elif option == "--ref":
            ref = rest.pop(0)
        else:
            sys.exit(f"unknown option {option}")
    os.makedirs(BUILDS, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    build_id = f"{stamp}-{target}"
    n = 1
    while os.path.exists(os.path.join(BUILDS, build_id)):
        n += 1
        build_id = f"{stamp}-{target}-{n}"
    os.makedirs(os.path.join(BUILDS, build_id))
    if origin == "shell" and os.environ.get("GITHUB_ACTIONS"):
        origin = "ci"

    def init(record):
        record.update({
            "id": build_id, "target": target, "origin": origin, "clean": clean, "ref": ref,
            "state": "waiting", "stage": "queued", "stages": [{"name": "queued", "start": now()}],
            "started": now(), "finished": None, "host": socket.gethostname(),
            "log": os.path.join(BUILDS, build_id, "log.txt"),
            "github_run": os.environ.get("GITHUB_RUN_ID"),
        })
    update(build_id, init)
    link = current_link(target)
    tmp = link + ".tmp"
    if os.path.lexists(tmp):
        os.unlink(tmp)
    os.symlink(build_id, tmp)
    os.replace(tmp, link)
    prune()
    print(build_id)


def stage(args):
    build_id, name = args[0], args[1]
    detail = args[2] if len(args) > 2 else None

    def change(record):
        if record.get("stage") == name:
            return
        if name == "queued" or name.startswith("waiting"):
            record["state"] = "waiting"
        elif record.get("state") == "waiting":
            record["state"] = "running"
        record["stage"] = name
        entry = {"name": name, "start": now()}
        if detail:
            entry["detail"] = detail
        record.setdefault("stages", []).append(entry)
    update(build_id, change)


def set_(args):
    values = parse_pairs(args[1:])
    update(args[0], lambda record: record.update(values))


def end(args):
    build_id, state = args[0], args[1]
    values = parse_pairs(args[2:])

    def change(record):
        record.update(values)
        record["state"] = state
        if state != "built":
            record["finished"] = now()
            record.setdefault("stages", []).append({"name": state, "start": now()})
    record = update(build_id, change)
    link = current_link(record.get("target", ""))
    if state != "built" and os.path.islink(link) and os.readlink(link) == build_id:
        os.unlink(link)


def current(args):
    link = current_link(args[0])
    if os.path.islink(link) and os.path.exists(path(os.readlink(link))):
        print(os.readlink(link))


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    commands = {"begin": begin, "stage": stage, "set": set_, "end": end, "current": current}
    command = commands.get(sys.argv[1])
    if not command:
        sys.exit(__doc__)
    command(sys.argv[2:])


if __name__ == "__main__":
    main()

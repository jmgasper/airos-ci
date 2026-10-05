#!/usr/bin/env python3
"""Create the air/OS forks of third-party components (forks/forks.json).

For every component this makes sure a repository exists under the owner
(a GitHub fork of the upstream, or an imported repository when the upstream is
not on GitHub), checks out `base` on a branch `branch`, commits the air/OS
changes (patch files from git, release tarballs, added files) one by one,
pushes the branch and records its commit in forks/forks.lock.json, which the
dependency builds pin to.

Run it where `gh` is logged in as the owner and git can push over ssh:

    forks/make-forks.py [--wave N] [--only NAME,...] [--force] [--workdir DIR]

A component whose branch is already recorded in the lock file and present on
GitHub is skipped unless --force is given.
"""
import argparse
import fnmatch
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
OWNER = os.environ.get("GITHUB_OWNER", "jmgasper")
TRAILER = "\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"


def run(cmd, cwd=None, check=True, capture=False, env=None, input=None):
    kw = dict(cwd=cwd, check=check, text=True, env=env, input=input)
    if capture:
        kw.update(stdout=subprocess.PIPE)
    print("  $", " ".join(cmd) if isinstance(cmd, list) else cmd, file=sys.stderr)
    r = subprocess.run(cmd, **kw)
    return r.stdout.strip() if capture else r.returncode


def gh(*args, check=True):
    return run(["gh", *args], capture=True, check=check)


def repo_exists(full):
    return subprocess.run(["gh", "api", f"repos/{full}"], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


class Sources:
    """Pinned git repositories that patch files are read from."""

    def __init__(self, spec, workdir):
        self.spec, self.workdir = spec, workdir

    def path(self, name):
        d = os.path.join(self.workdir, ".sources", name)
        if not os.path.isdir(d):
            run(["git", "clone", "-q", "--filter=blob:none", "--no-checkout",
                 f"https://github.com/{self.spec[name]['repo']}.git", d])
        ref = self.spec[name]["ref"]
        if subprocess.run(["git", "-C", d, "cat-file", "-e", f"{ref}^{{commit}}"],
                          stderr=subprocess.DEVNULL).returncode != 0:
            run(["git", "-C", d, "fetch", "-q", "--filter=blob:none", "origin"])
        return d

    def read(self, ref):
        name, path = ref.split(":", 1)
        d = self.path(name)
        return subprocess.run(["git", "-C", d, "show", f"{self.spec[name]['ref']}:{path}"],
                              check=True, stdout=subprocess.PIPE).stdout

    def describe(self, ref):
        name, path = ref.split(":", 1)
        return f"{self.spec[name]['repo']}@{self.spec[name]['ref'][:10]}:{path}"


def split_patch(data, prefix):
    """Keep only the file sections of a unified diff whose path starts with prefix."""
    text = data.decode("utf-8", "surrogateescape")
    sections = re.split(r"(?m)^(?=--- )", text)
    keep = [s for s in sections[1:]
            if re.match(r"--- (?:a/)?" + re.escape(prefix), s)]
    return "".join(keep).encode("utf-8", "surrogateescape")


def apply_patch(repo, data, message, origin):
    """git am for mbox patch sets, else patch(1) with the strip level that fits."""
    with tempfile.NamedTemporaryFile(suffix=".patch", delete=False) as f:
        f.write(data)
        name = f.name
    try:
        if re.search(rb"(?m)^From [0-9a-f]{40} ", data):
            run(["git", "am", "-q", "--keep-cr", "--committer-date-is-author-date", name], cwd=repo)
            return
        for level in (1, 2, 0, 3):
            if subprocess.run(["patch", f"-p{level}", "--dry-run", "-s", "-f", "-i", name],
                              cwd=repo, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                run(["patch", f"-p{level}", "-s", "-f", "--no-backup-if-mismatch", "-i", name], cwd=repo)
                break
        else:
            sys.exit(f"error: {origin} does not apply")
        commit(repo, message or f"air/OS: {os.path.basename(origin)}", origin)
    finally:
        os.unlink(name)


def commit(repo, message, origin):
    run(["git", "add", "-A"], cwd=repo)
    if run(["git", "diff", "--cached", "--quiet"], cwd=repo, check=False) == 0:
        print(f"  (no changes from {origin})", file=sys.stderr)
        return
    body = f"{message}\n\nFrom {origin}." + TRAILER
    run(["git", "commit", "-q", "-F", "-"], cwd=repo, input=body)


def fetch_tarball(url, sha256, cache):
    os.makedirs(cache, exist_ok=True)
    path = os.path.join(cache, os.path.basename(url))
    if not os.path.exists(path):
        print(f"  download {url}", file=sys.stderr)
        req = urllib.request.Request(url, headers={"User-Agent": "airos-ci"})
        with urllib.request.urlopen(req) as r, open(path + ".part", "wb") as f:
            shutil.copyfileobj(r, f)
        os.rename(path + ".part", path)
    digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
    if digest != sha256:
        sys.exit(f"error: {url}: sha256 {digest}, expected {sha256}")
    return path


def unpack_into(repo, tarball, into, strip=0, pick=None):
    with tempfile.TemporaryDirectory() as tmp:
        with tarfile.open(tarball) as t:
            t.extractall(tmp, filter="data")
        src = tmp
        for _ in range(strip):
            entries = os.listdir(src)
            if len(entries) != 1:
                sys.exit(f"error: cannot strip {tarball}: {entries}")
            src = os.path.join(src, entries[0])
        if pick:
            matches = [os.path.join(dp, d) for dp, dns, _ in os.walk(tmp) for d in dns
                       if fnmatch.fnmatch(os.path.relpath(os.path.join(dp, d), tmp), pick)]
            if len(matches) != 1:
                sys.exit(f"error: {pick} matches {matches} in {tarball}")
            src = matches[0]
        dest = os.path.normpath(os.path.join(repo, into))
        os.makedirs(dest, exist_ok=True)
        shutil.copytree(src, dest, dirs_exist_ok=True, symlinks=True)


def heredoc(script, target):
    """The text a shell script writes to `target` with cat > target <<'EOF'."""
    text = script.decode()
    m = re.search(r"cat > " + re.escape(target) + r" <<'?(\w+)'?\n(.*?)\n\1\n", text, re.S)
    if not m:
        sys.exit(f"error: no heredoc for {target}")
    return m.group(2) + "\n"


def make(c, sources, workdir, lock, force):
    name, repo_name = c["name"], c.get("repo", c["name"])
    full = f"{OWNER}/{repo_name}"
    branch = c["branch"]
    print(f"\n== {name} -> {full} {branch}", file=sys.stderr)
    if not force and name in lock and repo_exists(full) and \
            gh("api", f"repos/{full}/branches/{branch}", "--jq", ".commit.sha", check=False) == lock[name]["commit"]:
        print("  up to date", file=sys.stderr)
        return

    # 1. the repository
    if c["create"] == "fork":
        if not repo_exists(full):
            gh("repo", "fork", c["github"], "--clone=false", "--fork-name", repo_name)
            for _ in range(30):
                if repo_exists(full):
                    break
                time.sleep(2)
        upstream = c.get("upstream", f"https://github.com/{c['github']}.git")
    else:
        if not repo_exists(full):
            gh("repo", "create", full, "--public", "--description", c["description"])
        upstream = c.get("upstream")

    # 2. the working clone: commits and trees on demand (tree:0), objects of
    #    the checked-out tree only.
    d = os.path.join(workdir, repo_name)
    if not os.path.isdir(os.path.join(d, ".git")):
        os.makedirs(d, exist_ok=True)
        run(["git", "init", "-q"], cwd=d)
        run(["git", "remote", "add", "origin", f"git@github.com:{full}.git"], cwd=d)
        if upstream:
            run(["git", "remote", "add", "upstream", upstream], cwd=d)
        run(["git", "config", "remote.origin.promisor", "true"], cwd=d)
        run(["git", "config", "remote.origin.partialclonefilter", "blob:none"], cwd=d)
    run(["git", "reset", "-q", "--hard"], cwd=d, check=False)
    run(["git", "clean", "-qfdx"], cwd=d, check=False)

    base = c.get("base")
    if isinstance(base, dict):
        parent = lock[base["submodule_of"]]
        pdir = os.path.join(workdir, parent["repo"])
        line = run(["git", "ls-tree", parent["base_commit"], base["path"]], cwd=pdir, capture=True)
        base_rev = line.split()[2]
        fetch_ref = base_rev
    elif base:
        base_rev, fetch_ref = base, f"refs/tags/{base}:refs/tags/{base}"
    else:
        base_rev = None
    if base_rev:
        # Forks carry upstream's tags: fetch the base from the fork itself, so
        # the push afterwards knows the fork has it and sends only new commits.
        remote = "origin" if c["create"] == "fork" else "upstream"
        if subprocess.run(["git", "cat-file", "-e", f"{base_rev}^{{commit}}"], cwd=d,
                          stderr=subprocess.DEVNULL).returncode != 0:
            run(["git", "fetch", "-q", "--filter=blob:none", "--no-tags", remote, fetch_ref], cwd=d)
        base_commit = run(["git", "rev-parse", f"{base_rev}^{{commit}}"], cwd=d, capture=True)
        run(["git", "checkout", "-q", "-f", "-B", branch, base_commit], cwd=d)
    else:
        base_commit = None
        if run(["git", "rev-parse", "--verify", "-q", f"refs/heads/{branch}"], cwd=d,
               check=False, capture=True):
            run(["git", "checkout", "-q", "--detach"], cwd=d)
            run(["git", "branch", "-q", "-D", branch], cwd=d)
        run(["git", "checkout", "-q", "--orphan", branch], cwd=d)
        run(["git", "rm", "-rqf", "--ignore-unmatch", "."], cwd=d)

    # 3. the air/OS changes
    cache = os.path.join(workdir, ".cache")
    for p in c.get("patches", []):
        if "tarball" in p:
            path = fetch_tarball(p["tarball"], p["sha256"], cache)
            unpack_into(d, path, p.get("into", "."), p.get("strip", 0), p.get("pick"))
            commit(d, p["message"], f"{p['tarball']} (sha256 {p['sha256']})")
        elif "add" in p:
            target = os.path.join(d, p["add"])
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "w") as f:
                f.write(heredoc(sources.read(p["heredoc"]), p["add"]))
            commit(d, p["message"], sources.describe(p["heredoc"]))
        else:
            data = sources.read(p["from"])
            if "only" in p:
                data = split_patch(data, p["only"])
            apply_patch(d, data, p.get("message"), sources.describe(p["from"]))
    for path, sub in c.get("submodules", {}).items():
        run(["git", "config", "-f", ".gitmodules", f"submodule.{path}.url",
             f"https://github.com/{OWNER}/{sub}.git"], cwd=d)
        commit(d, f"Submodule {path} from {OWNER}/{sub}", "air/OS forks")
    if subprocess.run(["git", "rev-parse", "--verify", "-q", "HEAD"], cwd=d,
                      stdout=subprocess.DEVNULL).returncode != 0:
        sys.exit(f"error: {name}: nothing committed")

    # 4. publish and record
    run(["git", "push", "-q", "-f", "origin", f"{branch}:refs/heads/{branch}"], cwd=d)
    head = run(["git", "rev-parse", "HEAD"], cwd=d, capture=True)
    lock[name] = {"repo": repo_name, "url": f"https://github.com/{full}.git", "branch": branch,
                  "commit": head, "base": base_rev, "base_commit": base_commit,
                  "upstream": upstream}
    print(f"  {full} {branch} = {head[:12]}", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wave", type=int)
    ap.add_argument("--only")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--workdir", default=os.environ.get("AIROS_FORKS", "/mnt/HaikuWork/src/forks"))
    args = ap.parse_args()
    manifest = json.load(open(os.path.join(HERE, "forks.json")))
    lock_path = os.path.join(HERE, "forks.lock.json")
    lock = json.load(open(lock_path)) if os.path.exists(lock_path) else {}
    os.makedirs(args.workdir, exist_ok=True)
    sources = Sources(manifest["sources"], args.workdir)
    only = set(args.only.split(",")) if args.only else None
    for c in manifest["components"]:
        if args.wave is not None and c.get("wave") != args.wave:
            continue
        if only and c["name"] not in only:
            continue
        make(c, sources, args.workdir, lock, args.force)
        with open(lock_path, "w") as f:
            json.dump(lock, f, indent=2, sort_keys=True)
            f.write("\n")


if __name__ == "__main__":
    main()

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
CI_ROOT = os.path.dirname(HERE)
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
        if name == "ci":
            return CI_ROOT
        d = os.path.join(self.workdir, ".sources", name)
        if not os.path.isdir(d):
            run(["git", "clone", "-q", "--filter=blob:none", "--no-checkout",
                 f"https://github.com/{self.spec[name]['repo']}.git", d])
        ref = self.spec[name]["ref"]
        if subprocess.run(["git", "-C", d, "cat-file", "-e", f"{ref}^{{commit}}"],
                          stderr=subprocess.DEVNULL).returncode != 0:
            run(["git", "-C", d, "fetch", "-q", "--filter=blob:none", "origin"])
        return d

    def ref(self, name):
        # "ci:" is airos-ci itself, at its committed HEAD (so a patch must be in
        # git before a fork can use it).
        if name == "ci":
            return run(["git", "-C", CI_ROOT, "rev-parse", "HEAD"], capture=True)
        return self.spec[name]["ref"]

    def read(self, ref):
        name, path = ref.split(":", 1)
        d = self.path(name)
        return subprocess.run(["git", "-C", d, "show", f"{self.ref(name)}:{path}"],
                              check=True, stdout=subprocess.PIPE).stdout

    def describe(self, ref):
        name, path = ref.split(":", 1)
        repo = "jmgasper/airos-ci" if name == "ci" else self.spec[name]["repo"]
        return f"{repo}@{self.ref(name)[:10]}:{path}"


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
        if re.search(rb"(?m)^diff --git ", data) and subprocess.run(
                ["git", "apply", "--check", "--whitespace=nowarn", name], cwd=repo,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            run(["git", "apply", "--whitespace=nowarn", name], cwd=repo)
            commit(repo, message or f"air/OS: {os.path.basename(origin)}", origin)
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


def commit(repo, message, origin, everything=False):
    # --sparse: a sparse fork (WebKit) still records every file a patch made.
    # A release tarball goes in whole (-f): its generated files (configure,
    # Makefile.in) are what the projects' .gitignore leaves out.
    run(["git", "add", "-A", "--sparse", *(["-f"] if everything else [])], cwd=repo)
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

    # 0. a branch pushed as it is from a tree with tested history (the X399's
    #    Mesa trees): only checked and recorded.
    if c["create"] == "existing":
        sha = gh("api", f"repos/{full}/branches/{branch}", "--jq", ".commit.sha", check=False)
        if not re.fullmatch(r"[0-9a-f]{40}", sha or ""):
            sys.exit(f"error: {full} has no branch {branch}; push it first ({c.get('origin', '')})")
        lock[name] = {"repo": repo_name, "url": f"https://github.com/{full}.git", "branch": branch,
                      "commit": sha, "base": c.get("base"), "base_commit": c.get("base"),
                      "upstream": c.get("upstream")}
        print(f"  {full} {branch} = {sha[:12]} (existing branch)", file=sys.stderr)
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

    # 1b. nothing to commit: point the branch at the pinned upstream commit
    #     through the API, without cloning (raspberrypi/firmware is many GB).
    if c["create"] == "fork" and not c.get("patches") and not c.get("submodules") \
            and isinstance(c.get("base"), str):
        base = c["base"]
        if re.fullmatch(r"[0-9a-f]{40}", base):
            commit_sha = base
        else:
            ref = json.loads(gh("api", f"repos/{c['github']}/git/refs/tags/{base}"))
            commit_sha = ref["object"]["sha"]
            if ref["object"]["type"] == "tag":
                commit_sha = json.loads(gh("api", f"repos/{c['github']}/git/tags/{commit_sha}"))["object"]["sha"]
        if gh("api", f"repos/{full}/branches/{branch}", "--jq", ".commit.sha", check=False) != commit_sha:
            gh("api", "-X", "DELETE", f"repos/{full}/git/refs/heads/{branch}", check=False)
            # Through the API when possible. GitHub refuses it (404) for a commit
            # whose tree has .github/workflows unless the token has the workflow
            # scope, so fall back to pushing the ref over ssh (nothing to upload:
            # the fork has the commit). A new fork is created asynchronously,
            # hence the retries.
            for attempt in range(30):
                gh("api", "-X", "POST", f"repos/{full}/git/refs", "-f", f"ref=refs/heads/{branch}",
                   "-f", f"sha={commit_sha}", check=False)
                if gh("api", f"repos/{full}/branches/{branch}", "--jq", ".commit.sha",
                      check=False) == commit_sha:
                    break
                with tempfile.TemporaryDirectory(dir=workdir) as tmp:
                    run(["git", "init", "-q", tmp])
                    if run(["git", "-C", tmp, "fetch", "-q", "--depth=1", "--filter=blob:none",
                            f"git@github.com:{full}.git", commit_sha], check=False) == 0 and \
                            run(["git", "-C", tmp, "push", "-q", f"git@github.com:{full}.git",
                                 f"{commit_sha}:refs/heads/{branch}"], check=False) == 0:
                        break
                time.sleep(5)
            else:
                sys.exit(f"error: cannot create {branch} in {full}")
        lock[name] = {"repo": repo_name, "url": f"https://github.com/{full}.git", "branch": branch,
                      "commit": commit_sha, "base": base, "base_commit": commit_sha,
                      "upstream": f"https://github.com/{c['github']}.git"}
        print(f"  {full} {branch} = {commit_sha[:12]} (no changes; branch made through the API)",
              file=sys.stderr)
        return

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
    elif base and re.fullmatch(r"[0-9a-f]{40}", base):
        base_rev, fetch_ref = base, base
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
            depth = ["--depth=1"] if c.get("shallow") else []
            run(["git", "fetch", "-q", "--filter=blob:none", "--no-tags", *depth, remote, fetch_ref], cwd=d)
        if c.get("sparse"):
            # Huge trees (WebKit): check out only what the patches touch.
            paths = set()
            for p in c.get("patches", []):
                if "from" in p:
                    data = sources.read(p["from"])
                    # "diff --git a/X b/X" (binary and mode-only changes have
                    # nothing else), with names that may have spaces
                    # ("Directory Listing Template.html"), and "--- a/X" /
                    # "+++ b/Y" for renames.
                    for m in re.finditer(rb"(?m)^diff --git a/(.+) b/(.+)$", data):
                        line = m.group(0)[len(b"diff --git a/"):]
                        half = (len(line) - len(b" b/")) // 2
                        if line[:half] == line[half + 3:]:
                            paths.add(line[:half].decode())
                        else:
                            paths.update({m.group(1).split(b" ")[0].decode(),
                                          m.group(2).split(b" ")[-1].decode()})
                    for m in re.finditer(rb"(?m)^(?:---|\+\+\+) [ab]/(.+?)\t?$", data):
                        paths.add(m.group(1).decode())
            paths = {"/" + re.sub(r"([\\*?\[\]!# ])", r"\\\1", path) for path in paths}
            run(["git", "sparse-checkout", "set", "--no-cone", "--stdin"], cwd=d,
                input="\n".join(sorted(paths)) + "\n")
            print(f"  sparse checkout of {len(paths)} paths", file=sys.stderr)
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
            commit(d, p["message"], f"{p['tarball']} (sha256 {p['sha256']})", everything=True)
        elif "git" in p:
            # files from a pinned commit of another git repository (sparse,
            # blobs only for the matching paths), at the same paths
            with tempfile.TemporaryDirectory(dir=workdir) as tmp:
                run(["git", "init", "-q", tmp])
                run(["git", "-C", tmp, "remote", "add", "origin", p["git"]])
                run(["git", "-C", tmp, "config", "core.sparseCheckout", "true"])
                run(["git", "-C", tmp, "sparse-checkout", "set", "--no-cone", *p["paths"]])
                run(["git", "-C", tmp, "fetch", "-q", "--depth", "1", "--filter=blob:none",
                     "origin", p["commit"]])
                run(["git", "-C", tmp, "checkout", "-q", "FETCH_HEAD"])
                copied = 0
                for dp, dns, fns in os.walk(tmp):
                    dns[:] = [x for x in dns if x != ".git"]
                    for fn in fns:
                        src = os.path.join(dp, fn)
                        rel = os.path.relpath(src, tmp)
                        dst = os.path.join(d, p.get("into", "."), rel)
                        os.makedirs(os.path.dirname(dst), exist_ok=True)
                        if os.path.islink(src):
                            if os.path.lexists(dst):
                                os.remove(dst)
                            os.symlink(os.readlink(src), dst)
                        else:
                            shutil.copy2(src, dst)
                        copied += 1
                if not copied:
                    sys.exit(f"error: no files matched {p['paths']} in {p['git']}@{p['commit']}")
            commit(d, p["message"], f"{p['git']} at {p['commit']}")
        elif "overlay" in p:
            # copy a directory tree from a pinned source repository into the fork
            src_name, path = p["overlay"].split(":", 1)
            src = sources.path(src_name)
            dest = os.path.join(d, p["into"])
            os.makedirs(dest, exist_ok=True)
            archive = subprocess.run(["git", "-C", src, "archive", sources.spec[src_name]["ref"], path],
                                     check=True, stdout=subprocess.PIPE).stdout
            with tempfile.TemporaryDirectory() as tmp:
                subprocess.run(["tar", "-x", "-C", tmp], input=archive, check=True)
                shutil.copytree(os.path.join(tmp, path), dest, dirs_exist_ok=True)
            commit(d, p["message"], sources.describe(p["overlay"]))
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
    if c.get("shallow") and base_commit:
        # A shallow clone cannot tell that GitHub has the base tree, so the
        # push would upload all of it (WebKit: 700,000 objects). A tag at the
        # base, made through the API, is advertised to the push, which then
        # sends only what the patches changed.
        tag = f"refs/tags/airos-base-{base_commit[:12]}"
        if subprocess.run(["gh", "api", f"repos/{full}/git/{tag[5:]}"], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode != 0:
            gh("api", "-X", "POST", f"repos/{full}/git/refs", "-f", f"ref={tag}", "-f", f"sha={base_commit}")
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
        # Re-read the lock before writing it: another make-forks.py may have
        # recorded other forks since this one started.
        current = json.load(open(lock_path)) if os.path.exists(lock_path) else {}
        if c["name"] in lock:
            current[c["name"]] = lock[c["name"]]
        lock = current
        with open(lock_path, "w") as f:
            json.dump(lock, f, indent=2, sort_keys=True)
            f.write("\n")


if __name__ == "__main__":
    main()

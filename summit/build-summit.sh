#!/usr/bin/env bash
# summit/build-summit.sh ARCH [SUMMIT_DIR]
#
# The Summit pipeline for ARCH, from a Summit checkout (default
# $GITHUB_WORKSPACE):
#
#   1. summit/build-deps.sh    the engine's libraries, from the jmgasper forks
#   2. summit/build-engine.sh  WebKit with Summit's Haiku port (incremental)
#   3. the summit_webkit and summit packages (apps/build-app-packages.sh),
#      into the air/OS package pool, from which the images take them
#   4. the engine, as the summit_webkit package installs it, into DEPS, so
#      Natter's builds link it for Slack web sign-in
#
# Writes the package paths to $OUT_LIST (default $RUNNER_TEMP/packages.txt).
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"

ARCH=${1:?usage: build-summit.sh x86_64|arm64 [SUMMIT_DIR]}
SUMMIT_DIR=$(cd "${2:-${GITHUB_WORKSPACE:?no Summit checkout}}" && pwd)
if [[ ${AIROS_SUMMIT_LOCKED:-} != summit-$ARCH ]]; then
	exec env AIROS_SUMMIT_LOCKED=summit-$ARCH flock "$AIROS_LOCKS/summit-$ARCH.lock" "$0" "$ARCH" "$SUMMIT_DIR"
fi
JOBTMP=${RUNNER_TEMP:-$AIROS_WORK/tmp-summit}
export OUT_LIST=${OUT_LIST:-$JOBTMP/packages.txt}
mkdir -p "$JOBTMP"

"$AIROS_CI/summit/build-deps.sh" "$ARCH"
"$AIROS_CI/summit/build-engine.sh" "$ARCH" "$SUMMIT_DIR"

note "packages"
before=$(wc -l < "$OUT_LIST" 2>/dev/null || echo 0)
"$AIROS_CI/apps/ci-build-app.sh" "$ARCH" summit_webkit,summit summit "$SUMMIT_DIR"
engine=$(tail -n +"$((before + 1))" "$OUT_LIST" | grep '/summit_webkit-[^/]*\.hpkg$' | tail -n 1)
[[ -n $engine ]] || die "no summit_webkit package was made"

note "engine for app builds"
# DEPS is read by app builds under the shared haiku-ARCH lock.
DEPS=${DEPS:-$AIROS_ROOT/deps/$ARCH/boot/system}
. "$AIROS_SDK/$ARCH/env.sh"
with_lock "haiku-$ARCH" bash -c '
	set -e
	rm -rf "$1/lib/summit-webkit" "$1/develop/headers/summit-webkit"
	"$2" extract -C "$1" "$3"
	rm -f "$1/.PackageInfo"
	rm -rf "$1/documentation/packages/summit_webkit"
' _ "$DEPS" "$TOOLS/package/package" "$engine"
echo "$(basename "$engine") -> $DEPS/lib/summit-webkit"

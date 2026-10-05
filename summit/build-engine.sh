#!/usr/bin/env bash
# summit/build-engine.sh ARCH SUMMIT_DIR
#
# Summit's WebKit engine for ARCH, from the Summit checkout SUMMIT_DIR:
#
#   source  upstream WebKit at the commit Summit pins (engine/sources.lock.json),
#           fetched from jmgasper/WebKit, with Summit's Haiku port
#           (engine/patches/0001-haiku-port.patch) and its arm64 changes
#           (engine/arm64/patches/webkit-arm64-haiku.patch: arm64 code, and a
#           path without Skia; neither changes an x86_64 build)
#   config  Summit's GL + WebRTC engine (engine/arm64/rpi4-gl/init-cache-rtc.cmake)
#           with Skia, GL compositing, WebGL and asynchronous scrolling, as
#           the Raspberry Pi's engine is built (haiku: docs/rpi4/SUMMIT.md);
#           x86_64 adds smooth scrolling, as Summit's x86 engine has it
#   libs    summit/build-deps.sh's prefix and the backtrace() shim of
#           engine/arm64/execinfo
#
# The source tree ($AIROS_SRC/webkit-ARCH; sparse: no LayoutTests, JSTests,
# PerformanceTests, ManualTests or Websites) and the build directory
# ($AIROS_BUILD/webkit-ARCH) persist. The patched tree is a commit made in a
# scratch index, and checking it out rewrites only the files that differ from
# the last build's, so ninja rebuilds only what the change reaches.
#
# ENGINE_JOBS: compile jobs (default: one per 2.5 GB of memory, at most nproc;
# WebCore's unified sources take about 2 GB each).
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"

ARCH=${1:?usage: build-engine.sh x86_64|arm64 SUMMIT_DIR}
SUMMIT_DIR=$(cd "${2:?usage: build-engine.sh x86_64|arm64 SUMMIT_DIR}" && pwd)
if [[ ${AIROS_SUMMIT_LOCKED:-} != summit-$ARCH ]]; then
	exec env AIROS_SUMMIT_LOCKED=summit-$ARCH flock "$AIROS_LOCKS/summit-$ARCH.lock" "$0" "$@"
fi
. "$AIROS_CI/summit/lib.sh"
. "$AIROS_CI/lib/fork.sh"
summit_sdk

P=$SUMMIT_ROOT/deps
TC=$SUMMIT_ROOT/toolchain.cmake
[[ -f $TC && -f $P/lib/pkgconfig/icu-uc.pc ]] || die "no Summit libraries for $ARCH; run summit/build-deps.sh $ARCH"
SRC=$AIROS_SRC/webkit-$ARCH
B=$AIROS_BUILD/webkit-$ARCH
mem_gb=$(awk '/MemTotal/ {print int($2 / 1048576)}' /proc/meminfo)
jobs=$(( mem_gb * 2 / 5 ))
(( jobs <= $(nproc) )) || jobs=$(nproc)
JOBS=${ENGINE_JOBS:-$jobs}
summit_commit=$(git -C "$SUMMIT_DIR" rev-parse HEAD)

note "backtrace() shim"
# WebCore links libexecinfo; Haiku has no backtrace().
x=$SUMMIT_DIR/engine/arm64/execinfo
${CROSS}gcc --sysroot="$SYSROOT" -O2 -fPIC -shared "$x/execinfo.c" -o "$P/lib/libexecinfo.so.1.1.new" \
	-Wl,-soname,libexecinfo.so.1 -Wl,--hash-style=both -Wl,-Bsymbolic-functions
# replaced only when it changed, so the engine does not relink for nothing
cmp -s "$P/lib/libexecinfo.so.1.1.new" "$P/lib/libexecinfo.so.1.1" \
	&& rm "$P/lib/libexecinfo.so.1.1.new" || mv "$P/lib/libexecinfo.so.1.1.new" "$P/lib/libexecinfo.so.1.1"
ln -sfn libexecinfo.so.1.1 "$P/lib/libexecinfo.so.1"
ln -sfn libexecinfo.so.1 "$P/lib/libexecinfo.so"
cmp -s "$x/execinfo.h" "$P/include/execinfo.h" || cp "$x/execinfo.h" "$P/include/"

note "source"
base=$(json "$SUMMIT_DIR/engine/sources.lock.json" 'd["upstream"]["commit"]')
patches=("$SUMMIT_DIR/engine/patches/0001-haiku-port.patch"
	"$SUMMIT_DIR/engine/arm64/patches/webkit-arm64-haiku.patch")
url=$(fork_info webkit url)
if [[ ! -d $SRC/.git ]]; then
	rm -rf "$SRC"
	git init -q "$SRC"
	git -C "$SRC" remote add origin "$url"
	git -C "$SRC" config remote.origin.promisor true
	git -C "$SRC" config remote.origin.partialclonefilter blob:none
	git -C "$SRC" config core.sparseCheckout true
	printf '/*\n!/LayoutTests/\n!/JSTests/\n!/PerformanceTests/\n!/ManualTests/\n!/Websites/\n' \
		> "$SRC/.git/info/sparse-checkout"
fi
git -C "$SRC" cat-file -e "$base^{commit}" 2>/dev/null \
	|| git -C "$SRC" fetch -q --depth=1 --filter=blob:none origin "$base"
key=$( { echo "$base"; cat "${patches[@]}"; } | sha256sum | cut -c1-16)
ref=refs/airos/summit-$key
if ! patched=$(git -C "$SRC" rev-parse -q --verify "$ref^{commit}"); then
	# The base versions of the patched files, in one fetch (git apply --cached
	# would otherwise fetch them one at a time).
	python3 - "$SRC" "$base" "${patches[@]}" <<'EOF' | git -C "$SRC" -c fetch.negotiationAlgorithm=noop \
			fetch -q --no-tags --no-write-fetch-head --filter=blob:none origin --stdin
import re, subprocess, sys
src, base, patches = sys.argv[1], sys.argv[2], sys.argv[3:]
paths = set()
for patch in patches:
    for m in re.finditer(rb"(?m)^--- a/(.+?)\t?$", open(patch, "rb").read()):
        paths.add(m.group(1).decode())
out = subprocess.run(["git", "-C", src, "ls-tree", "-r", "-z", base, "--", *sorted(paths)],
                     check=True, stdout=subprocess.PIPE).stdout
print("\n".join(e.split(b"\t")[0].split()[2].decode() for e in out.split(b"\0") if e))
EOF
	index=$(mktemp "$AIROS_WORK/webkit-index-XXXXXX")
	GIT_INDEX_FILE=$index git -C "$SRC" read-tree "$base"
	for patch in "${patches[@]}"; do
		GIT_INDEX_FILE=$index git -C "$SRC" apply --cached --whitespace=nowarn "$patch" \
			|| die "$(basename "$patch") does not apply to WebKit ${base:0:12}"
	done
	# --missing-ok: a partial clone would otherwise fetch every blob it lacks, one by one
	tree=$(GIT_INDEX_FILE=$index git -C "$SRC" write-tree --missing-ok)
	rm -f "$index"
	patched=$(GIT_AUTHOR_NAME="air/OS CI" GIT_AUTHOR_EMAIL=ci@airos.invalid \
		GIT_COMMITTER_NAME="air/OS CI" GIT_COMMITTER_EMAIL=ci@airos.invalid \
		git -C "$SRC" commit-tree "$tree" -p "$base" \
		-m "Summit engine: WebKit ${base:0:12} with Summit ${summit_commit:0:12}'s patches")
	git -C "$SRC" update-ref "$ref" "$patched"
fi
git -C "$SRC" checkout -q -f --detach "$patched"
# keep the last three patched trees
git -C "$SRC" for-each-ref --sort=-committerdate --format='%(refname)' refs/airos/ | tail -n +4 \
	| xargs -r -n1 git -C "$SRC" update-ref -d
# The jmgasper/WebKit branch is the published copy of this tree.
fork_tree=$(git -C "$SRC" rev-parse -q --verify "$(fork_info webkit commit)^{tree}" 2>/dev/null || true)
if [[ -z $fork_tree ]]; then
	git -C "$SRC" fetch -q --depth=3 --filter=blob:none origin "$(fork_info webkit commit)" 2>/dev/null || true
	fork_tree=$(git -C "$SRC" rev-parse -q --verify "$(fork_info webkit commit)^{tree}" 2>/dev/null || true)
fi
if [[ $fork_tree == "$(git -C "$SRC" rev-parse "$patched^{tree}")" ]]; then
	echo "WebKit ${base:0:12} + Summit's patches = jmgasper/WebKit $(fork_info webkit branch) $(fork_info webkit commit | cut -c1-12)"
else
	echo "warning: Summit ${summit_commit:0:12}'s engine patches differ from jmgasper/WebKit $(fork_info webkit branch);" \
		"update it with forks/make-forks.py --only webkit --force (after moving the summit source ref)" >&2
fi

note "configure"
private=$SYSROOT/boot/system/develop/headers/private
export CPATH=$private/netservices:$private/libroot:$private/shared:$private/system:$private/system/arch
export PKG_CONFIG_LIBDIR=$P/lib/pkgconfig PKG_CONFIG_PATH= PKG_CONFIG_SYSROOT_DIR=
options=(-DUSE_HAIKU_GL_COMPOSITING=ON -DUSE_SKIA=ON -DENABLE_WEBGL=ON -DENABLE_ASYNC_SCROLLING=ON)
[[ $ARCH != x86_64 ]] || options+=(-DENABLE_SMOOTH_SCROLLING=ON)
mkdir -p "$B"
cmake -S "$SRC" -B "$B" -G Ninja -C "$SUMMIT_DIR/engine/arm64/rpi4-gl/init-cache-rtc.cmake" \
	-DCMAKE_TOOLCHAIN_FILE="$TC" -DCMAKE_BUILD_TYPE=Release "${options[@]}" > "$B/configure.log" 2>&1 \
	|| { tail -40 "$B/configure.log"; die "WebKit configure failed (log: $B/configure.log)"; }
grep -E "^-- (Enabled|  ENABLE_WEB_RTC|  USE_SKIA|  ENABLE_WEBGL )" "$B/configure.log" | head -10 || true

note "build ($JOBS jobs)"
# One big engine build at a time on the host: each takes about all of its
# memory. A few steps (CMake rewrites some inputs on every configure) do not
# wait for another engine's build.
start=$SECONDS
lock=(flock "$AIROS_LOCKS/webkit-build.lock")
(( $(ninja -C "$B" -n 2>/dev/null | grep -c '^\[') > 100 )) || lock=()
if ! "${lock[@]}" nice -n 10 ninja -C "$B" -j"$JOBS" > "$B/build.log" 2>&1; then
	grep -m 5 -B 2 -A 12 -E "error:|FAILED:" "$B/build.log" | head -80
	die "WebKit build failed (log: $B/build.log)"
fi
echo "built in $(( (SECONDS - start) / 60 )) min: $(grep -c '^\[' "$B/build.log" || true) steps"
for file in lib/libWebKit.so.1 bin/WebProcess bin/NetworkProcess; do
	[[ -e $B/$file ]] || die "the engine build has no $file"
done
cat > "$B/engine.json" <<EOF
{
 "webkit": {"repository": "$url", "base": "$base", "patched_tree": "$(git -C "$SRC" rev-parse "$patched^{tree}")"},
 "summit": "$summit_commit",
 "haiku": "$HAIKU_REVISION",
 "arch": "$ARCH"
}
EOF
echo "ENGINE_DIR=$B" | tee -a "${GITHUB_OUTPUT:-/dev/null}"

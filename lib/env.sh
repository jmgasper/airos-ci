# airos-ci common environment; source it from every script:
#   . "$(dirname "$0")/../lib/env.sh"
#
# Layout on the build server (airos-build). Everything can be overridden from
# the environment, so the scripts also run elsewhere.

AIROS_CI=${AIROS_CI:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
AIROS_ROOT=${AIROS_ROOT:-/data1/airos}        # sources, build trees, SDKs
AIROS_DATA=${AIROS_DATA:-/data2/airos}        # package pool, images, caches, logs

AIROS_SRC=${AIROS_SRC:-$AIROS_ROOT/src}           # git clones (fetch-only) and worktrees
AIROS_BUILD=${AIROS_BUILD:-$AIROS_ROOT/build}     # Haiku generated/ build directories
AIROS_SDK=${AIROS_SDK:-$AIROS_ROOT/sdk}           # <arch>/{env.sh,sysroot}: cross SDKs
AIROS_TOOLCHAIN=${AIROS_TOOLCHAIN:-$AIROS_ROOT/toolchain}  # jam and other host tools
AIROS_PACKAGES=${AIROS_PACKAGES:-$AIROS_DATA/packages}     # <arch>/*.hpkg: the air/OS package pool
AIROS_ARTIFACTS=${AIROS_ARTIFACTS:-$AIROS_DATA/artifacts}  # images, published over HTTP
AIROS_CACHE=${AIROS_CACHE:-$AIROS_DATA/cache}              # downloads, ccache
AIROS_LOCKS=${AIROS_LOCKS:-$AIROS_DATA/locks}
AIROS_WORK=${AIROS_WORK:-$AIROS_DATA/work}                 # per-job scratch space

GITHUB_OWNER=${GITHUB_OWNER:-jmgasper}
HAIKU_REPO=${HAIKU_REPO:-https://github.com/$GITHUB_OWNER/haiku.git}
BUILDTOOLS_REPO=${BUILDTOOLS_REPO:-https://github.com/$GITHUB_OWNER/buildtools.git}

JOBS=${JOBS:-$(nproc)}
export PATH="$AIROS_TOOLCHAIN/bin:$PATH"
export TMPDIR=${TMPDIR_OVERRIDE:-$AIROS_DATA/tmp}
mkdir -p "$TMPDIR" "$AIROS_LOCKS" 2>/dev/null || true

die() { echo "error: $*" >&2; exit 1; }
note() { printf '\n== %s\n' "$*"; }

# with_lock NAME COMMAND...: run COMMAND holding an exclusive lock, so two jobs
# never write the same build tree (runners for different repos share the host).
with_lock() {
	local name=$1
	shift
	flock "$AIROS_LOCKS/$name.lock" "$@"
}

# haiku_arch_triplet ARCH
haiku_triplet() {
	case $1 in
		x86_64) echo x86_64-unknown-haiku ;;
		arm64) echo aarch64-unknown-haiku ;;
		*) die "unknown architecture $1" ;;
	esac
}

# json FILE EXPR: read a value from a JSON manifest (python3 is always there).
json() {
	python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=eval(sys.argv[2],{"d":d}); print(v if not isinstance(v,(list,dict)) else json.dumps(v))' "$1" "$2"
}

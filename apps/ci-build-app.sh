#!/usr/bin/env bash
# ci-build-app.sh ARCH APP REPO_DIR [SOURCE_DIR]
#
# Build one application for ARCH from a checkout (default: $GITHUB_WORKSPACE)
# with build-app-packages.sh, then add the package to the air/OS package pool
# ($AIROS_PACKAGES/ARCH), from which the image builds take it.
#
#   APP       build-app-packages.sh name: amp airtime airshot burrow clipper
#             kiri natter turbochook lcdmonitor airpins
#   REPO_DIR  the directory name build-app-packages.sh knows the repository by
#             (tasamp for Amp, airTime, airShot, turbochook, ...)
#
# Writes the package path to $OUT_LIST (default $RUNNER_TEMP/packages.txt).
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"

ARCH=${1:?usage: ci-build-app.sh ARCH APP REPO_DIR [SOURCE_DIR]}
APP=${2:?app}
REPO_DIR=${3:?repository directory name}
SOURCE=${4:-${GITHUB_WORKSPACE:?no source directory}}
JOBTMP=${RUNNER_TEMP:-$AIROS_WORK/tmp-$APP}
OUT_LIST=${OUT_LIST:-$JOBTMP/packages.txt}

apps=$JOBTMP/apps-$ARCH
out=$JOBTMP/out-$ARCH
rm -rf "$apps" "$out"
mkdir -p "$apps" "$out"
ln -s "$SOURCE" "$apps/$REPO_DIR"

# One build tree per repository and architecture, kept between runs so make
# only rebuilds what changed.
AIROS_ARCH=$ARCH APPS=$apps APPBUILD=$AIROS_WORK/appbuild-$ARCH/$APP \
	"$AIROS_CI/apps/build-app-packages.sh" "$out" "$APP"

shopt -s nullglob
packages=("$out"/*-"$ARCH".hpkg)
[[ ${#packages[@]} -gt 0 ]] || die "no $ARCH package was made"
mkdir -p "$AIROS_PACKAGES/$ARCH"
for package in "${packages[@]}"; do
	name=$(basename "$package")
	base=${name%%-[0-9]*}
	# The pool keeps one version of each package: the newest build.
	with_lock packages-$ARCH bash -c '
		rm -f "$1/$2"-[0-9]*-"$3".hpkg
		cp "$4" "$1/"' _ "$AIROS_PACKAGES/$ARCH" "$base" "$ARCH" "$package"
	echo "$package" >> "$OUT_LIST"
	echo "pool: $AIROS_PACKAGES/$ARCH/$name"
done

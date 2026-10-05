#!/usr/bin/env bash
# build-image.sh TARGET [REF]
#
# Build an air/OS release image from jmgasper/haiku at REF (default
# origin/master) with the tree's CI image definitions
# (tools/airos/ci/UserBuildConfig) and the packages in the air/OS package pool:
#
#   x86_64  airos-x86_64.iso   hybrid ISO (USB stick or CD), EFI and BIOS
#   arm64   airos-arm64.iso    hybrid ISO with an EFI system partition
#                              (ROCK 5 ITX and other UEFI arm64 machines)
#   rpi4    airos-rpi4.img     Raspberry Pi 4 SD card image, boots directly
#
# The image (xz-compressed, with SHA-256 sums and a manifest of everything that
# went in) is published to $AIROS_ARTIFACTS/images/TARGET/<stamp>/ and
# $AIROS_ARTIFACTS/images/TARGET/latest, which the build server serves over
# HTTP.
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"

TARGET=${1:?usage: build-image.sh x86_64|arm64|rpi4 [ref]}
REF=${2:-origin/master}
case $TARGET in
	x86_64) ARCH=x86_64 PROFILE=nightly-airos-x86_64 JAM_TARGET= IMAGE=airos-x86_64.iso ;;
	arm64)  ARCH=arm64 PROFILE=airos-arm64 JAM_TARGET= IMAGE=airos-arm64.iso ;;
	rpi4)   ARCH=arm64 PROFILE=airos-rpi4 JAM_TARGET=airos-rpi-image IMAGE=airos-rpi4.img ;;
	*) die "unknown target $TARGET" ;;
esac
# The whole build holds the architecture's lock: it updates the SDK's worktree
# and build directory (the Pi build shares the arm64 worktree and compiler).
if [[ ${AIROS_LOCKED:-} != haiku-$ARCH ]]; then
	exec env AIROS_LOCKED=haiku-$ARCH flock "$AIROS_LOCKS/haiku-$ARCH.lock" "$0" "$@"
fi

# The applications every image carries (Summit is the default browser).
IMAGE_APPS=(summit summit_webkit amp airtime kiri clipper airshot turbochook burrow)

# 1. Haiku at REF: the SDK build updates the worktree and the build directory
#    of the architecture and builds haiku.hpkg and the host tools.
"$AIROS_CI/sdk/build-sdk.sh" "$ARCH" "$REF"
. "$AIROS_SDK/$ARCH/env.sh"

BUILD=$HAIKU_BUILD
if [[ $TARGET == rpi4 ]]; then
	# Its own build directory (its own UserBuildConfig) with the arm64 compiler.
	BUILD=$AIROS_BUILD/haiku-rpi4
fi

WORK=$AIROS_WORK/image-$TARGET
rm -rf "$WORK"
mkdir -p "$WORK"/{packages,libs,egl,demos,firmware}

# 2. The inputs.
note "inputs"
pool=$AIROS_PACKAGES/$ARCH
any=$AIROS_PACKAGES/any
missing=()
for app in "${IMAGE_APPS[@]}"; do
	file=$(ls "$pool/$app"-[0-9]*-"$ARCH".hpkg 2>/dev/null | head -n 1 || true)
	if [[ -n $file ]]; then cp "$file" "$WORK/packages/"; else missing+=("$app"); fi
done
# Libraries and system components CI builds (airos_*, rock5_ffmpeg,
# wpa_supplicant, rock5_glinfo, ...) and architecture-neutral firmware.
for file in "$pool"/airos_*-"$ARCH".hpkg "$pool"/rock5_*-"$ARCH".hpkg \
		"$pool"/wpa_supplicant-*-"$ARCH".hpkg "$any"/*.hpkg; do
	[[ -e $file ]] && cp "$file" "$WORK/packages/"
done
if [[ $ARCH == x86_64 ]]; then
	# The applications' x86_64 requirements that the build system's HaikuPorts
	# list lacks (the others come with AddHaikuImageSystemPackages).
	AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK "$AIROS_CI/deps/haikuports.py" fetch --no-deps \
		x86_64 taglib2 scintilla lexilla lzo lz4 | xargs -r cp -t "$WORK/packages/"
fi
# GL stack, EGL vendor files, demos and firmware staged by the deps builds.
gl=$AIROS_ROOT/image-inputs/$TARGET
[[ -d $gl/lib ]] && cp -a "$gl/lib/." "$WORK/libs/"
[[ -d $gl/egl ]] && cp -a "$gl/egl/." "$WORK/egl/"
[[ -d $gl/demos ]] && cp -a "$gl/demos/." "$WORK/demos/"
[[ -d $gl/firmware ]] && cp -a "$gl/firmware/." "$WORK/firmware/"
rpi_firmware=$gl/rpi-firmware
ls -1 "$WORK/packages"
[[ ${#missing[@]} -eq 0 ]] || echo "warning: not in the package pool yet: ${missing[*]}" >&2

# 3. + 4. The image.
mkdir -p "$BUILD"
cd "$BUILD"
if [[ $TARGET == rpi4 ]] && { [[ ! -f build/BuildConfig ]] \
		|| ! grep -q "^#c $HAIKU_SOURCE/configure" build/BuildConfig; }; then
	"$HAIKU_SOURCE/configure" --distro-compatibility compatible --no-full-xattr \
		--cross-tools-prefix "$CROSS"
fi
[[ -f $HAIKU_SOURCE/tools/airos/ci/UserBuildConfig ]] \
	|| die "$REF has no tools/airos/ci/UserBuildConfig"
{
	echo "# written by airos-ci images/build-image.sh"
	echo "AIROS_CI_PACKAGES = $WORK/packages ;"
	[[ -z $(ls "$WORK/libs") ]] || echo "AIROS_CI_LIBS = $WORK/libs ;"
	[[ -z $(ls "$WORK/egl") ]] || echo "AIROS_CI_EGL = $WORK/egl ;"
	[[ -z $(ls "$WORK/demos") ]] || echo "AIROS_CI_DEMOS = $WORK/demos ;"
	[[ -z $(ls "$WORK/firmware") ]] || echo "AIROS_CI_FIRMWARE = $WORK/firmware ;"
	[[ $TARGET != rpi4 ]] || echo "HAIKU_RPI_FIRMWARE_DIR = $rpi_firmware ;"
	echo "include $HAIKU_SOURCE/tools/airos/ci/UserBuildConfig ;"
} > UserBuildConfig
rm -f "$BUILD/$IMAGE"
note "jam @$PROFILE $JAM_TARGET"
jam -q -j"$JOBS" "@$PROFILE" $JAM_TARGET
[[ -f $BUILD/$IMAGE ]] || die "jam made no $IMAGE"
# The SDK's build directory must not keep this UserBuildConfig.
[[ $TARGET == rpi4 ]] || rm -f "$BUILD/UserBuildConfig"

# 5. Publish.
note "publish"
stamp=$(date -u +%Y%m%d-%H%M)-$HAIKU_REVISION
dest=$AIROS_ARTIFACTS/images/$TARGET/$stamp
mkdir -p "$dest"
size=$(stat -c %s "$BUILD/$IMAGE")
xz -T0 -6 -c "$BUILD/$IMAGE" > "$dest/$IMAGE.xz"
( cd "$dest" && sha256sum "$IMAGE.xz" > "$IMAGE.xz.sha256" )
image_sha=$(sha256sum "$BUILD/$IMAGE" | cut -d' ' -f1)
python3 - "$dest/manifest.json" "$TARGET" "$IMAGE" "$size" "$image_sha" "$HAIKU_REVISION" \
	"$HAIKU_SHA" "$WORK/packages" <<'EOF'
import hashlib, json, os, sys, datetime
out, target, image, size, sha, rev, haiku_sha, pkgdir = sys.argv[1:9]
pkgs = sorted(os.listdir(pkgdir))
json.dump({
    "target": target, "image": image, "image_bytes": int(size), "image_sha256": sha,
    "built": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "haiku": {"repository": "https://github.com/jmgasper/haiku", "revision": rev, "commit": haiku_sha},
    "packages": [{"file": p, "sha256": hashlib.sha256(open(os.path.join(pkgdir, p), "rb").read()).hexdigest()}
                 for p in pkgs],
}, open(out, "w"), indent=1)
EOF
ln -sfn "$stamp" "$AIROS_ARTIFACTS/images/$TARGET/latest"
# Keep the last five images of each target.
ls -1dt "$AIROS_ARTIFACTS/images/$TARGET"/2* | tail -n +6 | xargs -r rm -rf
echo "image: $dest/$IMAGE.xz ($(du -h "$dest/$IMAGE.xz" | cut -f1); $((size / 1048576)) MiB uncompressed)"
echo "IMAGE_DIR=$dest" >> "${GITHUB_OUTPUT:-/dev/null}"

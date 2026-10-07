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
# HTTP. The build is recorded for the build dashboard (lib/status.py,
# $AIROS_DATA/builds); CLEAN=1 builds Haiku from scratch. The x86_64 image also
# rebuilds the NVIDIA driver, accelerant and NVDEC from the same Haiku tree.
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
# The build's record for the build dashboard (lib/status.py): opened before the
# wait for the lock, unless whoever started the build opened it (BUILD_ID), and
# the output goes to its log as well.
# (A record that cannot be written never stops the build.)
if [[ -z ${BUILD_ID:-} ]]; then
	BUILD_ID=$(python3 "$AIROS_CI/lib/status.py" begin "$TARGET" --ref "$REF" \
		${CLEAN:+--clean} 2>/dev/null) || BUILD_ID=
	export BUILD_ID
fi
if [[ -n $BUILD_ID && -z ${BUILD_LOGGING:-} ]]; then
	export BUILD_LOGGING=1
	exec > >(tee -a "$AIROS_DATA/builds/$BUILD_ID/log.txt") 2>&1
	python3 "$AIROS_CI/lib/status.py" set "$BUILD_ID" "pid=$$" || true
fi

# The whole build holds the architecture's lock: it updates the SDK's worktree
# and build directory (the Pi build shares the arm64 worktree and compiler).
if [[ ${AIROS_LOCKED:-} != haiku-$ARCH ]]; then
	build_stage "waiting for the build server" "another $ARCH build or job holds the $ARCH tree"
	exec env AIROS_LOCKED=haiku-$ARCH flock "$AIROS_LOCKS/haiku-$ARCH.lock" "$0" "$@"
fi
trap 'status=$?; [[ $status == 0 || -z $BUILD_ID ]] \
	|| python3 "$AIROS_CI/lib/status.py" end "$BUILD_ID" failed "exit=$status"' EXIT

# CLEAN=1: a build from scratch: the Haiku objects of the architecture (and the
# Pi's) go first, so jam builds everything again (cross tools are kept).
if [[ ${CLEAN:-0} == 1 ]]; then
	build_stage "cleaning" "removing the $ARCH build objects"
	rm -rf "$AIROS_BUILD/haiku-$ARCH/objects" "$AIROS_BUILD/haiku-$ARCH/generated"
	[[ $TARGET != rpi4 ]] || rm -rf "$AIROS_BUILD/haiku-rpi4/objects" "$AIROS_BUILD/haiku-rpi4/generated"
fi

# The applications every image carries (Summit is the default browser).
IMAGE_APPS=(summit summit_webkit amp airtime kiri clipper airshot turbochook burrow)
[[ $TARGET != rpi4 ]] || IMAGE_APPS+=(rpi_installer)

# 1. Haiku at REF: the SDK build updates the worktree and the build directory
#    of the architecture and builds haiku.hpkg and the host tools.
build_stage "Haiku and the SDK"
"$AIROS_CI/sdk/build-sdk.sh" "$ARCH" "$REF"
. "$AIROS_SDK/$ARCH/env.sh"

# x86_64: the NVIDIA driver, its accelerant and the NVDEC add-on are not built
# by jam; build them from this same Haiku revision (deps/build-nvidia.sh, under
# this build's lock; about 20 s when little changed).
if [[ $TARGET == x86_64 ]]; then
	build_stage "NVIDIA driver" "nvidia_rm, accelerant, NVDEC"
	"$AIROS_CI/deps/build-nvidia.sh"
fi

BUILD=$HAIKU_BUILD
if [[ $TARGET == rpi4 ]]; then
	# Its own build directory (its own UserBuildConfig) with the arm64 compiler.
	BUILD=$AIROS_BUILD/haiku-rpi4
fi

WORK=$AIROS_WORK/image-$TARGET
rm -rf "$WORK"
mkdir -p "$WORK"/{packages,libs,egl,demos,firmware,add-ons}

# 2. The inputs.
note "inputs"
build_stage "inputs" "packages, GL stacks, firmware"
pool=$AIROS_PACKAGES/$ARCH
any=$AIROS_PACKAGES/any
missing=()
for app in "${IMAGE_APPS[@]}"; do
	file=$(ls "$pool/$app"-[0-9]*-"$ARCH".hpkg 2>/dev/null | head -n 1 || true)
	if [[ -n $file ]]; then cp "$file" "$WORK/packages/"; else missing+=("$app"); fi
done
# Libraries and system components CI builds (airos_*, rock5_ffmpeg,
# wpa_supplicant, ...) and firmware: architecture-neutral packages, and on
# arm64 HaikuPorts' Wi-Fi firmware recompressed with zlib
# (deps/build-firmware.sh).
for file in "$pool"/airos_*-"$ARCH".hpkg "$pool"/rock5_*-"$ARCH".hpkg \
		"$pool"/wpa_supplicant-*-"$ARCH".hpkg "$pool"/*_wifi_firmwares-*-any.hpkg "$any"/*.hpkg; do
	[[ -e $file ]] && cp "$file" "$WORK/packages/"
done
if [[ $ARCH == x86_64 ]]; then
	# The applications' x86_64 requirements that the build system's HaikuPorts
	# list lacks (the others come with AddHaikuImageSystemPackages), and what
	# summit_webkit's private Mesa needs: LLVM 21 (llvmpipe) and the Vulkan
	# loader (zink); and the Wi-Fi firmware Haiku's image leaves out (Intel
	# cards such as the X399's AX210, Ralink, Realtek).
	AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK "$AIROS_CI/deps/haikuports.py" fetch --no-deps \
		x86_64 taglib2 scintilla lexilla lzo lz4 llvm21_libs vulkan \
		intel_wifi_firmwares ralink_wifi_firmwares realtek_wifi_firmwares | xargs -r cp -t "$WORK/packages/"
fi
# GL stack, EGL vendor files, demos, firmware and add-ons staged by the deps
# builds.
gl=$AIROS_ROOT/image-inputs/$TARGET
[[ -d $gl/lib ]] && cp -a "$gl/lib/." "$WORK/libs/"
[[ -d $gl/egl ]] && cp -a "$gl/egl/." "$WORK/egl/"
[[ -d $gl/demos ]] && cp -a "$gl/demos/." "$WORK/demos/"
[[ -d $gl/firmware ]] && cp -a "$gl/firmware/." "$WORK/firmware/"
# x86_64: nvidia_rm, its accelerant and NVDEC (deps/build-nvidia.sh), NVK
# (deps/build-nvk.sh), the Zink renderer (deps/build-zink.sh): each a tree
# with lib/ and add-ons/
for part in "$gl"/nvidia "$gl"/nvk "$gl"/zink; do
	[[ -d $part/lib ]] && cp -a "$part/lib/." "$WORK/libs/"
	[[ -d $part/add-ons ]] && cp -a "$part/add-ons/." "$WORK/add-ons/"
done
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
	[[ -z $(ls "$WORK/add-ons") ]] || echo "AIROS_CI_ADDONS = $WORK/add-ons ;"
	# arm64: FluidLite for the MIDI kit (deps/recipes/fluidlite.sh)
	deps=$AIROS_ROOT/deps/$ARCH/boot/system
	[[ $ARCH != arm64 || ! -f $deps/develop/lib/libfluidlite.a ]] || echo "AIROS_CI_FLUIDLITE = $deps ;"
	[[ $TARGET != rpi4 ]] || echo "HAIKU_RPI_FIRMWARE_DIR = $rpi_firmware ;"
	echo "include $HAIKU_SOURCE/tools/airos/ci/UserBuildConfig ;"
} > UserBuildConfig
rm -f "$BUILD/$IMAGE"
note "jam @$PROFILE $JAM_TARGET"
build_stage "image" "jam @$PROFILE $JAM_TARGET"
jam -q -j"$JOBS" "@$PROFILE" $JAM_TARGET
[[ -f $BUILD/$IMAGE ]] || die "jam made no $IMAGE"
# The SDK's build directory must not keep this UserBuildConfig.
[[ $TARGET == rpi4 ]] || rm -f "$BUILD/UserBuildConfig"

# 5. Publish.
note "publish"
build_stage "publish" "xz, checksums, manifest"
stamp=$(date -u +%Y%m%d-%H%M)-$HAIKU_REVISION
dest=$AIROS_ARTIFACTS/images/$TARGET/$stamp
mkdir -p "$dest"
size=$(stat -c %s "$BUILD/$IMAGE")
xz -T0 -6 -c "$BUILD/$IMAGE" > "$dest/$IMAGE.xz"
( cd "$dest" && sha256sum "$IMAGE.xz" > "$IMAGE.xz.sha256" )
image_sha=$(sha256sum "$BUILD/$IMAGE" | cut -d' ' -f1)
python3 - "$dest/manifest.json" "$TARGET" "$IMAGE" "$size" "$image_sha" "$HAIKU_REVISION" \
	"$HAIKU_SHA" "$WORK/packages" "$gl" <<'EOF'
import glob, hashlib, json, os, sys, datetime
out, target, image, size, sha, rev, haiku_sha, pkgdir, inputs = sys.argv[1:10]
pkgs = sorted(os.listdir(pkgdir))
# What the files outside packages were built from (the *-sources.txt the deps
# builds leave with them: GL stacks, NVIDIA, NVK, Zink).
sources = {}
for path in sorted(glob.glob(os.path.join(inputs, "*-sources.txt"))
                   + glob.glob(os.path.join(inputs, "*", "*-sources.txt"))):
    name = os.path.basename(path)[:-len("-sources.txt")]
    sources[name] = dict(line.split(" ", 1) for line in open(path).read().splitlines() if " " in line)
json.dump({
    "inputs": sources,
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
[[ -z $BUILD_ID ]] || python3 "$AIROS_CI/lib/status.py" end "$BUILD_ID" built "image_dir=$dest" \
	"haiku=$HAIKU_REVISION" "image=$IMAGE.xz" "stamp=$stamp" || true

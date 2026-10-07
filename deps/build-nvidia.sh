#!/usr/bin/env bash
# build-nvidia.sh
#
# The NVIDIA graphics stack of the x86_64 images (the X399 workstation's GTX
# 1080 Ti and other Pascal cards), from the Haiku tree the x86_64 SDK was built
# from and the forks:
#
#   nvidia_rm, nvidia_rm_modeset  kernel add-ons: X547's Haiku OS layer
#                                 (haiku src/add-ons/kernel/drivers/graphics/
#                                 nvidia_rm) on jmgasper/open-gpu-kernel-modules,
#                                 linked with the RM core of NVIDIA's 570.86.16
#                                 driver, which build-cross.sh downloads from
#                                 NVIDIA and checks against its SHA-256
#   nvidia_rm.accelerant          app_server's side (modes, NVKMS)
#   nvdec                         media add-on: H.264 on the card's NVDEC engine,
#                                 with jmgasper/mesa-nvk's RM API; it offers
#                                 nothing where there is no NVIDIA card
#
# into $AIROS_ROOT/image-inputs/x86_64/add-ons, which the x86_64 image puts in
# system/non-packaged/add-ons: the boot menu's "Disable user add-ons" turns
# them off, as on the workstation. images/build-image.sh x86_64 runs it with
# every image build, so they match the image's Haiku revision; the sdk-deps
# workflow runs it too.
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"
if [[ ${AIROS_LOCKED:-} != haiku-x86_64 ]]; then
	exec env AIROS_LOCKED=haiku-x86_64 flock "$AIROS_LOCKS/haiku-x86_64.lock" "$0" "$@"
fi
export AIROS_ARCH=x86_64
. "$AIROS_CI/lib/sdk.sh"
. "$AIROS_CI/lib/fork.sh"

W=$AIROS_WORK/nvidia
INPUTS=$AIROS_ROOT/image-inputs/x86_64
mkdir -p "$W" "$INPUTS"
cd "$W"

driver=$HAIKU_SOURCE/src/add-ons/kernel/drivers/graphics/nvidia_rm/build-cross.sh
accelerant=$HAIKU_SOURCE/src/add-ons/accelerants/nvidia_rm/build-cross.sh
nvdec=$HAIKU_SOURCE/src/add-ons/media/plugins/nvdec/build-cross.sh
for script in "$driver" "$accelerant" "$nvdec"; do
	[[ -x $script ]] || die "$HAIKU_REVISION has no $script"
done
grep -q OGKM_SRC "$driver" || die "$HAIKU_REVISION's nvidia_rm build-cross.sh takes no OGKM_SRC"

note "sources"
fork_checkout open-gpu-kernel-modules "$W/open-gpu-kernel-modules"; OGKM_COMMIT=$FORK_COMMIT
fork_checkout mesa-nvk "$W/mesa-nvk"; NVK_COMMIT=$FORK_COMMIT

OUT=$W/out
rm -rf "$OUT"
# CLEAN=1 (a clean image build): the driver's objects and NVKMS's go too.
if [[ ${CLEAN:-0} == 1 ]]; then
	rm -rf "$W/work/obj" "$W/work/accelerant-obj" "$W/open-gpu-kernel-modules/src/nvidia-modeset/_out"
fi
note "nvidia_rm"
OGKM_SRC=$W/open-gpu-kernel-modules "$driver" "$HAIKU_BUILD" "$W/work" "$OUT"
note "nvidia_rm.accelerant"
OGKM_SRC=$W/open-gpu-kernel-modules "$accelerant" "$HAIKU_BUILD" "$W/work" "$OUT"
note "nvdec"
OGKM_SRC=$W/open-gpu-kernel-modules "$nvdec" "$HAIKU_BUILD" "$W/mesa-nvk" "$OUT"

note "image inputs"
stage=$W/stage/add-ons
rm -rf "$W/stage"
mkdir -p "$stage"
cp -a "$OUT/add-ons/kernel" "$OUT/add-ons/accelerants" "$OUT/add-ons/media" "$stage/"
${CROSS}strip --strip-debug "$stage/accelerants/nvidia_rm.accelerant" "$stage/media/plugins/nvdec" \
	"$stage"/kernel/drivers/bin/nvidia_rm "$stage"/kernel/drivers/bin/nvidia_rm_modeset
# what went in, and NVIDIA's licence for the RM core
nv=$(ls -d "$W"/work/NVIDIA-Linux-x86_64-*/ | head -n 1)
printf 'haiku %s\nopen-gpu-kernel-modules %s\nmesa-nvk %s\nnvidia %s\n' "$HAIKU_REVISION" \
	"$OGKM_COMMIT" "$NVK_COMMIT" "$(basename "$nv")" > "$W/stage/nvidia-sources.txt"
cp "$nv/LICENSE" "$W/stage/NVIDIA-LICENSE"
mkdir -p "$INPUTS/nvidia"
rsync -rlc --delete "$W/stage/" "$INPUTS/nvidia/"
find "$INPUTS/nvidia/add-ons" \( -type f -o -type l \) | sed "s|$INPUTS/nvidia/||" | sort

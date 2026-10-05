#!/usr/bin/env bash
# build-zink.sh
#
# The Zink renderer add-on of Haiku's OpenGL kit for x86_64: BGLView programs
# drawing on the GPU through Vulkan (NVK on nvidia_rm), cross-built from
# jmgasper/mesa airos-22.0.5-hgl as docs/x399-workstation/tools/
# build-mesa-hgl.sh builds it natively. It is Mesa 22.0.5, the release of the
# image's mesa package, so the glapi dispatch between libGL and the add-on is
# identical.
#
# Result: $AIROS_ROOT/image-inputs/x86_64/zink/add-ons/opengl-zink/Zink. The
# GL kit takes the first renderer it finds, so the image does not put Zink in
# add-ons/opengl itself: its boot script links it there only on a machine with
# an NVIDIA card (/dev/nvidiactl), and others keep Mesa's llvmpipe.
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"
if [[ ${AIROS_LOCKED:-} != haiku-x86_64 ]]; then
	exec env AIROS_LOCKED=haiku-x86_64 flock "$AIROS_LOCKS/haiku-x86_64.lock" "$0" "$@"
fi
export AIROS_ARCH=x86_64
. "$AIROS_CI/lib/sdk.sh"
. "$AIROS_CI/lib/fork.sh"

W=$AIROS_WORK/zink
INPUTS=$AIROS_ROOT/image-inputs/x86_64/zink
mkdir -p "$W"
cd "$W"
TLS=-mtls-dialect=gnu

note "sources"
fork_checkout mesa-hgl "$W/mesa"; MESA_COMMIT=$FORK_COMMIT

note "sysroot: the SDK's and HaikuPorts' Vulkan loader"
GLROOT=$W/sysroot
system=$GLROOT/boot/system
rsync -rlc --delete "$SYSROOT/" "$GLROOT/"
AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK "$AIROS_CI/deps/haikuports.py" stage --no-deps x86_64 \
	"$system" vulkan vulkan_devel > /dev/null
while IFS= read -r -d '' link; do
	target=$(readlink "$link")
	[[ $target == /boot/system/* ]] && ln -sfn "$(realpath -m --relative-to="$(dirname "$link")" "$GLROOT$target")" "$link"
done < <(find "$system" -type l -print0)

cat > "$W/cross.ini" <<EOF
[binaries]
c = '${CROSS}gcc'
cpp = '${CROSS}g++'
ar = '${CROSS}ar'
strip = '${CROSS}strip'
pkg-config = '/usr/bin/pkg-config'

[host_machine]
system = 'haiku'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[properties]
needs_exe_wrapper = true
sys_root = '$GLROOT'
pkg_config_libdir = ['$system/develop/lib/pkgconfig', '$system/lib/pkgconfig']

[built-in options]
c_args = ['--sysroot=$GLROOT', '$TLS']
cpp_args = ['--sysroot=$GLROOT', '$TLS']
c_link_args = ['--sysroot=$GLROOT', '-specs=$UNWIND_SPECS']
cpp_link_args = ['--sysroot=$GLROOT', '-specs=$UNWIND_SPECS']
EOF

note "Zink (Mesa 22.0.5)"
B=$W/build
key=$(cat "$W/cross.ini" <(echo "$MESA_COMMIT") | sha256sum | cut -c1-16)
if [[ ! -f $B/build.ninja || $(cat "$B.key" 2>/dev/null) != "$key" ]]; then
	rm -rf "$B"
	env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u LDFLAGS \
		PKG_CONFIG_LIBDIR="$system/develop/lib/pkgconfig:$system/lib/pkgconfig" \
		PKG_CONFIG_SYSROOT_DIR="$GLROOT" PKG_CONFIG_PATH= \
		meson setup "$B" "$W/mesa" --cross-file "$W/cross.ini" --buildtype=release \
		--prefix=/boot/system --libdir=lib \
		-Dplatforms=haiku -Dgallium-drivers=zink,swrast -Dglx=disabled -Degl=disabled \
		-Dllvm=disabled '-Dvulkan-drivers=[]' -Dshared-glapi=enabled -Dgbm=disabled \
		-Dgles1=disabled -Dgles2=disabled -Dosmesa=false > "$B.configure.log" 2>&1 \
		|| { tail -40 "$B.configure.log"; die "Zink configure failed (log: $B.configure.log)"; }
	echo "$key" > "$B.key"
fi
ninja -C "$B" -j"$JOBS" > "$B.build.log" 2>&1 \
	|| { grep -m5 -B3 -A10 -E 'error' "$B.build.log"; die "Zink build failed (log: $B.build.log)"; }
addon=$B/src/gallium/targets/haiku-zink/libzinkpipe.so
[[ -f $addon ]] || die "no $addon"
if ${CROSS}readelf -rW "$addon" | grep -qE 'TLSDESC|R_X86_64_TPOFF'; then
	die "the Zink add-on has TLS relocations Haiku's loader cannot do"
fi

note "image inputs"
stage=$W/stage
rm -rf "$stage"
mkdir -p "$stage/add-ons/opengl-zink"
cp "$addon" "$stage/add-ons/opengl-zink/Zink"
${CROSS}strip --strip-unneeded "$stage/add-ons/opengl-zink/Zink"
printf 'mesa-hgl %s\nhaiku %s\n' "$MESA_COMMIT" "$HAIKU_REVISION" > "$stage/zink-sources.txt"
mkdir -p "$INPUTS"
rsync -rlc --delete "$stage/" "$INPUTS/"
${CROSS}readelf -d "$INPUTS/add-ons/opengl-zink/Zink" | grep NEEDED

#!/usr/bin/env bash
# build-gl.sh
#
# The arm64 GL stack of the air/OS images, as tools/rock5-itx/mesa/build.py,
# build-application.py and tools/rpi4/mesa/build.sh make it, from the forks:
#   jmgasper/mesa (airos-25.3.6: Mesa 25.3.6 + the Haiku Panfrost/Mali CSF,
#   quad-fill and V3D patches), jmgasper/libglvnd (airos-1.7.0), jmgasper/glu.
#
#   1. Mesa's host compilers (mesa_clc, vtn_bindgen2, panfrost_compile), built
#      natively with Ubuntu's LLVM 18, libclc and SPIRV-LLVM-Translator;
#   2. libglvnd (libGL, libEGL, libGLESv2, libOpenGL, libGLdispatch and the
#      Haiku GL kit headers) into a GL sysroot;
#   3. Mesa three times: Panfrost (ROCK 5), V3D (Raspberry Pi 4), and the
#      V3D Vulkan driver;
#   4. GLU, the GLTeapot demo and GLInfo.
#
# Results:
#   $AIROS_ROOT/image-inputs/arm64/{lib,egl,demos}   ROCK 5 / EFI image
#   $AIROS_ROOT/image-inputs/rpi4/{lib,egl,demos}    Raspberry Pi 4 image
#   $AIROS_ROOT/deps/arm64/boot/system               GL headers and libraries
#                                                     for app builds
#   $AIROS_ROOT/gl/arm64/boot/system                  the same as an overlay of
#                                                     the SDK sysroot (Summit)
# Refuses to build when Mesa's copy of the Mali CSF kernel ABI headers differs
# from the driver's in the Haiku tree the SDK was built from.
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"
if [[ ${AIROS_LOCKED:-} != haiku-arm64 ]]; then
	exec env AIROS_LOCKED=haiku-arm64 flock "$AIROS_LOCKS/haiku-arm64.lock" "$0" "$@"
fi
export AIROS_ARCH=arm64
. "$AIROS_CI/lib/sdk.sh"
. "$AIROS_CI/lib/fork.sh"

W=$AIROS_WORK/gl
INPUTS=$AIROS_ROOT/image-inputs
mkdir -p "$W"
cd "$W"

note "sources"
fork_checkout mesa "$W/mesa";         MESA_COMMIT=$FORK_COMMIT
fork_checkout libglvnd "$W/libglvnd"; GLVND_COMMIT=$FORK_COMMIT
fork_checkout glu "$W/glu";           GLU_COMMIT=$FORK_COMMIT
MESA=$W/mesa

note "Mali CSF ABI"
abi=$MESA/src/panfrost/lib/kmod/haiku-abi
driver=$HAIKU_SOURCE/src/add-ons/kernel/drivers/graphics/mali_csf
for header in "$abi"/*.h; do
	cmp -s "$header" "$driver/$(basename "$header")" \
		|| die "Mesa's $(basename "$header") differs from the mali_csf driver's in $HAIKU_REVISION; update jmgasper/mesa"
done
echo "Mesa and the mali_csf driver agree ($(ls "$abi"/*.h | wc -l) headers)"

note "host compilers"
# From Mesa before the V3D commit: that patch adds Haiku stand-ins for libdrm's
# xf86drm.h and libsync.h that a native Linux build must not see (the
# workstation built its host compilers from the tree without it too).
v3d_commit=$(git -C "$MESA" log --format=%H -1 --grep='V3D (Raspberry Pi 4) winsys')
host_base=${v3d_commit:+$v3d_commit~1}
host_base=$(git -C "$MESA" rev-parse "${host_base:-HEAD}")
HOST=$AIROS_ROOT/toolchain/mesa-host-${host_base:0:12}
if [[ ! -x $HOST/bin/mesa_clc ]]; then
	host_src=$W/mesa-host-src
	git -C "$MESA" worktree remove --force "$host_src" 2>/dev/null || rm -rf "$host_src"
	git -C "$MESA" worktree add -q --detach --force "$host_src" "$host_base"
	printf "[binaries]\nllvm-config = '/usr/lib/llvm-18/bin/llvm-config'\n" > "$W/native.ini"
	rm -rf "$W/host-build"
	env -u CC -u CXX meson setup "$W/host-build" "$host_src" --native-file "$W/native.ini" \
		--prefix="$HOST" --libdir=lib --buildtype=debugoptimized --wrap-mode=nofallback \
		'-Dplatforms=[]' '-Dvulkan-drivers=[]' -Dglx=disabled -Dgbm=disabled -Dgallium-va=disabled \
		-Dglvnd=disabled -Dlibunwind=disabled -Dlmsensors=disabled -Dvalgrind=disabled \
		-Dbuild-tests=false '-Dvideo-codecs=[]' '-Dgallium-drivers=[]' -Dtools=panfrost \
		-Degl=disabled -Dgles1=disabled -Dgles2=disabled -Dopengl=false -Dmesa-clc=enabled \
		-Dinstall-mesa-clc=true -Dprecomp-compiler=enabled -Dinstall-precomp-compiler=true \
		-Dllvm=enabled -Dshared-llvm=enabled '-Dstatic-libclc=[]' > "$W/host-configure.log"
	ninja -C "$W/host-build" -j"$JOBS" > "$W/host-build.log"
	ninja -C "$W/host-build" install > /dev/null
fi
export PATH="$HOST/bin:$PATH"
ls "$HOST/bin"

note "GL sysroot and cross file"
GLROOT=$W/sysroot
rm -rf "$GLROOT"
mkdir -p "$GLROOT"
cp -a "$SYSROOT/." "$GLROOT/"
system=$GLROOT/boot/system
# absolute links inside the sysroot point into it
while IFS= read -r -d '' link; do
	target=$(readlink "$link")
	[[ $target == /boot/system/* ]] && ln -sfn "$(realpath -m --relative-to="$(dirname "$link")" "$GLROOT$target")" "$link"
done < <(find "$system" -type l -print0)
pkgdirs="'$system/develop/lib/pkgconfig', '$system/lib/pkgconfig'"
cat > "$W/cross.ini" <<EOF
[binaries]
c = '${CROSS}gcc'
cpp = '${CROSS}g++'
ar = '${CROSS}ar'
strip = '${CROSS}strip'
pkg-config = '/usr/bin/pkg-config'

[host_machine]
system = 'haiku'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
needs_exe_wrapper = true
sys_root = '$GLROOT'
pkg_config_libdir = [$pkgdirs]

[built-in options]
c_args = ['--sysroot=$GLROOT']
cpp_args = ['--sysroot=$GLROOT']
c_link_args = ['--sysroot=$GLROOT', '-specs=$UNWIND_SPECS']
cpp_link_args = ['--sysroot=$GLROOT', '-specs=$UNWIND_SPECS']
EOF
cross() { env -u CC -u CXX -u CPPFLAGS -u CFLAGS -u CXXFLAGS -u LDFLAGS \
	PKG_CONFIG_LIBDIR="$system/develop/lib/pkgconfig:$system/lib/pkgconfig" \
	PKG_CONFIG_SYSROOT_DIR="$GLROOT" PKG_CONFIG_PATH= "$@"; }

note "libglvnd"
rm -rf "$W/glvnd-build" "$W/glvnd-install"
cross meson setup "$W/glvnd-build" "$W/libglvnd" --cross-file="$W/cross.ini" \
	--buildtype=debugoptimized --prefix=/boot/system --libdir=lib \
	--includedir=develop/headers/os/opengl --sysconfdir=settings --wrap-mode=nofallback \
	-Dx11=disabled -Dglx=disabled -Dhgl=true -Dgles1=false -Dgles2=true -Degl=true \
	> "$W/glvnd-configure.log"
cross ninja -C "$W/glvnd-build" -j"$JOBS" > "$W/glvnd-build.log"
DESTDIR=$W/glvnd-install cross meson install -C "$W/glvnd-build" --no-rebuild > /dev/null
glvnd=$W/glvnd-install/boot/system
cp -a "$glvnd/." "$system/"
headers=$system/develop/headers
mv "$headers/os/opengl/OpenGLKit.h" "$headers/os/OpenGLKit.h"
mv "$headers/os/opengl/opengl/GLView.h" "$headers/os/opengl/GLView.h"
for name in libGL.so libEGL.so libOpenGL.so libGLESv2.so libGLdispatch.so; do
	ln -sfn "../../lib/$name" "$system/develop/lib/$name"
done

mesa_build() { # mesa_build DIR OPTIONS...
	local dir=$1
	shift
	# Configured afresh only when Mesa, the cross file or the options changed;
	# otherwise ninja brings the build up to date.
	local key
	key=$(printf '%s\n' "$MESA_COMMIT" "$@" | cat - "$W/cross.ini" | sha256sum | cut -c1-16)
	if [[ ! -f $dir/build.ninja || $(cat "$dir.key" 2>/dev/null) != "$key" ]]; then
		rm -rf "$dir"
		cross meson setup "$dir" "$MESA" --cross-file="$W/cross.ini" --prefix=/boot/system \
			--libdir=lib --buildtype=debugoptimized --wrap-mode=nofallback "$@" > "$dir.configure.log" \
			|| { tail -30 "$dir.configure.log"; die "configure $(basename "$dir") failed"; }
		echo "$key" > "$dir.key"
	fi
	cross ninja -C "$dir" -j"$JOBS" > "$dir.build.log" \
		|| { grep -m5 -B2 -A8 'error' "$dir.build.log"; die "build $(basename "$dir") failed"; }
}

note "Mesa: Panfrost (ROCK 5)"
# The options build.py pins in tools/rock5-itx/mesa/sources.json.
mapfile -t panfrost_options < <(python3 - "$HAIKU_SOURCE/tools/rock5-itx/mesa/sources.json" <<'EOF'
import json, sys
for key, value in json.load(open(sys.argv[1]))["mesa_options"].items():
    if isinstance(value, list):
        value = ",".join(value) if value else "[]"
    elif isinstance(value, bool):
        value = str(value).lower()
    print(f"-D{key}={value}")
EOF
)
mesa_build "$W/mesa-panfrost" "${panfrost_options[@]}"

common_v3d=(-Dplatforms=haiku -Dexpat=disabled -Dgallium-va=disabled -Dshader-cache=disabled
	-Dgles1=disabled -Dgbm=disabled -Dglx=disabled -Dllvm=disabled -Dvalgrind=disabled
	-Dbuild-tests=false '-Dtools=[]' -Dzstd=disabled -Dzlib=disabled -Dxmlconfig=disabled
	-Dmesa-clc=system -Dprecomp-compiler=system -Dspirv-tools=disabled)
note "Mesa: V3D (Raspberry Pi 4)"
mesa_build "$W/mesa-v3d" "${common_v3d[@]}" -Dgallium-drivers=v3d,softpipe '-Dvulkan-drivers=[]' \
	-Dgles2=enabled -Dopengl=true -Degl=enabled -Dglvnd=enabled
note "Mesa: V3D Vulkan (Raspberry Pi 4)"
mesa_build "$W/mesa-v3dv" "${common_v3d[@]}" '-Dgallium-drivers=[]' -Dvulkan-drivers=broadcom \
	-Dgles2=disabled -Dopengl=false -Degl=disabled -Dglvnd=disabled

note "GLU and GLTeapot"
rm -rf "$W/glu-build" "$W/glu-install"
cross meson setup "$W/glu-build" "$W/glu" --cross-file="$W/cross.ini" --buildtype=debugoptimized \
	--prefix=/boot/system --libdir=lib --includedir=develop/headers/os/opengl --wrap-mode=nofallback \
	-Ddefault_library=shared -Dgl_provider=glvnd > "$W/glu-configure.log"
cross ninja -C "$W/glu-build" -j"$JOBS" > "$W/glu-build.log"
DESTDIR=$W/glu-install cross meson install -C "$W/glu-build" --no-rebuild > /dev/null
glu=$W/glu-install/boot/system
app=$HAIKU_SOURCE/src/apps/glteapot
${CROSS}g++ --sysroot="$GLROOT" -specs="$UNWIND_SPECS" -std=gnu++17 -O2 -Wall \
	-I"$headers/os/opengl" -I"$glu/develop/headers/os/opengl" \
	"$app"/{FPS,GLObject,ObjectView,error,TeapotWindow,TeapotApp}.cpp \
	-L"$glvnd/lib" -L"$glu/lib" -Wl,-rpath-link,"$system/lib" \
	-lbe -lgame -llocalestub -lsupc++ -lGLU -lGL -o "$W/GLTeapot"
"$TOOLS/rc/rc" -o "$W/GLTeapot.rsrc" "$app/GLTeapot.rdef"
${CROSS}strip --strip-debug "$W/GLTeapot"
"$TOOLS/xres" -o "$W/GLTeapot" "$W/GLTeapot.rsrc"
# GLInfo (renderer, version and extensions), as the ROCK 5 lab image had it
# (tools/rock5-itx/build-glinfo-package.sh).
app=$HAIKU_SOURCE/src/tests/kits/opengl/glinfo
rm -rf "$W/glinfo" && mkdir -p "$W/glinfo"
for source in "$app"/*.cpp; do
	${CROSS}g++ --sysroot="$GLROOT" -std=gnu++17 -O2 -fPIC -I"$HAIKU_SOURCE/headers/private/interface" \
		-I"$HAIKU_SOURCE/headers/libs/glut" -I"$headers/os/opengl" -I"$glu/develop/headers/os/opengl" \
		-c "$source" -o "$W/glinfo/$(basename "${source%.cpp}").o"
done
${CROSS}g++ --sysroot="$GLROOT" -specs="$UNWIND_SPECS" -std=gnu++17 -O2 "$W"/glinfo/*.o \
	"$system/develop/lib/libcolumnlistview.a" -L"$glvnd/lib" -L"$glu/lib" -Wl,-rpath-link,"$system/lib" \
	-lbe -ltranslation -llocalestub -lsupc++ -lGLU -lGL -o "$W/GLInfo"
"$TOOLS/rc/rc" -o "$W/GLInfo.rsrc" "$app/GLInfo.rdef"
${CROSS}strip --strip-debug "$W/GLInfo"
"$TOOLS/xres" -o "$W/GLInfo" "$W/GLInfo.rsrc"

note "image inputs"
stage_target() { # stage_target TARGET EGL_LIBRARY VENDOR_FILE [extra libs...]
	local target=$1 out=$INPUTS/$1 egl=$2 vendor=$3
	shift 3
	rm -rf "$out/lib" "$out/egl" "$out/demos"
	mkdir -p "$out/lib" "$out/egl" "$out/demos"
	cp "$egl" "$out/lib/libEGL_mesa.so.0"
	local name version
	for name in libEGL:1.1.0 libGLESv2:2.1.0 libGLdispatch:0.0.0 libOpenGL:0.0.0 libGL:1.0.0; do
		version=${name#*:}
		cp "$glvnd/lib/${name%%:*}.so.$version" "$out/lib/${name%%:*}.so.${version%%.*}"
	done
	cp "$(readlink -f "$glu/lib/libGLU.so.1")" "$out/lib/libGLU.so.1"
	[[ $# -eq 0 ]] || cp "$@" "$out/lib/"
	${CROSS}strip --strip-unneeded "$out"/lib/*
	printf '{\n  "file_format_version": "1.0.0",\n  "ICD": {\n    "library_path": "/boot/system/non-packaged/lib/libEGL_mesa.so.0"\n  }\n}\n' \
		> "$out/egl/$vendor"
	cp "$W/GLTeapot" "$W/GLInfo" "$out/demos/"
	printf 'mesa %s\nlibglvnd %s\nglu %s\nhaiku %s\n' "$MESA_COMMIT" "$GLVND_COMMIT" "$GLU_COMMIT" \
		"$HAIKU_REVISION" > "$out/gl-sources.txt"
	echo "$target: $(ls "$out/lib" | tr '\n' ' ')"
}
stage_target arm64 "$W/mesa-panfrost/src/egl/libEGL_mesa.so.0.0.0" 10_mesa_panfrost.json
stage_target rpi4 "$W/mesa-v3d/src/egl/libEGL_mesa.so.0.0.0" 10_mesa.json \
	"$W/mesa-v3dv/src/broadcom/vulkan/libvulkan_broadcom.so"

note "GL development files for app builds"
cp -a "$glvnd/." "$DEPS/"
cp -a "$glu/." "$DEPS/"
mkdir -p "$DEPS/develop/headers/os"
cp "$headers/os/OpenGLKit.h" "$DEPS/develop/headers/os/"
cp "$headers/os/opengl/GLView.h" "$DEPS/develop/headers/os/opengl/"
note "GL SDK overlay"
# What the GL sysroot adds to the SDK's, in its layout: libglvnd and GLU with
# their headers and develop/lib links. summit/lib.sh lays it over its SDK
# snapshot, so the Summit engine finds EGL and GLES as on an installed system.
overlay=$W/gl-overlay/boot/system
rm -rf "$W/gl-overlay"
mkdir -p "$overlay/develop/lib"
cp -a "$glvnd/." "$overlay/"
cp -a "$glu/." "$overlay/"
mv "$overlay/develop/headers/os/opengl/OpenGLKit.h" "$overlay/develop/headers/os/OpenGLKit.h"
mv "$overlay/develop/headers/os/opengl/opengl/GLView.h" "$overlay/develop/headers/os/opengl/GLView.h"
rmdir "$overlay/develop/headers/os/opengl/opengl"
for name in libGL.so libEGL.so libOpenGL.so libGLESv2.so libGLdispatch.so libGLU.so; do
	ln -sfn "../../lib/$name" "$overlay/develop/lib/$name"
done
mkdir -p "$AIROS_ROOT/gl/arm64"
rsync -rlc --delete "$W/gl-overlay/" "$AIROS_ROOT/gl/arm64/"
echo "GL stack built from mesa ${MESA_COMMIT:0:12}, libglvnd ${GLVND_COMMIT:0:12}, glu ${GLU_COMMIT:0:12}"

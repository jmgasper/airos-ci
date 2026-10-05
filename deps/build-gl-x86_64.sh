#!/usr/bin/env bash
# build-gl-x86_64.sh
#
# The x86_64 GL stack of Summit's engine, as Summit's tools/mesa-vm builds it,
# from the forks: jmgasper/libglvnd (airos-1.7.0) and jmgasper/mesa
# (airos-25.3.6-x86_64: Mesa 25.3.6 with Summit's Haiku x86_64 changes), with
# EGL and OpenGL ES, and the Gallium drivers llvmpipe (HaikuPorts' LLVM 21),
# softpipe and zink (HaikuPorts' Vulkan loader; a GPU with a Vulkan driver).
# Stock Haiku's Mesa has no EGL, so the x86_64 summit_webkit package carries
# this one privately and the engine points its processes at it.
#
# Results:
#   $AIROS_ROOT/gl/x86_64/boot/system   libglvnd's headers and libraries, an
#                                       overlay of the SDK sysroot for the
#                                       engine build (summit/lib.sh)
#   $AIROS_ROOT/gl/x86_64-mesa/lib      libglvnd and Mesa, for the package's
#                                       lib/summit-webkit/mesa/lib
#   $AIROS_ROOT/gl/x86_64-mesa/haikuports.json   the HaikuPorts packages it
#                                       was built against (llvm21_libs and
#                                       vulkan are what it needs at run time)
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"
if [[ ${AIROS_LOCKED:-} != haiku-x86_64 ]]; then
	exec env AIROS_LOCKED=haiku-x86_64 flock "$AIROS_LOCKS/haiku-x86_64.lock" "$0" "$@"
fi
export AIROS_ARCH=x86_64
. "$AIROS_CI/lib/sdk.sh"
. "$AIROS_CI/lib/fork.sh"

W=$AIROS_WORK/gl-x86_64
OUT=$AIROS_ROOT/gl
mkdir -p "$W"
cd "$W"
# Haiku's runtime_loader implements only general-dynamic TLS (no TLSDESC).
TLS=-mtls-dialect=gnu

note "sources"
fork_checkout mesa-x86_64 "$W/mesa"; MESA_COMMIT=$FORK_COMMIT
fork_checkout libglvnd "$W/libglvnd"; GLVND_COMMIT=$FORK_COMMIT

note "GL sysroot: the SDK's, HaikuPorts' LLVM 21 and Vulkan"
GLROOT=$W/sysroot
system=$GLROOT/boot/system
rm -rf "$GLROOT"
mkdir -p "$GLROOT"
cp -a "$SYSROOT/." "$GLROOT/"
AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK "$AIROS_CI/deps/haikuports.py" stage --no-deps x86_64 \
	"$system" llvm21 llvm21_libs vulkan vulkan_devel > /dev/null
cp "$system/.haikuports.json" "$W/haikuports.json"
# absolute links inside the sysroot point into it
while IFS= read -r -d '' link; do
	target=$(readlink "$link")
	[[ $target == /boot/system/* ]] && ln -sfn "$(realpath -m --relative-to="$(dirname "$link")" "$GLROOT$target")" "$link"
done < <(find "$system" -type l -print0)

# llvm-config for the Haiku LLVM, which cannot run here: what Mesa's meson asks.
llvm_cmake=$system/lib/cmake/llvm/LLVMConfig.cmake
llvm_version=$(sed -n 's/^set(LLVM_PACKAGE_VERSION \(.*\))/\1/p' "$llvm_cmake")
[[ $llvm_version == 21.* ]] || die "HaikuPorts' llvm21 has LLVM $llvm_version"
components=$(sed -n '/^set(LLVM_AVAILABLE_LIBS/,/)/p' "$llvm_cmake" | tr ' ;\n' '\n\n\n' \
	| sed -n 's/^LLVM\([A-Za-z0-9]*\))\{0,1\}$/\1/p' | tr 'A-Z' 'a-z' | sort -u | tr '\n' ' ')
# and llvm-config's pseudo components (LLVM_DYLIB_COMPONENTS is "all")
components+="all all-targets engine native nativecodegen"
cat > "$W/llvm-config" <<EOF
#!/bin/sh
# llvm-config for HaikuPorts' LLVM $llvm_version in $system (made by build-gl-x86_64.sh)
out=""
for arg; do
	case \$arg in
		--version) out="\$out $llvm_version" ;;
		--prefix) out="\$out $system" ;;
		--includedir) out="\$out $system/develop/headers" ;;
		--libdir) out="\$out $system/develop/lib" ;;
		--cppflags) out="\$out -I$system/develop/headers -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS" ;;
		--cflags) out="\$out -I$system/develop/headers -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS" ;;
		--cxxflags) out="\$out -I$system/develop/headers -std=c++17 -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS" ;;
		--ldflags) out="\$out -L$system/develop/lib" ;;
		--libs) out="\$out -lLLVM-21" ;;
		--libfiles) out="\$out $system/develop/lib/libLLVM-21.so" ;;
		--system-libs) ;;
		--shared-mode) out="\$out shared" ;;
		--has-rtti) out="\$out YES" ;;
		--assertion-mode) out="\$out OFF" ;;
		--build-mode) out="\$out Release" ;;
		--targets-built) out="\$out X86 AMDGPU NVPTX SPIRV" ;;
		--components) out="\$out $components" ;;
		--link-shared|--link-static|-*) ;;
		*) ;;
	esac
done
echo \$out
EOF
chmod 755 "$W/llvm-config"
"$W/llvm-config" --version --shared-mode

cat > "$W/cross.ini" <<EOF
[binaries]
c = '${CROSS}gcc'
cpp = '${CROSS}g++'
ar = '${CROSS}ar'
strip = '${CROSS}strip'
pkg-config = '/usr/bin/pkg-config'
llvm-config = '$W/llvm-config'

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
cross() { env -u CC -u CXX -u CPPFLAGS -u CFLAGS -u CXXFLAGS -u LDFLAGS \
	PKG_CONFIG_LIBDIR="$system/develop/lib/pkgconfig:$system/lib/pkgconfig" \
	PKG_CONFIG_SYSROOT_DIR="$GLROOT" PKG_CONFIG_PATH= "$@"; }

note "libglvnd"
rm -rf "$W/glvnd-build" "$W/glvnd-install"
cross meson setup "$W/glvnd-build" "$W/libglvnd" --cross-file="$W/cross.ini" \
	--buildtype=release --prefix=/boot/system --libdir=lib \
	--includedir=develop/headers/os/opengl --sysconfdir=settings --wrap-mode=nofallback \
	-Dx11=disabled -Dglx=disabled -Dhgl=true -Dgles1=false -Dgles2=true -Degl=true \
	> "$W/glvnd-configure.log" || { tail -30 "$W/glvnd-configure.log"; die "libglvnd configure failed"; }
cross ninja -C "$W/glvnd-build" -j"$JOBS" > "$W/glvnd-build.log" \
	|| { grep -m5 -A8 error "$W/glvnd-build.log"; die "libglvnd build failed"; }
DESTDIR=$W/glvnd-install cross meson install -C "$W/glvnd-build" --no-rebuild > /dev/null
glvnd=$W/glvnd-install/boot/system
# The SDK has HaikuPorts' Mesa headers, linked into os/opengl: libglvnd's
# directories replace those links.
(cd "$glvnd" && find . -mindepth 1 -type d) | while read -r dir; do
	[[ ! -L $system/$dir ]] || rm "$system/$dir"
done
cp -a "$glvnd/." "$system/"
headers=$system/develop/headers
mv "$headers/os/opengl/OpenGLKit.h" "$headers/os/OpenGLKit.h"
mv "$headers/os/opengl/opengl/GLView.h" "$headers/os/opengl/GLView.h"
for name in libGL.so libEGL.so libOpenGL.so libGLESv2.so libGLdispatch.so; do
	ln -sfn "../../lib/$name" "$system/develop/lib/$name"
done

note "Mesa: llvmpipe, softpipe, zink"
# The options of Summit's tools/mesa-vm/guest-build.sh, with zink.
B=$W/mesa-build
key=$(printf '%s\n' "$MESA_COMMIT" "$GLVND_COMMIT" | cat - "$W/cross.ini" "$W/haikuports.json" | sha256sum | cut -c1-16)
if [[ ! -f $B/build.ninja || $(cat "$B.key" 2>/dev/null) != "$key" ]]; then
	rm -rf "$B"
	cross meson setup "$B" "$W/mesa" --cross-file="$W/cross.ini" --prefix=/boot/system \
		--libdir=lib --buildtype=release --wrap-mode=nofallback \
		-Dplatforms=haiku -Degl=enabled -Dglvnd=enabled -Dglx=disabled -Dgbm=disabled \
		-Dopengl=true -Dgles1=disabled -Dgles2=enabled \
		-Dgallium-drivers=softpipe,llvmpipe,zink '-Dvulkan-drivers=[]' \
		-Dgallium-va=disabled -Dgallium-rusticl=false -Dllvm=enabled -Dshared-llvm=enabled \
		-Dshader-cache=enabled -Dxmlconfig=disabled -Dexpat=disabled -Dzstd=disabled -Dzlib=enabled \
		-Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled -Dspirv-tools=disabled \
		-Dbuild-tests=false '-Dtools=[]' > "$B.configure.log" \
		|| { tail -40 "$B.configure.log"; die "Mesa configure failed (log: $B.configure.log)"; }
	echo "$key" > "$B.key"
fi
cross ninja -C "$B" -j"$JOBS" > "$B.build.log" \
	|| { grep -m5 -B2 -A8 'error' "$B.build.log"; die "Mesa build failed (log: $B.build.log)"; }
rm -rf "$W/mesa-install"
DESTDIR=$W/mesa-install cross meson install -C "$B" --no-rebuild > /dev/null
mesa=$W/mesa-install/boot/system
# Haiku's loader cannot do TLS descriptors or the initial-exec model in
# libraries it loads late.
if ${CROSS}readelf -rW "$mesa"/lib/lib*.so* "$glvnd"/lib/lib*.so* 2>/dev/null \
		| grep -qE 'TLSDESC|R_X86_64_TPOFF'; then
	die "unsupported TLS relocations in the GL libraries"
fi

note "results"
# The engine build's overlay: libglvnd as installed.
overlay=$W/gl-overlay/boot/system
rm -rf "$W/gl-overlay"
mkdir -p "$overlay/develop/lib"
cp -a "$glvnd/." "$overlay/"
mv "$overlay/develop/headers/os/opengl/OpenGLKit.h" "$overlay/develop/headers/os/OpenGLKit.h"
mv "$overlay/develop/headers/os/opengl/opengl/GLView.h" "$overlay/develop/headers/os/opengl/GLView.h"
rmdir "$overlay/develop/headers/os/opengl/opengl"
for name in libGL.so libEGL.so libOpenGL.so libGLESv2.so libGLdispatch.so; do
	ln -sfn "../../lib/$name" "$overlay/develop/lib/$name"
done
mkdir -p "$OUT/x86_64"
rsync -rlc --delete "$W/gl-overlay/" "$OUT/x86_64/"
# The private Mesa for summit_webkit: every library libglvnd and Mesa install.
private=$W/private
rm -rf "$private"
mkdir -p "$private/lib"
cp -a "$glvnd"/lib/*.so* "$mesa"/lib/*.so* "$private/lib/"
${CROSS}strip --strip-unneeded "$private"/lib/*.so*
cp "$W/haikuports.json" "$private/haikuports.json"
printf 'mesa %s\nlibglvnd %s\nhaiku %s\n' "$MESA_COMMIT" "$GLVND_COMMIT" "$HAIKU_REVISION" > "$private/gl-sources.txt"
mkdir -p "$OUT/x86_64-mesa"
rsync -rlc --delete "$private/" "$OUT/x86_64-mesa/"
ls "$OUT/x86_64-mesa/lib"
echo "x86_64 GL stack built from mesa ${MESA_COMMIT:0:12}, libglvnd ${GLVND_COMMIT:0:12} (LLVM $llvm_version)"

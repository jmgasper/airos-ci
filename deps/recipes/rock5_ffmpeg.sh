# rock5_ffmpeg (arm64): FFmpeg 6.1.6 with Rockchip MPP hardware video decoding
# for the ROCK 5 ITX (RK3588 VPU), as tools/rock5-itx/build-ffmpeg-arm64.sh and
# package-ffmpeg-arm64.sh make it, but from the forks:
#   - FFmpeg: jmgasper/ffmpeg airos-6.1.6 (HaikuPorts patch set)
#   - MPP:    jmgasper/mpp airos-14729dd (Haiku port + haiku/compat headers)
#   - the Haiku FFmpeg media plugin, the RockchipMppDecoder add-on
#     (00_rockchip_mpp) and Rock5MediaPlayer from the haiku tree the SDK was
#     built from ($HAIKU_SOURCE).
# FFmpeg's libraries and headers also go into DEPS, for airTime.
VERSION=6.1.6
PKG_REVISION=3
FORK=ffmpeg
NO_PACKAGE=1
STAMP_EXTRA="mpp:$(fork_info mpp commit)"
SUMMARY="FFmpeg codecs and Media Kit plugin for ROCK 5 ITX"
COPYRIGHT="2000-2024 FFmpeg developers"
LICENSE="LGPLv2.1"

fetch_source() {
	[[ $ARCH == arm64 ]] || die "rock5_ffmpeg is arm64 only"
	fork_checkout ffmpeg "$SRC"
	FFMPEG_COMMIT=$FORK_COMMIT
	fork_checkout mpp "$WORKDIR/rock5_ffmpeg/mpp"
	MPP_COMMIT=$FORK_COMMIT
}

build() {
	local top=$WORKDIR/rock5_ffmpeg mpp=$WORKDIR/rock5_ffmpeg/mpp
	local mppb=$top/mpp-build compat=$top/mpp/haiku/compat plug=$top/plugin hs=$HAIKU_SOURCE

	# 1. MPP
	rm -rf "$mppb"
	cmake -S "$mpp" -B "$mppb" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
		-DCMAKE_BUILD_TYPE=Release -DBUILD_TEST=OFF -DBUILD_SHARED_LIBS=ON \
		"-DCMAKE_C_FLAGS=-I$compat -include $compat/asm/ioctl.h" \
		"-DCMAKE_CXX_FLAGS=-I$compat -include $compat/asm/ioctl.h" \
		-DCMAKE_SHARED_LINKER_FLAGS=-Wl,--no-undefined
	cmake --build "$mppb" --target rockchip_mpp -j"$JOBS"
	local mpplib mppsoname
	mpplib=$(readlink -f "$mppb/mpp/librockchip_mpp.so")
	mppsoname=$(${CROSS}readelf -d "$mpplib" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')

	# 2. FFmpeg
	./configure --prefix=$PREFIX --libdir=$PREFIX/lib --incdir=$PREFIX/develop/headers \
		--target-os=haiku --arch=aarch64 --enable-cross-compile --cross-prefix="$CROSS" \
		--sysroot="$SYSROOT" --disable-programs --disable-doc \
		--disable-static --enable-shared --enable-pic --disable-avdevice \
		--disable-network --disable-autodetect --enable-pthreads --enable-small
	make -j"$JOBS"
	make install DESTDIR="$STAGE"
	local ff=$STAGE$PREFIX inc=$STAGE$PREFIX/develop/headers

	# 3. media plugin, MPP decoder add-on, player
	rm -rf "$plug"
	mkdir -p "$plug"
	local file
	for file in AVCodecDecoder AVCodecEncoder AVFormatReader AVFormatWriter \
			CodecTable DemuxerTable EncoderTable FFmpegPlugin MuxerTable \
			CpuCapabilities gfx_conv_c gfx_conv_c_lookup gfx_util; do
		${CROSS}g++ --sysroot="$SYSROOT" -std=gnu++17 -O2 -fPIC \
			-D__STDC_CONSTANT_MACROS -Wdeprecated -I"$inc" \
			-iquote "$inc/libavcodec" -iquote "$inc/libavformat" -iquote "$inc/libavfilter" \
			-iquote "$inc/libavutil" -iquote "$inc/libswscale" -iquote "$inc/libswresample" \
			-I"$hs/headers/private/media" -I"$hs/headers/private/media/experimental" \
			-I"$hs/headers/private/shared" \
			-c "$hs/src/add-ons/media/plugins/ffmpeg/$file.cpp" -o "$plug/$file.o"
	done
	${CROSS}g++ --sysroot="$SYSROOT" -shared -o "$plug/ffmpeg" "$plug"/*.o \
		-L"$ff/lib" -Wl,-rpath-link,"$SYSROOT/boot/system/lib" -Wl,-rpath-link,"$ff/lib" \
		-lavformat -lavcodec -lavfilter -lswscale -lswresample -lavutil -lbe -lmedia -lsupc++
	${CROSS}g++ --sysroot="$SYSROOT" -std=gnu++17 -O2 -fPIC \
		-Wall -Wextra -Werror -D__STDC_CONSTANT_MACROS -I"$inc" \
		-iquote "$inc/libavcodec" -iquote "$inc/libavutil" -iquote "$inc/libswscale" \
		-I"$hs/headers/private/media" -I"$hs/headers/private/shared" \
		-I"$mpp/inc" -I"$mpp/mpp/inc" \
		-c "$hs/tools/rock5-itx/RockchipMppDecoder.cpp" -o "$plug/RockchipMppDecoder.mpp.o"
	${CROSS}g++ --sysroot="$SYSROOT" -shared -o "$plug/00_rockchip_mpp" \
		"$plug/RockchipMppDecoder.mpp.o" -L"$mppb/mpp" -L"$ff/lib" \
		-Wl,-rpath-link,"$SYSROOT/boot/system/lib" -Wl,-rpath-link,"$ff/lib" -Wl,--no-undefined \
		-lrockchip_mpp -lavcodec -lswscale -lavutil -lbe -lmedia -lsupc++
	${CROSS}g++ --sysroot="$SYSROOT" -std=gnu++17 -O2 -pthread \
		-o "$plug/Rock5MediaPlayer" "$hs/tools/rock5-itx/Rock5MediaPlayer.cpp" \
		-Wl,-rpath-link,"$SYSROOT/boot/system/lib" -lbe -lmedia -lsupc++

	# 4. the rock5_ffmpeg package
	local pkg=$top/package
	rm -rf "$pkg"
	mkdir -p "$pkg/lib" "$pkg/add-ons/media/plugins" "$pkg/apps" "$pkg/data/licenses"
	cp -a "$ff/lib"/lib{avcodec,avfilter,avformat,avutil,swresample,swscale}.so* "$pkg/lib/"
	cp "$mpplib" "$pkg/lib/$mppsoname"
	cp "$plug/ffmpeg" "$plug/00_rockchip_mpp" "$pkg/add-ons/media/plugins/"
	cp "$plug/Rock5MediaPlayer" "$pkg/apps/"
	${CROSS}strip --strip-debug "$pkg/add-ons/media/plugins/ffmpeg" \
		"$pkg/add-ons/media/plugins/00_rockchip_mpp" "$pkg/apps/Rock5MediaPlayer"
	cp COPYING.LGPLv2.1 "$pkg/data/licenses/LGPLv2.1"
	cp "$hs/data/system/data/licenses/MIT" "$hs/data/system/data/licenses/Apache v2" "$pkg/data/licenses/"
	cat > "$pkg/.PackageInfo" <<EOF
name rock5_ffmpeg
version $VERSION-$PKG_REVISION
architecture arm64
summary "FFmpeg codecs and Media Kit plugin for ROCK 5 ITX"
description "FFmpeg $VERSION shared libraries, Rockchip MPP hardware video decoding, Media Kit plugins, and a sample movie player for arm64. Built by air/OS CI from jmgasper/ffmpeg ${FFMPEG_COMMIT:0:12}, jmgasper/mpp ${MPP_COMMIT:0:12} and jmgasper/haiku ${HAIKU_SHA:0:12}."
packager "air/OS CI"
vendor "air/OS"
copyrights { "2000-2024 FFmpeg developers" "2015-2026 Rockchip Electronics Co. LTD" "2004-2026 Haiku, Inc." }
licenses { "LGPLv2.1" "Apache v2" "MIT" }
provides {
	rock5_ffmpeg = $VERSION
}
requires {
	haiku >= r1~beta6
}
EOF
	local file=$AIROS_PACKAGES/$ARCH/rock5_ffmpeg-$VERSION-$PKG_REVISION-$ARCH.hpkg
	with_lock packages-$ARCH bash -c 'rm -f "$1"/rock5_ffmpeg-[0-9]*-arm64.hpkg' _ "$AIROS_PACKAGES/$ARCH"
	"$TOOLS/package/package" create -q -C "$pkg" "$file"
	echo "package: $file ($mppsoname)"
}

# FluidLite at e64b4b31 (jmgasper/FluidLite airos-e64b4b3), static, with SF3
# sound fonts through its bundled stb Vorbis decoder, as
# tools/rock5-itx/build-fluidlite-arm64.sh builds it: the arm64 Haiku build's
# fluidlite feature (the MIDI kit's synthesizer), which HaikuPorts has no arm64
# package for. Not packaged; the image build links it in.
VERSION=1.2.2
SUMMARY="FluidLite SoundFont synthesizer (static)"
NO_PACKAGE=1
build() {
	cmake_build -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
		-DFLUIDLITE_BUILD_STATIC=ON -DFLUIDLITE_BUILD_SHARED=OFF -DENABLE_SF3=ON -DSTB_VORBIS=ON
}

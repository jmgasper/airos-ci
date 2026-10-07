# airos-ci

Build pipelines for **air/OS**, jmgasper's fork of Haiku
([jmgasper/haiku](https://github.com/jmgasper/haiku)). They run on the
self-hosted build server **airos-build** (Cisco C240, Ubuntu 26.04,
192.168.1.200) through GitHub Actions runners, one per repository.

| Pipeline | Runs from | On | Makes |
|---|---|---|---|
| Images | `jmgasper/haiku` `.github/workflows/airos-images.yml` | pushes to `master`, nightly, by hand | `airos-x86_64.iso` (X399 and other PCs; EFI and BIOS), `airos-arm64.iso` (ROCK 5 ITX and other UEFI arm64 boards), `airos-rpi4.img` (Raspberry Pi 4 SD card for Balena Etcher; boots with no install) |
| Applications | each app repository's `.github/workflows/airos.yml` → [`app.yml`](.github/workflows/app.yml) | pushes to the default branch | x86_64 and arm64 packages of Amp, airTime, Kiri, Clipper, airShot, Burrow, Natter and Turbo Chook; a rolling `latest` release and the "Latest builds" section of each README |
| Summit | `jmgasper/summit` `.github/workflows/airos.yml` → [`summit.yml`](.github/workflows/summit.yml) | pushes to `main` | `summit_webkit` (the WebKit engine) and `summit` (the browser) |
| SDKs and dependencies | this repository, [`sdk-deps.yml`](.github/workflows/sdk-deps.yml) | changes to `sdk/`, `deps/`, `lib/` or the fork pins, by hand | cross SDKs, third-party libraries, firmware, the GL stacks |

The applications and Summit go into the **package pool**
(`/data2/airos/packages/{x86_64,arm64,any}`). Each image build takes the
newest package of everything from there, so an image always has the latest
successful build of every application.

## What the images contain

- Haiku from `jmgasper/haiku` `master`, built with the CI profiles in
  `tools/airos/ci/UserBuildConfig`: `nightly-airos-x86_64`, `airos-arm64` and
  `airos-rpi4`. They contain the fork's drivers and settings, and none of the
  lab tooling (no telnet shell, no SSH keys or password hashes).
- **Summit**, the default web browser (a post-install script makes it the
  preferred app for http/https links, HTML and XHTML), with its engine
  `summit_webkit`. The engine has GL compositing, WebGL, WebRTC and media
  playback.
- Amp, airTime, Kiri, Clipper, airShot, Turbo Chook and Burrow.
- arm64: libraries built from the jmgasper forks (`airos_*` packages:
  OpenSSL, curl, nghttp2, SQLite, TagLib, PCRE2, Scintilla, Lexilla),
  `rock5_ffmpeg` (FFmpeg 6.1.6 with Rockchip MPP hardware decoding),
  `wpa_supplicant`, and the GL stack:
  - ROCK 5: Mesa Panfrost with the Mali CSF firmware;
  - Pi 4: Mesa V3D and V3DV.
- x86_64: HaikuPorts' packages for what the applications need. The x86_64
  `summit_webkit` carries a private Mesa with EGL (llvmpipe, zink), which
  needs HaikuPorts' LLVM 21 and Vulkan loader.
- x86_64: the X399 workstation's NVIDIA stack, in
  `system/non-packaged`, so the boot menu's "Disable user add-ons" turns it
  off:
  - `nvidia_rm` (X547's Haiku OS layer with the RM core of NVIDIA 570.86.16)
    and its accelerant;
  - NVK (Vulkan, jmgasper/mesa-nvk, cross-built with Rust for its shader
    compiler);
  - the Zink OpenGL renderer (Mesa 22.0.5), which the boot script switches
    on only where there is an NVIDIA card;
  - the NVDEC H.264 decoder, which offers nothing on machines without an
    NVIDIA card.

  See [docs/x86_64-gpu.md](docs/x86_64-gpu.md).
- Wi-Fi and Bluetooth firmware (Intel, Realtek, MediaTek, Broadcom for the
  Pi) from `jmgasper/airos-firmware` and the Raspberry Pi firmware forks.

Each image comes with a `manifest.json` listing every package that went in,
with its SHA-256, and the Haiku commit. Images are smoke-tested in QEMU:
x86_64 and arm64 must boot to the desktop; for the Pi, the SD card layout is
checked. They are served at `http://airos-build.local/images/<target>/latest/`.
After the smoke test, `images/publish-github.py` verifies the compressed and
uncompressed image hashes, uploads the image, SHA-256 file and manifest to a
draft GitHub release, verifies GitHub's asset digests, then publishes it as
an immutable prerelease in `jmgasper/haiku`. Tags start with
`image-x86_64-`, `image-arm64-` or `image-rpi4-`. Re-running the publisher
verifies an existing published release without replacing its assets.
The public website discovers the newest published release for each target.

First-boot setup can grow the Pi's system volume to fill the SD card:
[docs/rpi4-sd-auto-resize.md](docs/rpi4-sd-auto-resize.md).

## Build dashboard

`http://192.168.1.200/` (also `http://airos-build.local/`) shows:
- the latest image of each target, with its smoke-test screenshot;
- buttons that start a new build from the latest master of x86_64,
  ARM64/EFI, the Raspberry Pi, or all three. Optionally the build is clean,
  with Haiku compiled from scratch;
- for every build in progress, whoever started it (the page, CI or a
  shell): its stage, a progress bar, the time elapsed, an estimate of the
  time left from the stages of earlier builds of that image, jam's targets,
  and the log.

`dashboard/server.py` runs as the systemd service `airos-dashboard`, behind
the nginx that serves the files under `/images/`. `images/build-image.sh`
and `images/smoke-test.sh` record each build in `/data2/airos/builds`
(`lib/status.py`). Set it up, or update it, with
`sudo dashboard/install.sh`.

## Repository layout

| Path | What |
|---|---|
| `lib/` | `env.sh` (server layout, locks), `sdk.sh` (cross SDK environment), `fork.sh` (check out a fork at its pinned commit) |
| `sdk/build-sdk.sh ARCH [REF]` | builds Haiku at REF: `haiku.hpkg`, `haiku_devel.hpkg`, the host tools, a sysroot. Writes `/data1/airos/sdk/ARCH` |
| `deps/build-deps.sh ARCH` | arm64: the app libraries from the forks (`deps/recipes/`) as `airos_*` packages. x86_64: HaikuPorts packages (`deps/haikuports.py`) |
| `deps/build-firmware.sh` | firmware packages and image inputs, checked against pinned hashes |
| `deps/build-gl.sh` | arm64 GL: Mesa Panfrost (ROCK 5), V3D and V3DV (Pi), libglvnd, GLU, GLTeapot |
| `deps/build-gl-x86_64.sh` | x86_64 GL for Summit's engine: libglvnd and Mesa (llvmpipe, softpipe, zink) |
| `deps/build-nvidia.sh` | x86_64 NVIDIA: `nvidia_rm`, `nvidia_rm_modeset`, the accelerant, the NVDEC media add-on |
| `deps/build-nvk.sh`, `deps/build-zink.sh` | x86_64: NVK (Vulkan) and the Zink renderer add-on of the OpenGL kit |
| `sdk/build-rust.sh` | a pinned Rust nightly with std built for `x86_64-unknown-haiku`, bindgen and cbindgen (NVK's NAK) |
| `apps/build-app-packages.sh` | cross-builds the applications, `summit_webkit` and `summit` into Haiku packages |
| `apps/ci-build-app.sh`, `apps/publish.sh` | the CI step of the app pipelines; the release and README update |
| `summit/` | the Summit pipeline: engine libraries (`build-deps.sh`), WebKit (`build-engine.sh`), packages (`build-summit.sh`) |
| `images/` | `build-image.sh TARGET` (`CLEAN=1`: Haiku from scratch), `smoke-test.sh TARGET`, the nginx that serves the images and the dashboard |
| `dashboard/` | the build dashboard (`server.py`, `index.html`, `install.sh`) |
| `forks/` | the third-party sources as jmgasper forks: `forks.json` (what and how), `forks.lock.json` (pinned commits), `make-forks.py`, `patches/` |
| `runner/register-runner.sh REPO` | adds a self-hosted runner for a repository |
| `server/provision.sh` | the build server's package setup after an Ubuntu install |

## Third-party sources: the forks

Every third-party component the images or packages build from is a
repository under [github.com/jmgasper](https://github.com/jmgasper), on an
`airos-*` branch: upstream at a release tag, plus the air/OS patches as
commits. These include Mesa, libglvnd, FFmpeg, Rockchip MPP, OpenSSL, curl,
SQLite, ICU, WebKit, the firmware, wpa_supplicant, OpenVPN and the rest.
`forks/forks.json` says how each is made: a GitHub fork plus patches, an
import of a release tarball, or a branch at an upstream tag. It also says
where each patch comes from: the Haiku or Summit tree at a pinned commit, or
`forks/patches/`. The builds check out exactly the commits in
`forks/forks.lock.json`.

```sh
forks/make-forks.py --only mesa --force   # remake one fork after changing its patches
```

## Build server layout

| Path | What |
|---|---|
| `/data1/airos/sdk/ARCH` | cross SDKs (`env.sh`, sysroot) |
| `/data1/airos/build`, `/data1/airos/src` | Haiku build directories and worktrees; WebKit trees |
| `/data1/airos/deps/ARCH` | the third-party prefix the app builds compile against |
| `/data1/airos/summit/ARCH` | Summit's engine libraries and its SDK snapshot |
| `/data1/airos/gl`, `/data1/airos/image-inputs` | GL stacks, firmware and other files the images take |
| `/data2/airos/packages` | the package pool |
| `/data2/airos/artifacts/images` | images (the last five per target), served over HTTP |
| `/data2/airos/cache`, `/data2/airos/work`, `/data2/airos/locks` | downloads and git caches, scratch space, `flock` locks |
| `/data1/runner/REPO` | the GitHub runners (user `ghrunner`) |

Jobs from different repositories run at the same time. They coordinate
through locks:
- `haiku-ARCH`: exclusive to rebuild an SDK, its dependencies or an image;
  shared by app builds.
- `summit-ARCH`: the Summit pipeline.
- `webkit-build`: one engine compile at a time.
- `packages-ARCH`: updates to the pool.

## Adding a repository

1. `runner/register-runner.sh REPO` (with `gh` logged in as jmgasper and
   SSH access to the server; `SUDO_PASSWORD` in the environment).
2. Add `.github/workflows/airos.yml` that calls `app.yml` with the app's
   `build-app-packages.sh` name. Push it over SSH: the gh token cannot write
   workflow files.

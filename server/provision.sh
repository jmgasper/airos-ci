#!/bin/bash
# provision.sh: set up the air/OS build server (Ubuntu 26.04 Server, airos-build)
# after a fresh install. Run as root: sudo server/provision.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
USER_NAME=${USER_NAME:-jmgasper}

echo "### apt update/upgrade"
apt-get update -q
apt-get -y -q -o Dpkg::Options::=--force-confold full-upgrade

# Haiku build prerequisites (per Haiku's "pre-requisite software" guide for Debian/Ubuntu),
# including the extras needed for ARM/ARM64/RISC-V targets (Rock 5 / RK3588 work).
HAIKU_PKGS="git nasm bc autoconf automake texinfo flex bison gawk build-essential unzip wget zip less
 zlib1g-dev libzstd-dev xorriso libtool gcc-multilib g++-multilib python3 u-boot-tools util-linux mtools
 device-tree-compiler libgmp-dev libmpfr-dev libmpc-dev attr dosfstools parted gdisk"
# Testing built images under emulation
QEMU_PKGS="qemu-system-x86 qemu-system-arm qemu-system-misc qemu-system-riscv qemu-utils ovmf qemu-efi-aarch64"
# CI / developer tooling; the Mesa host compilers (LLVM 18, libclc, SPIR-V);
# the WebKit build (ruby, gperf, unifdef) and its packaging (patchelf)
DEV_PKGS="curl ca-certificates gnupg jq gh git-lfs ccache cmake ninja-build meson pkg-config python3-pip
 python3-venv rsync zstd xz-utils pigz pv p7zip-full tree ncdu htop btop tmux screen vim
 docker.io docker-buildx docker-compose-v2 cifs-utils nfs-common smartmontools lm-sensors ipmitool avahi-daemon
 socat python3-pil llvm-18-dev libclang-18-dev libclc-18-dev libllvmspirvlib-18-dev
 spirv-tools spirv-tools-dev spirv-headers glslang-tools meson python3-mako python3-pycparser python3-yaml
 python3-packaging libexpat1-dev libdrm-dev
 ruby gperf unifdef patchelf"

echo "### installing packages"
missing=""
for p in $HAIKU_PKGS $QEMU_PKGS $DEV_PKGS; do
  apt-cache show "$p" >/dev/null 2>&1 || missing="$missing $p"
done
[ -n "$missing" ] && echo "WARNING: not in archive, skipping:$missing"
install_list=""
for p in $HAIKU_PKGS $QEMU_PKGS $DEV_PKGS; do
  case " $missing " in *" $p "*) ;; *) install_list="$install_list $p";; esac
done
apt-get -y -q install $install_list

usermod -aG docker,kvm "$USER_NAME"
systemctl enable --now docker

echo "### done"

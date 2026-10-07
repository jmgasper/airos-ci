# Raspberry Pi first-boot storage setup

The Pi image includes **Raspberry Pi Setup** (`rpi_installer`). On first
boot it asks whether to use the whole SD card for air/OS. Choose **Use entire
SD card**, confirm, and restart. **Keep current size** saves that choice;
**Later** offers setup again next boot. Applications → Raspberry Pi Setup
can reopen it manually.

The image remains small for flashing. Its BFS filesystem reserves bitmap
and journal space at creation (`block_size 4096; growable true`). The app
validates the boot device and standard FAT32 + BFS layout, saves the original
partition table, then extends only the BFS partition. The next boot grows
BFS before publishing files, without moving existing data or invoking the
experimental general resize ioctl.

The `airos-rpi4` profile requires `rpi_installer` in the image package set;
`images/build-image.sh rpi4` selects it from the ARM64 package pool. Build the
app from the workspace's `apps/rpi-installer` using the Haiku tree's
`tools/airos/build-arm64-app-packages.sh ... rpi_installer`, then install the
package into the pool under the `packages-arm64` lock.

Host filesystem tests cover 128 GB, 128 GiB and 2 TiB growth. Native ARM64
emulation covers the prompt, decline, cancel, expansion, restart and saved
completion. Pi SD-controller emulation also passed the filesystem growth
and SD flush barriers. A physical 128 GB card remains a separate hardware
test.

See [the implementation and validation notes](https://github.com/jmgasper/haiku/blob/master/docs/rpi4/INSTALLER.md).

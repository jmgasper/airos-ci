# Raspberry Pi SD card: growing air/OS to fill the card

**Status: not implemented (future work).** The `rpi4` image boots straight
from the SD card that Balena Etcher writes; nothing has to be installed. But
the system partition stays at the size it has in the image, whatever the size
of the card.

## Today

`images/build-image.sh rpi4` makes `airos-rpi4.img` (3.75 GiB), with an MBR
partition table:

| # | Start (sector) | Size | Type | Contents |
|---|---|---|---|---|
| 1 | 8192 | 256 MiB | `0c` FAT32 (LBA) | Pi firmware, `config.txt`, `airos-loader.img`, `airos-boot.tgz`, device trees |
| 2 | 532480 | 3.5 GiB | `eb` BeOS | the BFS system volume (`/boot`) |

On a 32 GB card the other ~28 GB are unpartitioned. You can make a second
partition there with DriveSetup and initialise it as BFS, but `/boot` does
not grow.

## What has to happen on first boot

1. Grow partition 2 in the MBR so it runs to the end of the card. Leave the
   start sector where it is.
2. Grow the BFS volume on partition 2 into that space, while it is mounted
   as `/boot`. It is the volume the system runs from.
3. Record that this is done, so it runs only once. The grow must be safe if
   the board loses power partway through.

## What Haiku has already

- **Growing an MBR partition.** The intel partitioning system
  (`src/add-ons/kernel/partitioning_systems/intel/intel.cpp`) supports
  `B_DISK_SYSTEM_SUPPORTS_RESIZING_CHILD` (`pm_resize_child`). Userland
  reaches it through the Disk Device API (`BPartition::ResizeChild()` on the
  card's device, then `BDiskDevice::CommitModifications()`), as DriveSetup
  does.
- **Growing BFS.** `src/add-ons/kernel/file_systems/bfs/ResizeVisitor.cpp`
  grows and shrinks a volume. It works out the new block bitmap size, moves
  any data that is in the way of the bigger bitmap, moves the log, and
  updates the superblock. Two things can call it:
  - the `BFS_IOCTL_RESIZE` ioctl (`bfs_control.h`, `resize_control { new_size,
    dry_run }`) on any file of a mounted volume (`kernel_interface.cpp`,
    `bfs_ioctl`);
  - `bfs_shell`'s `resizefs` command (`src/tools/bfs_shell/command_resizefs.cpp`),
    which works on an image file on the build host.
- **Limits.** `ResizeVisitor::_IsResizePossible()` refuses to grow past
  65535 allocation groups. With the image's 2 KiB blocks that is far more
  than any SD card.

## What is missing

- **`bfs_resize()` is compiled out.** The disk-system hook in
  `kernel_interface.cpp` sits under `#if 0` and returns `B_ERROR`, so the
  Disk Device API (and DriveSetup) cannot resize BFS. Only the ioctl works.
- **The device grows only after a rescan.** The partition device
  `/dev/disk/.../2` keeps the size the partition table had at boot. BFS can
  only write past the old end after the disk device manager has applied the
  new partition size, and it will not change a mounted partition's size
  outside a resize job.
- **It is untested on a live system volume.** Nobody has run
  `ResizeVisitor`'s grow path on a mounted volume with a running system on
  it. Its comments carry open TODOs about the block cache while mounted.

## Proposed implementation

In the Haiku tree (jmgasper/haiku, `rpi4` support):

1. **Enable `bfs_resize()`.** Remove the `#if 0` and use `ResizeVisitor` on
   the mounted volume's `Volume`, as the disabled code already sketches.
   Keep `fs_shell` out. Allow growing only (refuse a new size smaller than
   the current one) until shrinking has been tested.
2. **Write a first-boot tool `expand_boot_volume`** (`src/bin/`, or under
   `tools/airos/`), run by a launch_daemon job in `data/boot/rpi`. It only
   runs on the `airos-rpi4` profile, and only while
   `/boot/system/settings/airos/boot-volume-expanded` is missing. It should:
   - find the boot volume's partition (`BVolumeRoster::GetBootVolume()` →
     `BDiskDeviceRoster::FindPartitionByVolume()`) and its disk device;
   - return quietly unless the partition is the last one, the map is MBR
     (`intel`), and there is at least 64 MiB free after it;
   - `PrepareModifications()`, then `ResizeChild()` to the end of the device
     (rounded down to 4 MiB), then `CommitModifications()`. Committing runs
     `pm_resize_child`, and then `bfs_resize` for the content, because the
     disk device manager resizes a child's content with it;
   - write the marker file, `sync`, and log the old and new sizes to the
     syslog.
3. **Fall back to the ioctl** if the disk device manager will not resize
   mounted content: grow the partition with the Disk Device API, wait for the
   rescan, then call `ioctl(BFS_IOCTL_RESIZE)` on `/boot` with the new
   partition size.
4. **Image side.** Nothing changes. The image stays small (3.75 GiB, about
   500 MB after xz), so Etcher writes it quickly.

## Testing

- On the build host: make an image, copy it onto a bigger file, grow
  partition 2 with `sfdisk`, then run `bfs_shell`'s `resizefs` and check the
  result with its `checkfs`. This tests `ResizeVisitor` without hardware and
  could become part of `images/smoke-test.sh rpi4`.
- In QEMU (x86_64, MBR disk image with a BFS system partition, larger
  virtual disk): run the first-boot job and check the volume, then `checkfs`
  it after a reboot.
- On a Pi 4: cards of 16, 32 and 128 GB. Pull the power during the grow and
  check that the next boot recovers (BFS journal replay) and that the job
  runs again.

## Until then

- Make a data partition in the free space with DriveSetup (partition,
  then initialise as BFS) and keep large files there.
- Or, before writing the card, grow the image on a Linux host
  (`ResizeVisitor` is untested, so keep a copy of the image). `bfs_shell` is
  built with the Haiku tree (`jam -q "<build>bfs_shell"`) and reads its
  commands from stdin:

  ```sh
  truncate -s 16G airos-rpi4.img
  echo ', +' | sfdisk -N 2 airos-rpi4.img        # partition 2 to the end
  size=$(( $(sfdisk -l -o Sectors airos-rpi4.img | tail -1) * 512 ))
  printf 'resizefs %d\ncheckfs\n' "$size" \
      | bfs_shell --start-offset $((532480 * 512)) airos-rpi4.img
  ```

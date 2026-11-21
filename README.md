# ubuntu-zfs-root

Installs Ubuntu Server onto a ZFS root pool booted by [ZFSBootMenu](https://zfsbootmenu.org).

- Root pool as single disk, mirror, raidz1 or raidz2
- One ESP per disk, each with its own UEFI boot entry, so any disk can boot
- Plain prompts, no dialog boxes, works in any terminal size
- Fails loudly with the line number on any error; full log in `/root/ubuntu-zfs-root.log`

## Requirements

- UEFI boot (CSM/legacy off), SATA controller in AHCI mode, not RAID
- Ubuntu live ISO (26.04 server tested) with network access
- Disks for the root pool can be fully wiped

## Usage

Boot the live ISO. At the installer's language screen press `Ctrl+Z` (or `Ctrl+Alt+F2`)
for a shell, run `sudo -i`, then:

```bash
apt update && apt install -y git
git clone https://github.com/Battleroid/ubuntu-zfs-root.git
cd ubuntu-zfs-root
./install.sh                 # prompts for everything
./install.sh config.env      # or preset values, see config.example
./install.sh -d              # debug: print every command with its line number
```

The script lists disks (the live USB and empty card readers are hidden), asks which to use,
shows a summary and asks you to type `WIPE` before touching anything.

Inputs are validated before anything is wiped. Timezones must be Region/City (e.g.
`America/New_York`); abbreviations like `EST` are rejected because they ignore daylight saving.

### Running over SSH

Easier for copy/paste. On the server console:

```bash
passwd ubuntu-server     # live user; root login over SSH is disabled
ip -4 a                  # server IP
```

Then `ssh ubuntu-server@<ip>`, `sudo -i`, and run the steps above.

## Layout

| Dataset | Mount | Notes |
|---|---|---|
| `rpool/ROOT/ubuntu` | `/` | Boot environment, includes `/var/lib` so package state rolls back with the OS |
| `rpool/home` | `/home` | |
| `rpool/var/log` | `/var/log` | Survives rollbacks |
| `rpool/var/cache` | `/var/cache` | Not auto-snapshotted |
| `rpool/var/tmp` | `/var/tmp` | Not auto-snapshotted |

Pool options: `ashift=12`, `autotrim=on`, `compression=lz4`, `compatibility=openzfs-2.2-linux`
(keeps the pool readable by ZFSBootMenu's bundled ZFS). Monthly full trim is enabled via
`org.debian:periodic-trim`.

## Config variables

All optional. Anything unset is prompted for.

| Variable | Default |
|---|---|
| `DISKS` | prompted; space-separated `/dev/disk/by-id/...` paths |
| `TOPOLOGY` | `single` / `mirror` / `raidz1` / `raidz2`, inferred for 1-2 disks |
| `POOL` | `rpool` |
| `NEW_HOSTNAME`, `USERNAME` | prompted |
| `PASSWORD_HASH` | prompted; or `openssl passwd -6` output |
| `GH_USER` | GitHub user for `ssh-import-id`, `-` for none |
| `TIMEZONE` | live system's timezone |
| `SUITE` | `resolute` |
| `KERNEL` | `linux-generic` (e.g. `linux-generic-hwe-26.04`) |
| `ESP_SIZE` | `1G`; size of the EFI System Partition on each disk (the FAT32 partition UEFI boots from). It only holds the ZFSBootMenu image (~100MB), so `512M` also works. Uses `sgdisk` size format |
| `MIRROR` | `http://archive.ubuntu.com/ubuntu` |
| `DISCARD` | `n`; `y` runs `blkdiscard` on SSDs before partitioning |
| `CONFIRM` | set to `WIPE` to skip the final confirmation |

## Boot

Each root disk gets a 1G ESP holding the prebuilt ZFSBootMenu EFI image
(`EFI/ZBM/VMLINUZ.EFI` plus a `VMLINUZ-BACKUP.EFI` copy) and its own UEFI boot entry. Kernels
and initramfs live on ZFS, so the ESPs never change during normal updates. Only the first
disk's ESP is mounted at `/boot/efi`.

To update ZFSBootMenu later, download the new image and copy it to every ESP:

```bash
curl -fsSL https://get.zfsbootmenu.org/efi -o /tmp/zbm.efi
for esp in $(lsblk -lnpo NAME,PARTLABEL | awk '$2=="EFI"{print $1}'); do
    mount "$esp" /mnt && cp /tmp/zbm.efi /mnt/EFI/ZBM/VMLINUZ.EFI && umount /mnt
done
```

## After first boot

```bash
zpool status rpool              # mirror-0, all disks ONLINE
zfs list
efibootmgr | grep ZFSBootMenu   # one entry per disk
```

Boot environments: snapshot before big changes with `zfs snapshot rpool/ROOT/ubuntu@pre-upgrade`.
ZFSBootMenu can boot or roll back to any snapshot from its menu (press Esc during the countdown).

### Replacing a failed root disk

```bash
sgdisk -R /dev/disk/by-id/NEW /dev/disk/by-id/GOOD    # copy partition layout
sgdisk -G /dev/disk/by-id/NEW                         # new random GUIDs
zpool replace rpool OLD-part2 /dev/disk/by-id/NEW-part2
mkfs.vfat -F32 -n EFI /dev/disk/by-id/NEW-part1       # then copy EFI/ZBM from a good ESP
efibootmgr -c -d /dev/sdX -p 1 -L "ZFSBootMenu (new)" -l '\EFI\ZBM\VMLINUZ.EFI'
```

## Troubleshooting

- **Run with `-d`.** Every command is printed with its script line number and logged to
  `/root/ubuntu-zfs-root.log`. The password prompt is excluded from the trace.
- **A partition "did not appear".** The script prints the kernel's view, udev links, the
  on-disk partition table and recent kernel log. An empty on-disk table means the write failed;
  missing kernel partitions with a good table means the re-read failed (reboot the live ISO).
- **Samsung 860/870 EVO.** Whole-disk `blkdiscard` is off by default (`DISCARD=n`) because
  these drives have known queued-TRIM issues on Linux. `autotrim` handles TRIM after install.
- **`pool ... is already imported` / exported pool exists.** A previous attempt left a pool:
  `zpool destroy <name>` (or `zpool import` then destroy), then rerun.
- **`cannot export 'rpool': pool is busy`.** The script runs in a private mount namespace to
  prevent this. If it still happens it warns instead of failing: the pool is synced and the
  host ID matches the new system, so rebooting is safe.
- **ZFSBootMenu: "No boot environments with kernels found".** `/boot` has a kernel but no
  matching `initrd.img-*`. Repair from the live ISO without reinstalling:
  ```bash
  apt update && apt install -y zfsutils-linux
  zpool import -f -N -R /mnt rpool
  zfs mount rpool/ROOT/ubuntu && zfs mount -a
  for m in dev proc sys; do mount --rbind /$m /mnt/$m; done
  chroot /mnt update-initramfs -c -k all
  umount -Rl /mnt/dev /mnt/proc /mnt/sys && zpool export rpool
  ```
  The installer now creates and verifies the initramfs for every kernel, so new installs
  should not hit this.
- **Rerunning is safe.** Each run wipes and repartitions the selected disks from scratch and
  removes stale ZFSBootMenu boot entries.

## Not included

Encryption, swap, desktops and SecureBoot. Add swap later as a zvol or file if needed.

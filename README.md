# ubuntu-zfs-root

Installs Ubuntu Server onto a ZFS root pool booted by [ZFSBootMenu](https://zfsbootmenu.org).

- Root pool as single disk, mirror, raidz1 or raidz2
- One ESP per disk, each with its own UEFI boot entry, so any disk can boot
- Plain prompts, no dialog boxes, works in any terminal size
- Fails loudly with the line number on any error; full log in `/root/ubuntu-zfs-root.log`

## Usage

Boot an Ubuntu live ISO (26.04 server works) in UEFI mode, get a root shell, then:

```bash
apt update && apt install -y git
git clone https://github.com/Battleroid/ubuntu-zfs-root.git
cd ubuntu-zfs-root
./install.sh                 # prompts for everything
./install.sh config.env      # or preset values, see config.example
```

The script lists disks (the live USB is hidden), asks which to use, shows a summary and
asks you to type `WIPE` before touching anything.

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
| `ESP_SIZE` | `1G` |
| `MIRROR` | `http://archive.ubuntu.com/ubuntu` |
| `CONFIRM` | set to `WIPE` to skip the final confirmation |

## Not included

Encryption, swap, desktops and SecureBoot. Add swap later as a zvol or file if needed.

## After first boot

```bash
zpool status rpool
efibootmgr | grep ZFSBootMenu   # one entry per disk
```

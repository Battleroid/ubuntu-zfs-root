#!/usr/bin/env bash
# Install Ubuntu onto a ZFS root pool (single, mirror or raidz) booted by ZFSBootMenu.
# Run as root from an Ubuntu live ISO booted in UEFI mode.
#
# Usage: ./install.sh [-d] [config.env]   (-d prints every command as it runs)
# Any variable below can be preset in the config file; anything unset is prompted for.

set -Eeuo pipefail

LOG=/root/ubuntu-zfs-root.log
TARGET=/mnt
trap 'echo "ERROR: line $LINENO: $BASH_COMMAND (see $LOG)" >&2' ERR

# ---------------------------------------------------------------- helpers

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo; echo "==> $*"; }

# ask VAR "Prompt" [default] - sets VAR unless already set
ask() {
    local var=$1 prompt=$2 def=${3-} reply
    [[ -n ${!var-} ]] && return
    read -r -p "$prompt${def:+ [$def]}: " reply
    printf -v "$var" '%s' "${reply:-$def}"
    [[ -n ${!var} ]] || die "$var is required"
}

# Stable /dev/disk/by-id path for a whole disk, falling back to the kernel name
byid() {
    local dev=$1 fallback="" link
    for link in /dev/disk/by-id/*; do
        [[ $link == *-part* ]] && continue
        [[ $(readlink -f "$link") == "$dev" ]] || continue
        case ${link##*/} in
            wwn-*|nvme-eui.*|*_[0-9]) fallback=${fallback:-$link} ;;
            *) echo "$link"; return ;;
        esac
    done
    echo "${fallback:-$dev}"
}

# Kernel device for partition N of a disk (sdf -> sdf1, nvme0n1 -> nvme0n1p1)
kpart() {
    local dev
    dev=$(readlink -f "$1")
    if [[ $dev =~ [0-9]$ ]]; then echo "${dev}p$2"; else echo "$dev$2"; fi
}

# Most stable path for partition N: by-id link, then by-partuuid, then kernel name
part() {
    local k uuid
    k=$(kpart "$1" "$2")
    if [[ $1 == /dev/disk/by-id/* && -e $1-part$2 ]]; then echo "$1-part$2"; return; fi
    uuid=$(blkid -s PARTUUID -o value "$k" 2>/dev/null || true)
    if [[ -n $uuid && -e /dev/disk/by-partuuid/$uuid ]]; then echo "/dev/disk/by-partuuid/$uuid"; return; fi
    echo "$k"
}

# Make the kernel re-read a disk's partition table and refresh its udev links
rescan() {
    local dev
    dev=$(readlink -f "$1")
    partprobe "$dev" 2>/dev/null || blockdev --rereadpt "$dev" 2>/dev/null || true
    udevadm trigger --action=change "$dev"
    udevadm settle
}

wait_for() {
    local i
    for i in {1..30}; do
        [[ -e $1 ]] && return
        [[ $i -eq 10 || $i -eq 20 ]] && rescan "$2"
        sleep 1
    done
    echo "Kernel view:" >&2
    lsblk -o NAME,SIZE,TYPE,PARTLABEL "$(readlink -f "$2")" >&2 || true
    echo "udev links:" >&2
    local link
    for link in /dev/disk/by-id/*; do
        [[ $(readlink -f "$link") == "$(readlink -f "$2")"* ]] && echo "  $link" >&2
    done
    echo "On-disk table:" >&2
    sgdisk -p "$(readlink -f "$2")" >&2 || true
    echo "Kernel log:" >&2
    dmesg | tail -n 25 >&2 || true
    die "device $1 did not appear"
}

# ---------------------------------------------------------------- preflight

preflight() {
    [[ $EUID -eq 0 ]] || die "run as root (sudo -i)"
    [[ -d /sys/firmware/efi ]] || die "not booted in UEFI mode"
    if [[ ${1-} == -d ]]; then DEBUG=1; shift; fi
    if [[ -n ${1-} ]]; then
        [[ -f $1 ]] || die "config file $1 not found"
        # shellcheck source=/dev/null
        . "$1"
    fi
    exec > >(tee -a "$LOG") 2>&1
    if [[ ${DEBUG-} == 1 ]]; then
        export PS4='+ ${LINENO}: '
        set -x
    fi

    info "Installing live-environment tools"
    apt-get -qq update
    DEBIAN_FRONTEND=noninteractive apt-get -qq -y install \
        zfsutils-linux debootstrap gdisk parted dosfstools efibootmgr curl openssl >/dev/null
    curl -fsI http://archive.ubuntu.com/ubuntu/ >/dev/null || die "no network access to archive.ubuntu.com"
}

# ---------------------------------------------------------------- questions

select_disks() {
    local live="" src pk devs=() i
    src=$(findmnt -no SOURCE /cdrom 2>/dev/null || true)
    if [[ -n $src ]]; then
        pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true)
        live=${pk:+/dev/$pk}
        live=${live:-$src}
    fi

    mapfile -t devs < <(lsblk -dnbpo NAME,TYPE,SIZE | awk '$2=="disk" && $3>0 {print $1}' | grep -vx "${live:-none}")
    [[ ${#devs[@]} -gt 0 ]] || die "no disks found"

    if [[ -z ${DISKS-} ]]; then
        echo
        echo "Available disks (live USB hidden):"
        for i in "${!devs[@]}"; do
            printf '  %d) %-14s %6s  %s\n' "$((i + 1))" "${devs[i]}" \
                "$(lsblk -dno SIZE "${devs[i]}")" "$(lsblk -dno MODEL "${devs[i]}" | xargs)"
        done
        local picks
        read -r -p "Disk numbers for the root pool (space separated): " picks
        DISKS=""
        for i in $picks; do
            [[ $i =~ ^[0-9]+$ && $i -ge 1 && $i -le ${#devs[@]} ]] || die "invalid choice: $i"
            DISKS+="$(byid "${devs[i - 1]}") "
        done
    fi
    read -r -a DISK_LIST <<< "$DISKS"
    [[ ${#DISK_LIST[@]} -gt 0 ]] || die "no disks selected"
    for i in "${DISK_LIST[@]}"; do [[ -b $i ]] || die "$i is not a block device"; done
}

select_topology() {
    local n=${#DISK_LIST[@]}
    if [[ -z ${TOPOLOGY-} ]]; then
        if   [[ $n -eq 1 ]]; then TOPOLOGY=single
        elif [[ $n -eq 2 ]]; then TOPOLOGY=mirror
        else ask TOPOLOGY "Topology (mirror, raidz1, raidz2)" mirror
        fi
    fi
    case $TOPOLOGY in
        single) [[ $n -eq 1 ]] || die "single needs exactly 1 disk"; VDEV=() ;;
        mirror) [[ $n -ge 2 ]] || die "mirror needs 2+ disks";      VDEV=(mirror) ;;
        raidz1) [[ $n -ge 3 ]] || die "raidz1 needs 3+ disks";      VDEV=(raidz1) ;;
        raidz2) [[ $n -ge 4 ]] || die "raidz2 needs 4+ disks";      VDEV=(raidz2) ;;
        *) die "unknown topology: $TOPOLOGY" ;;
    esac
}

ask_settings() {
    ask NEW_HOSTNAME "Hostname"
    ask POOL         "Root pool name" rpool
    ask USERNAME     "Admin username"
    ask GH_USER      "GitHub user to import SSH keys from (- for none)" -
    ask TIMEZONE     "Timezone" "$(cat /etc/timezone 2>/dev/null || echo UTC)"
    SUITE=${SUITE:-resolute}
    KERNEL=${KERNEL:-linux-generic}
    ESP_SIZE=${ESP_SIZE:-1G}
    MIRROR=${MIRROR:-http://archive.ubuntu.com/ubuntu}

    if [[ -z ${PASSWORD_HASH-} ]]; then
        { set +x; } 2>/dev/null   # keep the password out of the log
        local p1 p2
        read -r -s -p "Password for $USERNAME: " p1; echo
        read -r -s -p "Confirm password: " p2; echo
        [[ -n $p1 && $p1 == "$p2" ]] || die "passwords empty or do not match"
        PASSWORD_HASH=$(openssl passwd -6 -stdin <<< "$p1")
        [[ ${DEBUG-} == 1 ]] && set -x
    fi

    zpool list -H -o name 2>/dev/null | grep -qx "$POOL" && die "pool $POOL is already imported"
    # An exported pool with the same name is fine only if it lives on the disks being wiped
    local ids id ours="" d p
    ids=$(zpool import 2>/dev/null | awk -v n="$POOL" '$1=="pool:" {f=($2==n)} f && $1=="id:" {print $2}' || true)
    if [[ -n $ids ]]; then
        for d in "${DISK_LIST[@]}"; do
            for p in "$(readlink -f "$d")"?*; do
                [[ -b $p ]] && ours+=" $(zdb -l "$p" 2>/dev/null | awk '/pool_guid/ {print $2; exit}' || true)"
            done
        done
        for id in $ids; do
            [[ " $ours " == *" $id "* ]] || die "an exported pool named $POOL exists on other disks; destroy it or pick another name"
        done
        echo "Note: existing pool $POOL on the selected disks will be overwritten."
    fi
    return 0
}

confirm() {
    info "Summary"
    echo "  Hostname : $NEW_HOSTNAME"
    echo "  User     : $USERNAME (SSH keys: $GH_USER)"
    echo "  Pool     : $POOL ($TOPOLOGY)"
    echo "  Release  : $SUITE, kernel $KERNEL"
    echo "  Timezone : $TIMEZONE"
    echo "  Disks to WIPE:"
    local d
    for d in "${DISK_LIST[@]}"; do
        printf '    %s  (%s, %s)\n' "$d" "$(readlink -f "$d")" "$(lsblk -dno SIZE "$d")"
    done
    local reply=${CONFIRM-}
    [[ -n $reply ]] || read -r -p "Type WIPE to erase these disks and install: " reply
    [[ $reply == WIPE ]] || die "aborted"
}

# ---------------------------------------------------------------- disks and pool

partition_disks() {
    info "Wiping and partitioning"
    local d p
    for d in "${DISK_LIST[@]}"; do
        for p in "$d"-part* "$(readlink -f "$d")"?*; do
            [[ -b $p ]] || continue
            zpool labelclear -f "$p" 2>/dev/null || true
            mdadm --zero-superblock --force "$p" 2>/dev/null || true
        done
        wipefs -aq "$d"
        if [[ ${DISCARD-n} == y && $(lsblk -dno ROTA "$d") -eq 0 ]]; then
            blkdiscard -f "$d" || true
        fi
        # sgdisk -q exits 0 without writing on some builds; silence via redirect instead
        sgdisk --zap-all "$d" >/dev/null
        sgdisk -n1:1M:+"$ESP_SIZE" -t1:EF00 -c1:EFI \
                  -n2:0:0             -t2:BF00 -c2:"$POOL" "$d" >/dev/null
    done
    for d in "${DISK_LIST[@]}"; do rescan "$d"; done
    for d in "${DISK_LIST[@]}"; do
        wait_for "$(kpart "$d" 1)" "$d"; wait_for "$(kpart "$d" 2)" "$d"
        udevadm settle
        mkfs.vfat -F32 -n EFI "$(part "$d" 1)" >/dev/null
    done
    show_partitions
}

show_partitions() {
    local d
    echo "Partitions:"
    for d in "${DISK_LIST[@]}"; do
        lsblk -o NAME,SIZE,TYPE,PARTLABEL,FSTYPE "$(readlink -f "$d")"
        echo "  using: $(part "$d" 1)"
        echo "         $(part "$d" 2)"
    done
}

create_pool() {
    info "Creating pool $POOL"
    local vdevs=() d
    for d in "${DISK_LIST[@]}"; do vdevs+=("$(part "$d" 2)"); done

    zgenhostid -f
    zpool create -f \
        -o ashift=12 -o autotrim=on \
        -o compatibility=openzfs-2.2-linux \
        -o cachefile=/etc/zfs/zpool.cache \
        -O compression=lz4 -O acltype=posixacl -O xattr=sa \
        -O relatime=on -O dnodesize=auto -O normalization=formD \
        -O canmount=off -O mountpoint=none \
        -R "$TARGET" \
        "$POOL" "${VDEV[@]}" "${vdevs[@]}"

    zfs set org.debian:periodic-trim=enable "$POOL"

    # Boot environment: everything under ROOT/ubuntu rolls back together (incl. /var/lib)
    zfs create -o canmount=off -o mountpoint=none "$POOL/ROOT"
    zfs create -o canmount=noauto -o mountpoint=/ "$POOL/ROOT/ubuntu"
    zfs mount "$POOL/ROOT/ubuntu"
    zpool set bootfs="$POOL/ROOT/ubuntu" "$POOL"
    zfs set org.zfsbootmenu:commandline="quiet" "$POOL/ROOT"

    # Kept outside the boot environment so they survive rollbacks
    zfs create -o mountpoint=/home "$POOL/home"
    zfs create -o canmount=off -o mountpoint=/var "$POOL/var"
    zfs create "$POOL/var/log"
    zfs create -o com.sun:auto-snapshot=false "$POOL/var/cache"
    zfs create -o com.sun:auto-snapshot=false "$POOL/var/tmp"
    chmod 1777 "$TARGET/var/tmp"
}

# ---------------------------------------------------------------- OS install

install_base() {
    info "Debootstrapping $SUITE"
    debootstrap "$SUITE" "$TARGET" "$MIRROR"

    mkdir -p "$TARGET/etc/zfs"
    cp /etc/hostid "$TARGET/etc/hostid"
    cp /etc/zfs/zpool.cache "$TARGET/etc/zfs/zpool.cache"
    cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf"

    echo "$NEW_HOSTNAME" > "$TARGET/etc/hostname"
    printf '127.0.0.1 localhost\n127.0.1.1 %s\n' "$NEW_HOSTNAME" > "$TARGET/etc/hosts"

    rm -f "$TARGET/etc/apt/sources.list"
    cat > "$TARGET/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: $MIRROR
Suites: $SUITE $SUITE-updates $SUITE-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu
Suites: $SUITE-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

    mkdir -p "$TARGET/etc/netplan"
    cat > "$TARGET/etc/netplan/01-dhcp.yaml" <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    wired:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: true
EOF
    chmod 600 "$TARGET/etc/netplan/01-dhcp.yaml"

    mkdir -p "$TARGET/boot/efi"
    echo "UUID=$(blkid -s UUID -o value "$(part "${DISK_LIST[0]}" 1)") /boot/efi vfat umask=0077,nofail 0 1" \
        > "$TARGET/etc/fstab"
}

configure_chroot() {
    info "Configuring system in chroot"
    local m
    for m in dev proc sys; do
        mount --rbind "/$m" "$TARGET/$m"
        mount --make-rslave "$TARGET/$m"
    done

    chroot "$TARGET" /usr/bin/env -i \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive \
        KERNEL="$KERNEL" USERNAME="$USERNAME" PASSWORD_HASH="$PASSWORD_HASH" \
        GH_USER="$GH_USER" TIMEZONE="$TIMEZONE" \
        bash -euo pipefail <<'CHROOT'
apt-get -qq update
apt-get -qq -y install locales tzdata >/dev/null
locale-gen en_US.UTF-8 >/dev/null
update-locale LANG=en_US.UTF-8
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
echo "$TIMEZONE" > /etc/timezone

apt-get -qq -y install --no-install-recommends "$KERNEL" >/dev/null
apt-get -qq -y install \
    ubuntu-minimal ubuntu-standard zfs-initramfs zfsutils-linux \
    openssh-server sudo netplan.io systemd-resolved \
    dosfstools efibootmgr curl ssh-import-id >/dev/null

systemctl enable zfs.target zfs-import-cache zfs-mount zfs-import.target \
    systemd-networkd systemd-resolved ssh >/dev/null

useradd -m -s /bin/bash -G sudo,adm -p "$PASSWORD_HASH" "$USERNAME"
passwd -l root >/dev/null
if [ "$GH_USER" != "-" ]; then
    su - "$USERNAME" -c "ssh-import-id gh:$GH_USER" || echo "WARN: ssh key import failed"
fi

# Create (not just update) an initramfs for every installed kernel and verify it has ZFS
for v in $(ls /lib/modules); do
    [ -e "/boot/vmlinuz-$v" ] || continue
    update-initramfs -c -k "$v" 2>/dev/null || update-initramfs -u -k "$v"
    [ -s "/boot/initrd.img-$v" ] || { echo "ERROR: no initramfs for $v" >&2; exit 1; }
    lsinitramfs "/boot/initrd.img-$v" | grep '/zfs\.ko' >/dev/null \
        || { echo "ERROR: initramfs for $v has no zfs module" >&2; exit 1; }
    echo "initramfs OK: $v"
done
apt-get -qq clean
CHROOT
}

install_zfsbootmenu() {
    info "Installing ZFSBootMenu on every ESP"
    local efi=/root/zbm.efi d dev esp tmp
    curl -fsSL https://get.zfsbootmenu.org/efi -o "$efi"
    [[ -s $efi ]] || die "ZFSBootMenu download failed"

    # Remove stale entries from earlier runs
    efibootmgr | awk '/ZFSBootMenu/ {print substr($1, 5, 4)}' | while read -r n; do
        efibootmgr -q -B -b "$n"
    done

    tmp=$(mktemp -d)
    for i in "${!DISK_LIST[@]}"; do
        d=${DISK_LIST[i]}
        esp=$(part "$d" 1)
        mount "$esp" "$tmp"
        mkdir -p "$tmp/EFI/ZBM"
        cp "$efi" "$tmp/EFI/ZBM/VMLINUZ.EFI"
        cp "$efi" "$tmp/EFI/ZBM/VMLINUZ-BACKUP.EFI"
        umount "$tmp"
        dev=$(readlink -f "$d")
        efibootmgr -q -c -d "$dev" -p 1 -L "ZFSBootMenu (disk $((i + 1)))" -l '\EFI\ZBM\VMLINUZ.EFI'
    done
    rmdir "$tmp"
    efibootmgr | grep ZFSBootMenu
}

finish() {
    info "Unmounting and exporting $POOL"
    local m
    for m in dev proc sys; do umount -Rl "$TARGET/$m" 2>/dev/null || true; done
    local i
    for i in 1 2 3; do
        zpool export "$POOL" && break
        if [[ $i -eq 3 ]]; then
            zpool sync "$POOL"
            echo "WARN: could not export $POOL (still busy). Data is synced and the host ID"
            echo "      matches the new system, so it is safe to reboot anyway."
        fi
        sleep 3
    done
    echo
    echo "Done. Remove the USB and reboot. ZFSBootMenu boots $POOL/ROOT/ubuntu."
    echo "Log: $LOG"
}

# ---------------------------------------------------------------- main

[[ $EUID -eq 0 ]] || die "run as root (sudo -i)"

# Run in a private mount namespace so services started during the install never
# pick up copies of the /mnt mounts (which would keep the pool busy at export).
if [[ -z ${ZFSROOT_NS-} ]]; then
    export ZFSROOT_NS=1
    exec unshare --mount --propagation private -- "$(readlink -f "$0")" "$@"
fi

preflight "$@"
select_disks
select_topology
ask_settings
confirm
partition_disks
create_pool
install_base
configure_chroot
install_zfsbootmenu
finish

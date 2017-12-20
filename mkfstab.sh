#!/bin/bash
set -euo pipefail

DISK=$1
VG_NAME=$2

BOOT_PARTITION=$(findfs PARTUUID=$(partx -o UUID -g -r --nr 2 "$DISK"))
EFI_PARTITION=$(findfs PARTUUID=$(partx -o UUID -g -r --nr 1 "$DISK"))

root=$(dmsetup info -C --noheadings -o Name "/dev/$VG_NAME/root")
swap=$(dmsetup info -C --noheadings -o Name "/dev/$VG_NAME/swap")
extra=$(dmsetup info -C --noheadings -o Name "/dev/$VG_NAME/extra")

cat <<EOF
# /etc/fstab: static file system information.
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
UUID=$( blkid -s UUID -o value "${EFI_PARTITION}" ) /boot/efi vfat umask=0077 0 1
UUID=$( blkid -s UUID -o value "${BOOT_PARTITION}" ) /boot ext2 defaults 0 2
"/dev/mapper/$root" / xfs defaults 0 2
"/dev/mapper/$swap" none swap sw 0 0
"/dev/mapper/$extra" /extra xfs defaults 0 1
EOF


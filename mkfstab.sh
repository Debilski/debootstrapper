#!/bin/bash

PARTITION=$1

cat <<EOF
# /etc/fstab: static file system information.
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
UUID=$( blkid -s UUID -o value ${PARTITION}1 ) /boot/efi vfat umask=0077 0 1
UUID=$( blkid -s UUID -o value ${PARTITION}2 ) /boot ext2 defaults 0 2
/dev/mapper/vg--main-root / xfs defaults 0 2
/dev/mapper/vg--main-swap none swap sw 0 0
/dev/mapper/vg--main-extra /extra xfs defaults 0 1
EOF


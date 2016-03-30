#!/bin/bash
set -euo pipefail

source config

echo "Choose partition to install to:"
read PARTITION

echo "Current partition layout on ${PARTITION} is:"
sgdisk -p $PARTITION

echo "Deleting all data. Press button or quit with CTRL-C"
read

sgdisk -Z $PARTITION
sgdisk --new=1:0:+512M --typecode=1:EF00 --change-name=1:"EFI Boot" $PARTITION
sgdisk --new=2:0:+256M --typecode=2:8300 --change-name=2:"Boot" $PARTITION
sgdisk --new=3:0:0     --typecode=3:8E00 --change-name=3:"LVM" $PARTITION

vgcreate vg-main ${PARTITION}3
lvcreate vg-main --size +70G --name root
lvcreate vg-main --size +12G --name swap
lvcreate vg-main --extents 100%FREE --name extra

mkfs.vfat -F 32 ${PARTITION}1
mkfs.ext2 ${PARTITION}2

mkfs.xfs /dev/vg-main/root
mkswap /dev/vg-main/swap
mkfs.xfs /dev/vg-main/extra

mkdir -p /target
mount /dev/vg-main/root /target
mkdir -p /target/boot
mount ${PARTITION}2 /target/boot
mkdir -p /target/boot/efi
mount ${PARTITION}1 /target/boot/efi
mkdir -p /target/extra

debootstrap --arch amd64 jessie /target http://${APT_CACHE}ftp.de.debian.org/debian

sed -i -e s/main/"main contrib non-free"/g /target/etc/apt/sources.list
bash mkfstab.sh $PARTITION > /target/etc/fstab

CHROOT_MOUNTS="dev dev/pts proc sys sys/firmware"
for m in $CHROOT_MOUNTS ; do
  mount --bind /$m /target/$m
done

chroot /target passwd
chroot /target apt-get update
chroot /target apt-get install lvm2 xfsprogs linux-image-amd64 grub-efi-amd64 firmware-linux dbus

chroot /target grub-install --force-extra-removable --recheck $PARTITION
chroot /target update-grub

umount -A --recursive /target/
mount /dev/vg-main/root /target
mount ${PARTITION}2 /target/boot
mount ${PARTITION}1 /target/boot/efi

cat > /target/root/default-environment <<EOF
HOSTNAME=$(basename $(hostname -A) ${DOMAIN})
TIMEZONE=${TIMEZONE}
EOF

cp init-system.service /target/etc/systemd/system/multi-user.target.wants/
systemd-nspawn -D /target -b
rm /target/etc/systemd/system/multi-user.target.wants/init-system.service


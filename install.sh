#!/bin/bash
set -euo pipefail

source config
HOSTNAME=$(basename $(hostname -A) ${DOMAIN})

echo "Assuming hostname is:"
echo $HOSTNAME

VG=$HOSTNAME-vg
echo "This means, we’ll create a volume group with the name ‘$VG’."
echo "Please exit, if this is wrong."

echo ""

echo "Choose partition to install to:"
read PARTITION

echo "Current partition layout on ${PARTITION} is:"
sgdisk -p $PARTITION

echo "Deleting all data. Press button or quit with CTRL-C"
read

sgdisk --clear --zap-all --mbrtogpt $PARTITION
sgdisk --new=1:0:+512M --typecode=1:EF00 --change-name=1:"EFI Boot" $PARTITION
sgdisk --new=2:0:+256M --typecode=2:8300 --change-name=2:"Boot" $PARTITION
sgdisk --new=3:0:0     --typecode=3:8E00 --change-name=3:"LVM" $PARTITION

vgcreate $VG ${PARTITION}3
lvcreate $VG --size +70G --name root
lvcreate $VG --size +12G --name swap
lvcreate $VG --extents 100%FREE --name extra

mkfs.vfat -F 32 ${PARTITION}1
mkfs.ext2 ${PARTITION}2

mkfs.xfs /dev/$VG/root
mkswap /dev/$VG/swap
mkfs.xfs /dev/$VG/extra

mkdir -p /target
mount /dev/$VG/root /target
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
chroot /target apt-get install -y lvm2 xfsprogs linux-image-amd64 grub-efi-amd64 firmware-linux

chroot /target grub-install --force-extra-removable --recheck $PARTITION
chroot /target update-grub

echo "Now umounting the dev mounts again. But sleeping a bit before that."
sync
sleep 3

umount -A --recursive /target/
mount /dev/$VG/root /target
mount ${PARTITION}2 /target/boot
mount ${PARTITION}1 /target/boot/efi

cat > /target/root/default-environment <<EOF
HOSTNAME=${HOSTNAME}
TIMEZONE=${TIMEZONE}
EOF

cp minimal-dhcp-network /target/etc/network/interfaces

cp init-system.service /target/etc/systemd/system/multi-user.target.wants/
systemd-nspawn -D /target apt-get install -y dbus openssh-server aptitude bash-completion
systemd-nspawn -D /target -b
rm /target/etc/systemd/system/multi-user.target.wants/init-system.service

wget -O /target/root/puppetlabs-release-pc1-jessie.deb https://apt.puppetlabs.com/puppetlabs-release-pc1-jessie.deb
systemd-nspawn -D /target dpkg -i /root/puppetlabs-release-pc1-jessie.deb
systemd-nspawn -D /target apt-get update
systemd-nspawn -D /target apt-get -y install lsb-release puppet-agent
systemd-nspawn -D /target apt-get remove puppetlabs-release-pc1


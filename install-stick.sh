#!/bin/bash
set -euo pipefail

source config

TARGET=${TARGET:-/target}

function echo_blue() { echo -e "\e[34m$*\033[0m"; }
function echo_green() { echo -e "\e[32m$*\033[0m"; }

read -s -p "Please set the password for root: " PASSWD

HOSTNAME=debian-boot

echo "Assuming hostname is:"
echo_green $HOSTNAME

VG="$HOSTNAME-vg"
echo "This means, we’ll create a volume group with the name ‘$VG’."
echo "Please exit, if this is wrong."

echo ""

echo_blue "Choose disk to install to:"
read -e DISK

echo "Current partition layout on ${DISK} is:"
sgdisk -p "$DISK"

echo_blue "Deleting all data. Press button or quit with CTRL-C"
read

sgdisk --clear --zap-all --mbrtogpt $DISK
sgdisk --new=1:0:+512M --typecode=1:EF00 --change-name=1:"EFI Boot" $DISK
sgdisk --new=2:0:+256M --typecode=2:8300 --change-name=2:"Boot" $DISK
sgdisk --new=3:0:0     --typecode=3:8E00 --change-name=3:"LVM" $DISK

partprobe $DISK

LVM_PARTITION=$(findfs PARTUUID=$(partx -o UUID -g -r --nr 3 $DISK))
BOOT_PARTITION=$(findfs PARTUUID=$(partx -o UUID -g -r --nr 2 $DISK))
EFI_PARTITION=$(findfs PARTUUID=$(partx -o UUID -g -r --nr 1 $DISK))

echo_blue "Please confirm the automatic selection of partitions:"
echo_green "${EFI_PARTITION} for EFI"
echo_green "${BOOT_PARTITION} for Boot"
echo_green "${LVM_PARTITION} for LVM."
read

vgcreate $VG ${LVM_PARTITION}
lvcreate $VG --size +3G --name root
lvcreate $VG --extents 100%FREE --name extra

mkfs.vfat -F 32 ${EFI_PARTITION}
mkfs.ext2 ${BOOT_PARTITION}

mkfs.xfs /dev/$VG/root
mkfs.xfs /dev/$VG/extra

echo "Installing to tmpfs."
mkdir -p /target-tmpfs
mount -t tmpfs -o size=500M none /target-tmpfs
debootstrap --arch amd64 stretch /target-tmpfs http://${APT_CACHE}ftp.de.debian.org/debian

mkdir -p /target
mount /dev/$VG/root /target
mkdir -p /target/boot
mount ${BOOT_PARTITION} /target/boot
mkdir -p /target/boot/efi
mount ${EFI_PARTITION} /target/boot/efi
mkdir -p /target/extra

echo "Copying over to target."
cp -a --preserve=all /target-tmpfs/* /target/
sync
umount /target-tmpfs

cat >>/target/etc/locale.gen <<EOF
en_US.UTF-8 UTF-8
EOF

cat >/target/etc/default/locale <<EOF
LANG="en_US.UTF-8"
LANGUAGE="en_US:en"
EOF

cat > /target/root/default-environment <<EOF
HOSTNAME=${HOSTNAME}
TIMEZONE=${TIMEZONE}
EOF

cp wired.network /target/etc/systemd/network
rm /target/etc/resolv.conf

SYSTEMD_START_FILE=/target/etc/systemd/system/multi-user.target.wants/init-system.service
cat >$SYSTEMD_START_FILE <<EOF
[Service]
Type=oneshot
EnvironmentFile=/root/default-environment
ExecStart=/usr/bin/hostnamectl set-hostname $HOSTNAME
ExecStart=/usr/bin/timedatectl set-timezone $TIMEZONE
ExecStart=/bin/systemctl enable systemd-networkd
ExecStart=/bin/systemctl enable systemd-networkd
ExecStart=/bin/systemctl disable networking
ExecStart=/bin/systemctl poweroff
EOF


mount -t tmpfs -o size=500M none /target/var/cache
mount -t tmpfs -o size=500M none /target/var/tmp

echo "root:${PASSWD}" | chroot /target chpasswd

systemd-nspawn -D /target apt-get install -y dbus aptitude bash-completion locales
systemd-nspawn -D /target apt-get purge -y ifupdown
# systemd-nspawn -D /target bash -c 'apt-get install -y $(tasksel --task-packages standard)'
systemd-nspawn -D /target -b
rm $SYSTEMD_START_FILE

sed -i -e s/main/"main contrib non-free"/g /target/etc/apt/sources.list
bash mkfstab-stick.sh $DISK $VG > /target/etc/fstab

CHROOT_MOUNTS="dev dev/pts proc sys sys/firmware"
for m in $CHROOT_MOUNTS ; do
  mount --bind /$m /target/$m
done

chroot /target update-locale
chroot /target apt-get update
chroot /target apt-get install -y lvm2 xfsprogs linux-image-amd64 grub-efi-amd64 firmware-linux parted gdisk dosfstools git-core debootstrap openssh-server

chroot /target grub-install --force-extra-removable --recheck --target x86_64-efi $DISK
chroot /target update-grub

echo "Now umounting the dev mounts again. But sleeping a bit before that."
sync
sleep 3

umount -A --recursive /target/

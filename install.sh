#!/bin/bash
set -euo pipefail

source config


TARGET=${TARGET:-/target}
T_BOOT="$TARGET/boot"
T_EFI="$TARGET/boot/efi"
T_EXTRA="$TARGET/extra"

DEBIAN_CODENAME=stretch
GRUB=grub-efi-amd64 # grub-pc

function echo_blue() { echo -e "\e[34m$*\033[0m"; }
function echo_green() { echo -e "\e[32m$*\033[0m"; }

function enter_to_continue() { read -p "Press Enter to continue … "; }

# check for: debootstrap
# dosfstools
# xfsprogs
# lvm
# systemd-container
# partprobe
# sgdisk
which debootstrap mkfs.vfat mkfs.xfs lvs systemd-nspawn partprobe sgdisk > /dev/null || {
  echo_green "Some tools are missing. Installing …"
  apt-get -y install debootstrap dosfstools xfsprogs lvm2 systemd-container gdisk parted
}


read -r -s -p "Please set the password for root: " PASSWD

HOSTNAME=$(basename $(hostname -A) ${DOMAIN})

echo "Assuming hostname is:"
echo_green "$HOSTNAME"

VG="$HOSTNAME-vg"
echo "This means, we’ll create a volume group with the name ‘$VG’."
echo "Please exit, if this is wrong."

echo ""

if vgs "$VG" ; then
   echo_blue "Volume group $VG already exists. Aborting."
   exit 1
fi

echo_blue "Choose disk to install to:"
read -r -e DISK

echo "Current partition layout on ${DISK} is:"
sgdisk -p "$DISK"

echo_blue "Deleting all data. Press button or quit with CTRL-C"
enter_to_continue

sgdisk --clear --zap-all --mbrtogpt "$DISK"
sgdisk --new=1:2048:4095 --typecode=1:EF02 --change-name=1:"BIOS Boot Partition" "$DISK"
sgdisk --new=2:0:+512M   --typecode=2:EF00 --change-name=2:"EFI System Partition" "$DISK"
sgdisk --new=3:0:+1G     --typecode=3:8300 --change-name=3:"Linux /boot" "$DISK"
sgdisk --new=4:0:0       --typecode=4:8E00 --change-name=4:"Linux LVM" "$DISK"

partprobe "$DISK"

LVM_PARTITION=$(findfs PARTUUID="$(partx --output UUID --noheadings --raw --nr 4 "$DISK")")
BOOT_PARTITION=$(findfs PARTUUID="$(partx --output UUID --noheadings --raw --nr 3 "$DISK")")
EFI_PARTITION=$(findfs PARTUUID="$(partx --output UUID --noheadings --raw --nr 2 "$DISK")")

echo_blue "Please confirm the automatic selection of partitions:"
echo_green "${EFI_PARTITION} for EFI"
echo_green "${BOOT_PARTITION} for Boot"
echo_green "${LVM_PARTITION} for LVM."
enter_to_continue


vgcreate "$VG" "${LVM_PARTITION}"
lvcreate "$VG" --size +70G --name root
lvcreate "$VG" --size +12G --name swap
lvcreate "$VG" --extents 100%FREE --name extra

mkfs.vfat -F 32 "${EFI_PARTITION}"
mkfs.ext2 "${BOOT_PARTITION}"

mkfs.xfs -n ftype=1 "/dev/$VG/root" # ftype=1 should be the default nowadays
mkswap "/dev/$VG/swap"
mkfs.xfs -n ftype=1 "/dev/$VG/extra"

mkdir -p /target
mount "/dev/$VG/root" "$TARGET"
mkdir -p /target/boot
mount "${BOOT_PARTITION}" "$T_BOOT"
mkdir -p /target/boot/efi
mount "${EFI_PARTITION}" "$T_EFI"
mkdir -p /target/extra

debootstrap --arch amd64 $DEBIAN_CODENAME "$TARGET" "http://${APT_CACHE}ftp.de.debian.org/debian"

cat >>"$TARGET/etc/locale.gen" <<EOF
en_US.UTF-8 UTF-8
EOF

cat >"$TARGET/etc/default/locale" <<EOF
LANG="en_US.UTF-8"
LANGUAGE="en_US:en"
EOF

cat >"$TARGET/root/default-environment" <<EOF
HOSTNAME=${HOSTNAME}
TIMEZONE=${TIMEZONE}
EOF

cp minimal-dhcp-network /target/etc/network/interfaces

SYSTEMD_START_FILE="$TARGET/etc/systemd/system/multi-user.target.wants/init-system.service"
cat >"$SYSTEMD_START_FILE" <<EOF
[Service]
Type=oneshot
EnvironmentFile=/root/default-environment
ExecStart=/usr/bin/hostnamectl set-hostname $HOSTNAME
ExecStart=/usr/bin/timedatectl set-timezone $TIMEZONE
ExecStart=/bin/systemctl poweroff
EOF

SYSTEMD_NETWORKD_FILE="$TARGET/etc/systemd/network/ethernet.network"
cat >"$SYSTEMD_NETWORKD_FILE" <<EOF
[Match]
Name=en*

[Network]
DHCP=yes
EOF

systemctl restart dbus

systemd-nspawn -D "$TARGET" apt-get install -y dbus openssh-server aptitude bash-completion apt-transport-https
systemd-nspawn -D "$TARGET" bash -c 'apt-get install -y $(tasksel --task-packages standard)'
#systemd-nspawn -D "$TARGET" aptitude install -y '~pstandard' '~prequired' '~pimportant' # tasksel standard
systemd-nspawn -D "$TARGET" -b
rm "$SYSTEMD_START_FILE"
systemd-nspawn -D "$TARGET" systemctl enable systemd-networkd systemd-resolved

sed -i -e s/main/"main contrib non-free"/g "$TARGET/etc/apt/sources.list"
bash mkfstab.sh "$DISK" "$VG" > "$TARGET/etc/fstab"

CHROOT_MOUNTS="dev dev/pts proc sys sys/firmware"
for m in $CHROOT_MOUNTS ; do
  mount --bind "/$m" "/target/$m"
done

chroot "$TARGET" update-locale
echo "root:${PASSWD}" | chroot /target chpasswd
chroot "$TARGET" apt-get update
chroot "$TARGET" apt-get install -y lvm2 xfsprogs linux-image-amd64 $GRUB firmware-linux firmware-linux-nonfree firmware-realtek

chroot "$TARGET" grub-install --force-extra-removable --recheck "$DISK"
chroot "$TARGET" update-grub

echo_green "Now umounting the dev mounts again. But sleeping a bit before that."
sync
sleep 3

umount -A --recursive "$TARGET"
mount "/dev/$VG/root" "$TARGET"

wget -O "$TARGET/root/puppet6-release-$DEBIAN_CODENAME.deb" https://apt.puppetlabs.com/puppet6-release-$DEBIAN_CODENAME.deb
systemd-nspawn -D "$TARGET" dpkg -i /root/puppet6-release-$DEBIAN_CODENAME.deb
systemd-nspawn -D "$TARGET" apt-get update
systemd-nspawn -D "$TARGET" apt-get -y install lsb-release puppet-agent
systemd-nspawn -D "$TARGET" apt-get -y remove puppet6-release


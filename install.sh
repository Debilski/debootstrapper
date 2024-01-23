#!/usr/bin/env bash

set -euo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
}

# shellcheck source=./config
source "${script_dir}/config"

function setup_targets() {
  TARGET=${TARGET:-/target}
  T_BOOT="$TARGET/boot"
  T_EFI="$TARGET/boot/efi"
  T_EXTRA="$TARGET/extra"
}
setup_targets

DEBIAN_CODENAME=bookworm
DEBIAN_BACKPORTS=""
GRUB=grub-efi-amd64 # grub-pc


function echo_red() { echo -e "\e[31m$*\033[0m"; }
function echo_green() { echo -e "\e[32m$*\033[0m"; }
function echo_orange() { echo -e "\e[33m$*\033[0m"; }
function echo_blue() { echo -e "\e[34m$*\033[0m"; }
function echo_purple() { echo -e "\e[35m$*\033[0m"; }
function echo_cyan() { echo -e "\e[36m$*\033[0m"; }

function enter_to_continue() { read -rp "Press Enter to continue … "; }

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  echo_red "$msg"
  exit "$code"
}

parse_params() {
  # default values of variables set from params
  TARGET_DISK=''

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    -t | --target-disk) # example named parameter
      TARGET_DISK="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # check required params and arguments
  #  [[ -z "${param-}" ]] && die "Missing required parameter: param"
  # [[ ${#args[@]} -eq 0 ]] && die "Missing script arguments"

  return 0
}

parse_params "$@"


function check_tools() {
  # check for: debootstrap
  # dosfstools
  # xfsprogs
  # lvm
  # systemd-container
  # partprobe
  # sgdisk
  which debootstrap mkfs.vfat mkfs.xfs lvs systemd-nspawn partprobe sgdisk nc > /dev/null || {
    echo_green "Some tools are missing. Installing …"
    apt-get -y install debootstrap dosfstools xfsprogs lvm2 systemd-container gdisk parted
  }
}

function check_apt_cache() {
  # check that we can reach the apt cache server.
  # otherwise ignore
  IFS=":" read -ra SERVER_PORT <<< "$APT_CACHE"
  if [[ ${#SERVER_PORT[@]} ]] && nc -z "${SERVER_PORT[@]}"; then
    PROXY="${APT_CACHE}/"
    echo "Using proxy server $APT_CACHE."
  else
    PROXY=""
    echo "Cannot reach proxy server $APT_CACHE. Ignoring."
  fi
}

check_tools
check_apt_cache



read -r -s -p "Please set the password for root: " PASSWD

read -r -p "Add ssh key? " SSH_KEY

HOSTNAME=${HOSTNAME:-$(basename $(hostname -A) ${DOMAIN})}

if [[ $HOSTNAME == grml ]] ; then
  echo "Hostname is grml. This doesn’t seem right."
  exit 1
fi

echo "Assuming hostname is:"
echo_green "$HOSTNAME"

VG="$HOSTNAME-vg"
echo "This means, we’ll create a volume group with the name ‘$VG’."
echo "Please exit, if this is wrong."

echo ""

read -p "Should I install a kernel from ${DEBIAN_CODENAME} backports? [y/n]" -n 1 -r
echo    # (optional) move to a new line
if [[ $REPLY =~ ^[Yy]$ ]]
then
    DEBIAN_BACKPORTS=true
fi

if vgs "$VG" ; then
   echo_blue "Volume group $VG already exists. Aborting."
   exit 1
fi

if [[ -z "${TARGET_DISK-}" ]] ; then
  echo_blue "Choose disk to install to:"
  read -r -e DISK
else
  echo_blue "Choosing disk from command line: $TARGET_DISK"
  DISK=$TARGET_DISK
fi

echo "Current partition layout on ${DISK} is:"
sgdisk -p "$DISK"

echo_blue "Deleting all data. Press button or quit with CTRL-C"
enter_to_continue

sgdisk --clear --zap-all --mbrtogpt "$DISK"
sgdisk --new=1:0:+512M   --typecode=1:EF00 --change-name=1:"EFI System Partition" "$DISK"
sgdisk --new=2:0:+1G     --typecode=2:8300 --change-name=2:"Linux /boot" "$DISK"
sgdisk --new=3:0:0       --typecode=3:8E00 --change-name=3:"Linux LVM" "$DISK"

partprobe "$DISK"

LVM_PARTITION=$(findfs PARTUUID="$(partx --output UUID --noheadings --raw --nr 3 "$DISK")")
BOOT_PARTITION=$(findfs PARTUUID="$(partx --output UUID --noheadings --raw --nr 2 "$DISK")")
EFI_PARTITION=$(findfs PARTUUID="$(partx --output UUID --noheadings --raw --nr 1 "$DISK")")

echo_blue "Please confirm the automatic selection of partitions:"
echo_green "${EFI_PARTITION} for EFI"
echo_green "${BOOT_PARTITION} for Boot"
echo_green "${LVM_PARTITION} for LVM."
enter_to_continue


vgcreate "$VG" "${LVM_PARTITION}"
lvcreate "$VG" --size +100G --name root
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

debootstrap --arch amd64 $DEBIAN_CODENAME "$TARGET" "http://${PROXY}ftp.de.debian.org/debian"
chroot "$TARGET" apt purge -y rsyslog
echo "root:${PASSWD}" | chroot "$TARGET" chpasswd

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

SYSTEMD_START_FILE="$TARGET/etc/systemd/system/init-system.service"
cat >"$SYSTEMD_START_FILE" <<EOF
[Unit]
Description=Set up hostname and timezone and shut down

[Service]
Type=oneshot
EnvironmentFile=/root/default-environment
ExecStart=/usr/bin/hostnamectl set-hostname $HOSTNAME
ExecStart=/usr/bin/timedatectl set-timezone $TIMEZONE
ExecStart=/usr/bin/systemctl poweroff

[Install]
WantedBy=multi-user.target
EOF

SYSTEMD_NETWORKD_FILE="$TARGET/etc/systemd/network/ethernet.network"
cat >"$SYSTEMD_NETWORKD_FILE" <<EOF
[Match]
Name=e*
Type=!vlan

[Network]
VLAN=huvlan
EOF

cat >"$TARGET/etc/systemd/network/huvlan.netdev" <<EOF
[NetDev]
Name=huvlan
Kind=vlan

[VLAN]
Id=71
EOF

cat >"$TARGET/etc/systemd/network/huvlan.network" <<EOF
[Match]
Name=huvlan

[Network]
DHCP=yes

[DHCPv4]
UseDomains = true
EOF

systemctl restart dbus

systemd-nspawn -D "$TARGET" apt-get install -y dbus openssh-server aptitude bash-completion apt-transport-https
systemd-nspawn -D "$TARGET" bash -c 'apt-get install -y $(tasksel --task-packages standard)'
#systemd-nspawn -D "$TARGET" aptitude install -y '~pstandard' '~prequired' '~pimportant' # tasksel standard
systemd-nspawn -D "$TARGET" systemctl enable init-system.service
systemd-nspawn -D "$TARGET" -b
systemd-nspawn -D "$TARGET" systemctl disable init-system.service

rm "$SYSTEMD_START_FILE"

if [ -n "$SSH_KEY" ] ; then
  mkdir -p "$TARGET"/root/.ssh
  chmod 0700 "$TARGET"/root/.ssh
  echo "$SSH_KEY" >> "$TARGET"/root/.ssh/authorized_keys
  chmod 0600 "$TARGET"/root/.ssh/authorized_keys
fi


sed -i -e s/main/"main contrib non-free"/g "$TARGET/etc/apt/sources.list"
if "$DEBIAN_BACKPORTS" ; then
  echo "deb http://${PROXY}ftp.de.debian.org/debian ${DEBIAN_CODENAME}-backports main contrib firmware-non-free non-free" >> "$TARGET/etc/apt/sources.list"
fi
bash mkfstab.sh "$DISK" "$VG" > "$TARGET/etc/fstab"

function chroot_mounts() {
  setup_targets

  CHROOT_MOUNTS="dev dev/pts proc sys sys/firmware"
  for m in $CHROOT_MOUNTS ; do
    mount --bind "/$m" "$TARGET/$m"
  done
}
chroot_mounts

chroot "$TARGET" update-locale
chroot "$TARGET" apt-get update
chroot "$TARGET" apt-get install -y lvm2 xfsprogs $GRUB
if "$DEBIAN_BACKPORTS" ; then
  chroot "$TARGET" apt-get install -y -t ${DEBIAN_CODENAME}-backports linux-image-amd64 firmware-linux firmware-linux-nonfree firmware-realtek
else
  chroot "$TARGET" apt-get install -y linux-image-amd64 firmware-linux firmware-linux-nonfree firmware-realtek
fi

chroot "$TARGET" grub-install --force-extra-removable --recheck "$DISK"
# We may need a bind mount for /run to work around a bug in update-grub
mount --bind /run "$TARGET/run"
chroot "$TARGET" update-grub

echo_green "Now umounting the dev mounts again. But sleeping a bit before that."
sync
sleep 3

umount -A --recursive "$TARGET"
mount "/dev/$VG/root" "$TARGET"

echo_green "Setting timezone."
systemd-nspawn -D "$TARGET" apt-get -y install tzdata
systemd-nspawn -D "$TARGET" dpkg-reconfigure --frontend noninteractive tzdata

echo_green "Installing Puppet."
wget -O "$TARGET/root/puppet-release-$DEBIAN_CODENAME.deb" https://apt.puppetlabs.com/puppet-release-$DEBIAN_CODENAME.deb
systemd-nspawn -D "$TARGET" dpkg -i /root/puppet-release-$DEBIAN_CODENAME.deb
systemd-nspawn -D "$TARGET" apt-get update
systemd-nspawn -D "$TARGET" apt-get -y install lsb-release puppet-agent
systemd-nspawn -D "$TARGET" systemctl enable puppet
systemd-nspawn -D "$TARGET" apt-get -y remove puppet-release

systemd-nspawn -D "$TARGET" apt-get install -y systemd-resolved
systemd-nspawn -D "$TARGET" systemctl enable systemd-networkd systemd-resolved


echo_green "Activating production environment in Puppet."
cat >>"$TARGET/etc/puppetlabs/puppet/puppet.conf" <<EOF
[main]
environment=production
EOF

echo_green "Adding puppet to /etc/hosts"
echo "172.18.65.13   puppet puppet.itb.biologie.hu-berlin.de" >> "$TARGET/etc/hosts"

echo_green "˜˜˜ Installation finished. You can now reboot. ˜˜˜"


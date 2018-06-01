#!/bin/bash
set -euo pipefail


# https://unix.stackexchange.com/a/227318
# https://github.com/marcan/takeover.sh

source config

TAKEOVER=${TAKEOVER:-/takeover}
OLDROOT="$TAKEOVER/oldroot"

function echo_blue() { echo -e "\e[34m$*\033[0m"; }
function echo_green() { echo -e "\e[32m$*\033[0m"; }

function enter_to_continue() { read -p "Press Enter to continue … "; }

if ! [ -x "$(command -v git)" ]; then
  apt install debootstrap
fi

echo_blue "Going into maintenance mode."

cat > /etc/systemd/system/maintenance-net.target <<EOL
[Unit]
Description=Maintenance Mode with Networking and SSH
#Requires=maintenance.target network.target sshd.service
#After=maintenance.target network.target sshd.service
Requires=maintenance-net.target systemd-networkd.service sshd.service
After=maintenance-net.target systemd-networkd.service sshd.service
AllowIsolate=yes

EOL

systemctl daemon-reload
systemctl isolate maintenance-net.target

echo_blue "Unmounting all uneeded file systems"
# unmount unneeded
umount -a || true # errors here are okay
swapoff -a

echo_blue "Creating temporary debian"
mkdir -p "$TAKEOVER"
mount -t tmpfs tmpfs "$TAKEOVER"

debootstrap --arch amd64 stretch "$TAKEOVER" "http://${APT_CACHE}ftp.de.debian.org/debian"

chroot "$TAKEOVER" apt update
chroot "$TAKEOVER" apt install -y build-essential git lvm2 openssh-server psmisc tmux

echo_blue "Takeover ssh keys and config."
# cp sshd_config /takeover/etc/ssh/sshd_config
rm -rf "$TAKEOVER/etc/ssh"
cp -rx /etc/ssh "$TAKEOVER/etc/ssh"

echo_blue "You can now paste an authorized ssh key"
echo -n "> "
read a
if ! [ -z "$a" ] ; then
    chroot "$TAKEOVER" mkdir /root/.ssh
    chroot "$TAKEOVER" touch /root/.ssh/authorized_keys
    chroot "$TAKEOVER" chmod 0600 /root/.ssh/authorized_keys
    echo "$a" >> "$TAKEOVER/root/.ssh/authorized_keys"
else
    echo_blue "No key pasted. Allowing root login."
    sed -i '/PermitRootLogin/d' "$TAKEOVER/etc/ssh/sshd_config"
    echo -e "\nPermitRootLogin yes\n" >> "$TAKEOVER/etc/ssh/sshd_config"
    chroot "$TAKEOVER" passwd
fi

cat >> "$TAKEOVER/root/.bashrc" <<EOL

echo "The following processes are still active on /oldroot:"
echo "$ fuser -vm /oldroot"
fuser -vm /oldroot

echo "You can terminate all of them with:"
echo "fuser -ki -TERM -m /oldroot"

echo "To reclaim PID1 run:"
echo "systemctl daemon-reexec"
EOL


echo_blue "Pivoting root"
enter_to_continue

mount --make-rprivate / # necessary for pivot_root to work
mkdir "$OLDROOT"
pivot_root "$TAKEOVER" "$OLDROOT"
for i in dev proc sys run; do mount --move /oldroot/$i /$i; done

echo_blue "Restarting ssh. Please log in with new shell."
systemctl restart sshd
systemctl status sshd

enter_to_continue

echo_blue "When finished, you can reboot with: echo b > /proc/sysrq-trigger"

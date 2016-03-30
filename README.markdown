# Debian installation using only debootstrap

## Prerequisites

### A minimal Debian installation on a USB stick in EFI mode.

Using [grml](https://grml.org/) would be easier to prepare but only works from legacy (BIOS) boot and does not come with [systemd-nspawn](https://www.freedesktop.org/software/systemd/man/systemd-nspawn.html).

A future task would be to add statelessness to the USB stick and enable boot to RAM.

### Disable udev rules for the USB stick.

Debian will create a file `/etc/udev/rules.d/70-persistent-net.rules` with whatever the current ethernet addresses are, containing something like

    SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="ab:cd:ef:01:03:05", ATTR{dev_id}=="0x0", ATTR{type}=="1", KERNEL=="eth*", NAME="eth0

this tells the system to reserve the name `eth0` for an ethernet adapter with address `ab:cd:ef:01:03:05`. Obviously, we want to use the USB stick on other machines as well and we don’t want those other machines to start numbering the ethernet adapters from `eth1` on. Let us therefore ensure that Debian won’t ever create the file again:

    root@usb-boot:~ $ rm /etc/udev/rules.d/70-persistent-net.rules
    root@usb-boot:~ $ touch /etc/udev/rules.d/70-persistent-net.rules

## Prepare hard drive

Now reboot the target machine from our USB stick.

Our partitioning scheme shall be as follows:

    1. 512 MiB /boot/efi – EFI  – EFI Boot Partition
    2. 256 MiB /boot     – ext2 – Boot
    3. rest    vg-main   – LVM
    
    vg-main:
       70 GiB /          – xfs  – Root fs
       12 GiB swap       – swap – Swap
       rest   /extra     – xfs  – User writable area

We can automate the partitioning with sgdisk and the LVM tools.

    PARTITION=/dev/sda ## Change as needed!
    
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

## Mount the target

    mkdir -p /target
    mount /dev/vg-main/root /target
    mkdir -p /target/boot
    mount ${PARTITION}2 /target/boot
    mkdir -p /target/boot/efi
    mount ${PARTITION}1 /target/boot/efi
    mkdir -p /target/extra
    
    debootstrap --arch amd64 jessie /target http://apt-cacher-ng.local.pri:3142/ftp.de.debian.org/debian
    # alternatively
    # debootstrap --arch amd64 jessie /target http:/ftp.de.debian.org/debian
    
    sed -i -e s/main/"main contrib non-free"/g /target/etc/apt/sources.list
    mount -o bind /dev /target/dev
    mount -o bind /dev/shm /target/dev/shm
    mount -o bind /proc /target/proc
    mount -o bind /sys /target/sys
    mount -t devpts devpts /target/dev/pts
    
    chroot /target /usr/bin/apt-get update
    chroot /target /usr/bin/apt-get install -y lvm2 xfsprogs linux-image-amd64 grub-efi-amd64 firmware-linux
    
    # Create fstab
    
    cat >> /target/etc/fstab <<EOF
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
    
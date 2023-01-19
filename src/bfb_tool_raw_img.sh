#!/bin/bash

#
# Copyright (c) 2021-2022 NVIDIA CORPORATION & AFFILIATES, ALL RIGHTS RESERVED.
#
# This software product is a proprietary product of NVIDIA CORPORATION &
# AFFILIATES (the "Company") and all right, title, and interest in and to the
# software product, including all associated intellectual property rights, are
# and shall remain exclusively with the Company.
#
# This software product is governed by the End User License Agreement
# provided with the software product.
#

CHROOT_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
bfb=`realpath $1`
verbose=$2
#A bash-specific way to do case-insensitive matching
shopt -s nocasematch

function log()
{
    if [[ $* == *"ERROR"* ]]; then
        echo "$*"
        exit 1
    fi
    if [ "$verbose" = true ] ; then
        echo "$*"
    fi
}

bfb_img=${bfb%.*}.img
tmp_dir="img_from_bfb_tmp_"$(date +"%T")
git_repo="https://github.com/Mellanox/bfscripts.git"
mkbfb_path=`realpath mlx-mkbfb.py`
mlnx_bf_configure_path=`realpath mlnx_bf_configure`

#create tmp directory
if [ ! -d "$tmp_dir" ]; then
    mkdir $tmp_dir
fi

#check if mlx-mkbfb.py exist
if [ ! -e "$mkbfb_path" ]; then
    log "ERROR: can't find mlx-mkbfb.py script"
    exit 1
fi

#execute mkbfb_path
(cd $tmp_dir;$mkbfb_path -x $bfb)

initramfs_v0=`realpath $tmp_dir/dump-initramfs-v0`

(cd $tmp_dir;zcat $initramfs_v0|cpio -i)> /dev/null 2>&1
img_tar_path=`realpath $tmp_dir/ubuntu/image.tar.xz`
if [ $? -ne 0 ]; then
    log "ERROR: $tmp_dir/ubuntu/image.tar.xz can't be found"
fi

log "INFO: starting creating clean img"
dd if=/dev/zero of=$bfb_img iflag=fullblock bs=1M count=10000 > /dev/null 2>&1
bfb_img=`realpath $bfb_img`
log "INFO: starting creating partitions"
bs=512
reserved=34
start_reserved=2048
boot_size_megs=50
mega=$((2**20))
boot_size_bytes=$(($boot_size_megs * $mega))
giga=$((2**30))
MIN_DISK_SIZE4DUAL_BOOT=$((16*$giga)) #16GB
common_size_bytes=$((10*$giga))

disk_sectors=`fdisk -l $bfb_img 2> /dev/null | grep "Disk $bfb_img:" | awk '{print $7}'`
disk_size=`fdisk -l $bfb+img 2> /dev/null | grep "Disk $bfb_img:" | awk '{print $5}'`
disk_end=$((disk_sectors - reserved))

boot_start=$start_reserved
boot_size=$(($boot_size_bytes/$bs))
root_start=$(($boot_start + $boot_size))
root_end=$disk_end
root_size=$(($root_end - $root_start + 1))
(
sfdisk -f "$bfb_img" << EOF
label: gpt
label-id: A2DF9E70-6329-4679-9C1F-1DAF38AE25AE
device: ${bfb_img}
unit: sectors
first-lba: $reserved
last-lba: $disk_end
${bfb_img}p1 : start=$boot_start, size=$boot_size, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI System", bootable
${bfb_img}p2 : start=$root_start ,size=$root_size, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="writable"
EOF
) >/dev/null 2>&1

#create device maps over partitions segments
kpartx_out=`kpartx -asv $bfb_img`

#format partitions
BOOT_PARTITION="/dev/mapper/"`echo $kpartx_out | cut -d " " -f 3`
ROOT_PARTITION="/dev/mapper/"`echo $kpartx_out | cut -d " " -f 12`

if [[ "$BOOT_PARTITION" != *"loop"*  ||  "$ROOT_PARTITION" != *"loop"* ]]; then
    kpartx -d $bfb_img
    log "ERROR: there was an error while creating device maps over partitions segments"
fi

log "INFO: BOOT partition is $BOOT_PARTITION"
log "INFO: ROOT partition is $ROOT_PARTITION"

log "INFO: formating partitions"
mkfs.fat $BOOT_PARTITION -n "system-boot"> /dev/null 2>&1
mkfs.ext4 -F $ROOT_PARTITION -L "writable"> /dev/null 2>&1
sync

#create directory before mounting
mkdir -p mnt
mount -t ext4 $ROOT_PARTITION mnt
mkdir -p mnt/boot/efi
mount -t vfat $BOOT_PARTITION mnt/boot/efi

#copy image.tar to root partition
log "INFO: copying extracted image.tar.xz to root partition"
tar Jxf $img_tar_path --warning=no-timestamp -C mnt
if [ $? -ne 0 ]; then
    log "ERROR: Couldn't extract $img_tar_path"
fi


#modify etc/default/grub to support VM
if  grep -q "GRUB_CMDLINE_LINUX=" mnt/etc/default/grub; then
    log "INFO: modify GRUB_CMDLINE_LINUX at etc/default/grub to support vm"
    GRUB_CMDLINE_LINUX=`grep  "GRUB_CMDLINE_LINUX=" mnt/etc/default/grub`
    GRUB_CMDLINE_LINUX_MODIFIED=`echo $GRUB_CMDLINE_LINUX| sed s/"console=hvc0"//|sed s/"earlycon=pl011,0x01000000"//|sed s/"quiet"/"net.ifnames=0 biosdevname=0"/`
    sed -i '/GRUB_CMDLINE_LINUX=/d' mnt/etc/default/grub
    echo $GRUB_CMDLINE_LINUX_MODIFIED >> mnt/etc/default/grub
fi 

#copy qemu-aarch64-static to mounted image
if [ "`uname -m`" != "aarch64" ]; then
    log "INFO: copying /usr/bin/qemu-aarch64-static to mnt/usr/bin/"
    cp /usr/bin/qemu-aarch64-static mnt/usr/bin/
fi

#create boot/grub/grub.cfg
log "INFO: creating grub.cfg"

mount --bind /proc mnt/proc
mount --bind /dev mnt/dev
mount --bind /sys mnt/sys
if chroot mnt env PATH=$CHROOT_PATH /usr/sbin/grub-mkconfig -o /boot/grub/grub.cfg ; then
    log "INFO: grub.cfg was successfully created"
else
    log "ERROR: grub.cfg was was not created,please check script prerequisites"
fi

log "INFO: remove unnecessary bfb services"
chroot mnt systemctl disable bfvcheck.service
rm -f mnt/etc/systemd/system/networking.service.d/override.conf
rm -f mnt/etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf
rm -f mnt/etc/systemd/system/NetworkManager-wait-online.service.d/override.conf

#create EFI/ubuntu/grub.cfg
root='$root'
prefix='$prefix'
root_uuid=`blkid -p $ROOT_PARTITION | grep -oP ' UUID=[0-9a-zA-Z"-]+' |cut -d '"' -f2`
boot_uuid=`blkid -p $BOOT_PARTITION | grep -oP ' UUID=[0-9a-zA-Z"-]+' |cut -d '"' -f2`
cat >mnt/boot/efi/EFI/ubuntu/grub.cfg << EOF
search.fs_uuid $root_uuid root
set prefix=($root)'/boot/grub'
configfile $prefix/grub.cfg
EOF

#edit etc/fstab
cat > mnt/etc/fstab << EOF
UUID="$root_uuid" / auto defaults 0 0
UUID="$boot_uuid" /boot/efi vfat umask=0077 0 1
EOF


#set default password
log "INFO: set deafult password"
if [ -n "${ubuntu_PASSWORD}" ]; then
    log "INFO: Changing the default password for user ubuntu"
    perl -ni -e "if(/^users:/../^runcmd/) {
        next unless m{^runcmd};
        print q@users:
        - name: ubuntu
        lock_passwd: False
        groups: [adm, audio, cdrom, dialout, dip, floppy, lxd, netdev, plugdev, sudo, video]
        sudo: ALL=(ALL) NOPASSWD:ALL
        shell: /bin/bash
        passwd: $ubuntu_PASSWORD
        @;
        print }  else {print}" mnt/var/lib/cloud/seed/nocloud-net/user-data
else
    perl -ni -e "print unless /plain_text_passwd/" mnt/var/lib/cloud/seed/nocloud-net/user-data
fi

#modify mlnx_bf_configure script
log "INFO: modify mlnx_bf_configure script to support SimX"
if [ ! -e "$mlnx_bf_configure_path" ]; then
    log "ERROR: can't find mlnx_bf_configure script"
    exit 1
fi

mv mnt/sbin/mlnx_bf_configure mnt/sbin/mlnx_bf_configure.orig
if [ $? -ne 0 ]; then
    log "ERROR: Couldn't modify mlnx_bf_configure original name"
fi

log "INFO: move $mlnx_bf_configure_path to mnt/sbin/mlnx_bf_configure"
mv $mlnx_bf_configure_path mnt/sbin/mlnx_bf_configure
if [ $? -ne 0 ]; then
    log "ERROR: Couldn't copy $mlnx_bf_configure_path to mnt/sbin/mlnx_bf_configure"
fi
chmod 777 mnt/sbin/mlnx_bf_configure

#configure network settings
log "INFO: modify network settings"
echo -e "  eth0:\n    dhcp4: true   " >> mnt/var/lib/cloud/seed/nocloud-net/network-config
sed -i '/PasswordAuthentication no/c\PasswordAuthentication yes' mnt/etc/ssh/sshd_config

#unmounting
log "INFO: unmounting directories"
umount mnt/proc
umount mnt/dev
umount mnt/sys
umount mnt/boot/efi
umount mnt

#save chango "INFO: saving to image device maps over paritions
log "INFO: saving img file with changes"
kpartx -d $bfb_img> /dev/null 2>&1

log "INFO: removing temp directories"
rm mnt -rf
rm $tmp_dir -rf

#move img file to shared container volume

log "INFO: moving $bfb_img to shared container volume"
mv $bfb_img /workspace
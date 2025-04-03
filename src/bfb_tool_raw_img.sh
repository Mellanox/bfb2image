#!/bin/bash

###############################################################################
#
# Copyright 2023 NVIDIA Corporation
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the "Software"), to deal in
# the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
# the Software, and to permit persons to whom the Software is furnished to do so,
# subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
# FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
# COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
# IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
# CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
###############################################################################

CHROOT_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
bfb=$(realpath $1)
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
mkbfb_path=$(realpath mlx-mkbfb.py)

# Set the default password for ubuntu user to 'nvidia'
ubuntu_PASSWORD=${ubuntu_PASSWORD:-'$1$TIMsY7oM$JI0G7/LJ9hKRkhSwByxF71'}

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

initramfs_v0=$(realpath $tmp_dir/dump-initramfs-v0)

(cd $tmp_dir;zcat $initramfs_v0|cpio -i)> /dev/null 2>&1
img_tar_path=$(realpath $tmp_dir/ubuntu/image.tar.xz)
if [ $? -ne 0 ]; then
    log "ERROR: $tmp_dir/ubuntu/image.tar.xz can't be found"
fi

log "INFO: starting creating clean img"
dd if=/dev/zero of=$bfb_img iflag=fullblock bs=1M count=10000 > /dev/null 2>&1
bfb_img=$(realpath $bfb_img)
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

disk_sectors=$(fdisk -l $bfb_img 2> /dev/null | grep "Disk $bfb_img:" | awk '{print $7}')
disk_size=$(fdisk -l $bfb_img 2> /dev/null | grep "Disk $bfb_img:" | awk '{print $5}')
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
kpartx_out=$(kpartx -asv $bfb_img)

#format partitions
BOOT_PARTITION="/dev/mapper/"$(echo $kpartx_out | cut -d " " -f 3)
ROOT_PARTITION="/dev/mapper/"$(echo $kpartx_out | cut -d " " -f 12)

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

mv config-sf mnt/sbin
mv mlnx-sf.conf mnt/etc/modprobe.d

#copy qemu-aarch64-static to mounted image
if [ "$(uname -m)" != "aarch64" ]; then
    log "INFO: copying /usr/bin/qemu-aarch64-static to mnt/usr/bin/"
    cp /usr/bin/qemu-aarch64-static mnt/usr/bin/
fi

#update sshd configuration
perl -ni -e 'print unless /PasswordAuthentication no/' mnt/etc/ssh/sshd_config
echo "PasswordAuthentication yes" >> mnt/etc/ssh/sshd_config
echo "PermitRootLogin yes" >> mnt/etc/ssh/sshd_config

#create boot/grub/grub.cfg
log "INFO: creating grub.cfg"

mount --bind /proc mnt/proc
mount --bind /dev mnt/dev
mount --bind /sys mnt/sys
sed -i -r -e 's/earlycon=[^ ]* //g' mnt/etc/default/grub
mkconfig_outout=$(chroot mnt env PATH=$CHROOT_PATH /usr/sbin/grub-mkconfig -o /boot/grub/grub.cfg 2>&1)

if echo $mkconfig_outout | grep "Command failed" ; then
    log "ERROR: grub.cfg was was not created,please check script prerequisites"
else
    log "INFO: grub.cfg was successfully created"
fi

###
### log "INFO: remove unnecessary bfb services"
### chroot mnt systemctl disable bfvcheck.service
### rm -f mnt/etc/systemd/system/networking.service.d/override.conf
### rm -f mnt/etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf
### rm -f mnt/etc/systemd/system/NetworkManager-wait-online.service.d/override.conf
###
#create EFI/ubuntu/grub.cfg
root='$root'
prefix='$prefix'
root_uuid=$(blkid -p $ROOT_PARTITION | grep -oP ' UUID=[0-9a-zA-Z"-]+' |cut -d '"' -f2)
boot_uuid=$(blkid -p $BOOT_PARTITION | grep -oP ' UUID=[0-9a-zA-Z"-]+' |cut -d '"' -f2)
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
if [ -n "${ubuntu_PASSWORD}" ]; then
		log "INFO: Changing the default password for user ubuntu"
		perl -ni -e "if(/^users:/../^runcmd/) {
						next unless m{^runcmd};
		print q@users:
  - name: ubuntu
    lock_passwd: False
    groups: adm, audio, cdrom, dialout, dip, floppy, lxd, netdev, plugdev, sudo, video
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    passwd: $ubuntu_PASSWORD
@;
		print } else {print}" mnt/var/lib/cloud/seed/nocloud-net/user-data
else
		perl -ni -e "print unless /plain_text_passwd/" mnt/var/lib/cloud/seed/nocloud-net/user-data
fi

# Increase openibd timeout to support multiple devices
sed -r -i -e "s/(TimeoutSec=).*/\118000/" mnt/lib/systemd/system/openibd.service

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
log "INFO: The default password for user ubuntu is 'nvidia'"
mv $bfb_img /workspace

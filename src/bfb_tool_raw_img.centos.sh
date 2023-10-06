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

PATH="/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/opt/mellanox/scripts"

bfb=`realpath $1`
verbose=$2
#A bash-specific way to do case-insensitive matching
shopt -s nocasematch

fspath=$(readlink -f `dirname $0`)

function log()
{
    msg="[$(date +%H:%M:%S)] $*"
    echo "$msg"
    if [[ $* == *"ERROR"* ]]; then
        exit 1
    fi
}

bind_partitions()
{
	mount --bind /proc /mnt/proc
	mount --bind /dev /mnt/dev
	mount --bind /sys /mnt/sys
}

unmount_partitions()
{
	umount /mnt/sys/fs/fuse/connections > /dev/null 2>&1 || true
	umount /mnt/sys > /dev/null 2>&1
	umount /mnt/dev > /dev/null 2>&1
	umount /mnt/proc > /dev/null 2>&1
	umount /mnt/boot/efi > /dev/null 2>&1
	umount /mnt > /dev/null 2>&1
}

distro="CentOS"

function_exists()
{
	declare -f -F "$1" > /dev/null
	return $?
}

DHCP_CLASS_ID=${PXE_DHCP_CLASS_ID:-""}
DHCP_CLASS_ID_OOB=${DHCP_CLASS_ID_OOB:-"NVIDIA/BF/OOB"}
DHCP_CLASS_ID_DP=${DHCP_CLASS_ID_DP:-"NVIDIA/BF/DP"}
FACTORY_DEFAULT_DHCP_BEHAVIOR=${FACTORY_DEFAULT_DHCP_BEHAVIOR:-"true"}

if [ "${FACTORY_DEFAULT_DHCP_BEHAVIOR}" == "true" ]; then
	# Set factory defaults
	DHCP_CLASS_ID="NVIDIA/BF/PXE"
	DHCP_CLASS_ID_OOB="NVIDIA/BF/OOB"
	DHCP_CLASS_ID_DP="NVIDIA/BF/DP"
fi

bfb_img=${bfb%.*}.img
tmp_dir="img_from_bfb_tmp_"$(date +"%T")
git_repo="https://github.com/Mellanox/bfscripts.git"
mkbfb_path=`realpath mlx-mkbfb.py`

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
img_tar_path=`realpath $tmp_dir/*/image.tar.xz`
if [ $? -ne 0 ]; then
    log "ERROR: OS filesystem tarball image.tar.xz can't be found under $tmp_dir"
fi

log "INFO: starting creating clean img"
dd if=/dev/zero of=$bfb_img iflag=fullblock bs=1M count=10000 > /dev/null 2>&1
bfb_img=`realpath $bfb_img`
log "INFO: $distro installation started"

# Create the CentOS partitions.
parted --script $bfb_img -- \
	mklabel gpt \
	mkpart primary 1MiB 201MiB set 1 esp on \
	mkpart primary 201MiB 100%

sync

#create device maps over partitions segments
kpartx_out=`kpartx -asv $bfb_img`

#format partitions
BOOT_PARTITION="/dev/mapper/$(kpartx -asv $bfb_img | grep -o loop.p1)"
ROOT_PARTITION="/dev/mapper/$(kpartx -asv $bfb_img | grep -o loop.p2)"

if [[ "$BOOT_PARTITION" != *"loop"*  ||  "$ROOT_PARTITION" != *"loop"* ]]; then
    kpartx -d $bfb_img
    log "ERROR: there was an error while creating device maps over partitions segments"
fi

log "INFO: BOOT partition is $BOOT_PARTITION"
log "INFO: ROOT partition is $ROOT_PARTITION"

partprobe "$bfb_img"

sleep 1

if function_exists bfb_pre_install; then
	log "INFO: Running bfb_pre_install from bf.cfg"
	bfb_pre_install
fi

mkdosfs $BOOT_PARTITION -n system-boot
mkfs.xfs -f $ROOT_PARTITION -L writable

export EXTRACT_UNSAFE_SYMLINKS=1

fsck.vfat -a $BOOT_PARTITION

root=${ROOT_PARTITION}
mount ${ROOT_PARTITION} /mnt
mkdir -p /mnt/boot/efi
mount ${BOOT_PARTITION} /mnt/boot/efi

echo "Extracting /..."
tar Jxf $img_tar_path --warning=no-timestamp -C /mnt
sync

mv config-sf /mnt/sbin
mv mlnx-sf.conf /mnt/etc/modprobe.d

#copy qemu-aarch64-static to mounted image
if [ "`uname -m`" != "aarch64" ]; then
    log "INFO: copying /usr/bin/qemu-aarch64-static to mnt/usr/bin/"
    cp /usr/bin/qemu-aarch64-static /mnt/usr/bin/
fi

root_uuid=$(blkid -s UUID -o value $ROOT_PARTITION 2> /dev/null)
boot_uuid=$(blkid -s UUID -o value $BOOT_PARTITION 2> /dev/null)

cat > /mnt/etc/fstab << EOF
#
# /etc/fstab
#
#
UUID="$root_uuid"  /           xfs     defaults                   0 1
UUID="$boot_uuid"  /boot/efi	 vfat    umask=0077,shortname=winnt 0 2
EOF

memtotal=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
if [ $memtotal -gt 16000000 ]; then
	sed -i -r -e "s/(net.netfilter.nf_conntrack_max).*/\1 = 1000000/" /mnt/usr/lib/sysctl.d/90-bluefield.conf
fi

# cat > /mnt/etc/udev/rules.d/50-dev-root.rules << EOF
# # If the system was booted without an initramfs, grubby
# # will look for the symbolic link "/dev/root" to figure
# # out the root file system block device.
# SUBSYSTEM=="block", KERNEL=="$root", SYMLINK+="root"
# EOF

# Disable SELINUX
sed -i -e "s/^SELINUX=.*/SELINUX=disabled/" /mnt/etc/selinux/config

chmod 600 /mnt/etc/ssh/*

# Disable Firewall services
/bin/rm -f /mnt/etc/systemd/system/multi-user.target.wants/firewalld.service
/bin/rm -f /mnt/etc/systemd/system/dbus-org.fedoraproject.FirewallD1.service

bind_partitions

/bin/rm -f /mnt/boot/vmlinux-*.bz2

sed -i -e "s@GRUB_CMDLINE_LINUX=.*@GRUB_CMDLINE_LINUX=\"crashkernel=auto root=UUID=$root_uuid modprobe.blacklist=mlx5_core,mlx5_ib net.ifnames=0 biosdevname=0 iommu.passthrough=1\"@" /mnt/etc/default/grub

chroot /mnt /usr/sbin/grub2-mkconfig -o /boot/efi/EFI/centos/grub.cfg

# virtio_scsi
cat > /mnt/etc/dracut.conf.d/vm.conf << EOF
add_drivers+=" libiscsi virtio_blk loop null_blk virtio_console "
EOF

kdir=$(/bin/ls -1d /mnt/lib/modules/4.18* /mnt/lib/modules/4.19* /mnt/lib/modules/4.20* /mnt/lib/modules/5.* 2> /dev/null)
kver=""
if [ -n "$kdir" ]; then
    kver=${kdir##*/}
    DRACUT_CMD=`chroot /mnt /bin/ls -1 /sbin/dracut /usr/bin/dracut 2> /dev/null | head -n 1 | tr -d '\n'`
    chroot /mnt /usr/sbin/grub2-set-default 0
    chroot /mnt $DRACUT_CMD --kver ${kver} --force /boot/initramfs-${kver}.img
else
    kver=$(/bin/ls -1 /mnt/lib/modules/ | head -1)
fi

# Network configuration
cat > /mnt/etc/sysconfig/network-scripts/ifcfg-br0 << EOF
NAME="br0"
DEVICE=br0
TYPE=Bridge
DELAY=0
ONBOOT=yes
NETBOOT=yes
IPV6INIT=yes
BOOTPROTO=dhcp
EOF

cat > /mnt/etc/sysconfig/network-scripts/ifcfg-eth0 << EOF
NAME=eth0
DEVICE=eth0
ONBOOT=yes
NETBOOT=yes
TYPE=Ethernet
BRIDGE=br0
EOF


echo centos | chroot /mnt passwd root --stdin

mkdir -p /mnt/etc/dhcp
cat >> /mnt/etc/dhcp/dhclient.conf << EOF
send vendor-class-identifier "$DHCP_CLASS_ID_DP";
interface "oob_net0" {
  send vendor-class-identifier "$DHCP_CLASS_ID_OOB";
}
EOF

chroot /mnt systemctl disable bfvcheck.service

# Clean up logs
echo > /mnt/var/log/messages
echo > /mnt/var/log/maillog
echo > /mnt/var/log/secure
echo > /mnt/var/log/firewalld
echo > /mnt/var/log/audit/audit.log
/bin/rm -f /mnt/var/log/yum.log
/bin/rm -rf /mnt/tmp/*

if function_exists bfb_modify_os; then
	log "INFO: Running bfb_modify_os from bf.cfg"
	bfb_modify_os
fi

sync

umount /mnt/boot/efi
umount /mnt/sys
umount /mnt/dev
umount /mnt/proc
umount /mnt

sync

log "INFO: saving img file with changes"
kpartx -d $bfb_img> /dev/null 2>&1

echo
echo "ROOT PASSWORD is \"centos\""
echo

if function_exists bfb_post_install; then
	log "INFO: Running bfb_post_install from bf.cfg"
	bfb_post_install
fi

log "INFO: removing temp directories"
/bin/rm -rf mnt
/bin/rm -rf $tmp_dir

#move img file to shared container volume

log "INFO: moving $bfb_img to shared container volume"
mv $bfb_img /workspace

#!/bin/bash -x

###############################################################################
#
# Copyright 2026 NVIDIA Corporation
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

# This script creates files vmlinuz and initrd based on the provided image <img> and a BFB that can be used for PXE installation
# vmlinuz is taken from the BFB
# initrd is taken from the BFB but the OS image inside is replaced with the filesystem from the original image <img>

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <img> <original bfb>"
  exit 1
fi

# Exit if not root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi

IMG=$(readlink -f "$1")
BFB=$(readlink -f "$2")

if [[ -z "${IMG}" || -z "${BFB}" ]]; then
  echo "Usage: $0 <img> <original bfb>"
  exit 1
fi

BFB_NAME=$(basename "${BFB}" | sed -e 's/.bfb//')

TDIR=${TDIR:-"$(mktemp -d /tmp/img2iso.XXXXXXXXXX)"}
# Mount points
# ${targetdir} - Updated rootfs from the existing IMG file
targetdir="${TDIR}/rootfs"
# ${bfbdir} - directory for the BFB files
bfbdir="${TDIR}/bfb"
# ${outputdir} - directory for the output files
outputdir=${outputdir:-"${TDIR}/${BFB_NAME}"}

kpartx_out=$(kpartx -asv "${IMG}" ||:)
IMG1_PARTITION="/dev/mapper/"$(echo $kpartx_out | cut -d " " -f 3)
IMG2_PARTITION="/dev/mapper/"$(echo $kpartx_out | cut -d " " -f 12)

/bin/rm -rf "${targetdir}"
mkdir -p "${targetdir}"

mount ${IMG2_PARTITION} "${targetdir}"
mount ${IMG1_PARTITION} "${targetdir}"/boot/efi/

# Extract the kernel and initramfs from the BFB
mkdir -p "${bfbdir}"
mkdir -p "${outputdir}"
cd "${bfbdir}"
mlx-mkbfb -x -n image-v0 "${BFB}"
mlx-mkbfb -x -n initramfs-v0 "${BFB}"
cp dump-image-v0 ${outputdir}/vmlinuz.lzma
xz --format=lzma -d "${outputdir}/vmlinuz.lzma"
gzip "${outputdir}/vmlinuz"
mv "${outputdir}/vmlinuz.gz" "${outputdir}/vmlinuz"

# Add missing files to the initramfs
if [[ ! -f "${targetdir}/etc/udev/rules.d/92-oob_net.rules" ]]; then
  cat > "${targetdir}/etc/udev/rules.d/92-oob_net.rules" << 'EOF'
SUBSYSTEM=="net", ACTION=="add", DEVPATH=="/devices/platform/MLNXBF17:00/net/e*", NAME="oob_net0", RUN+="/sbin/sysctl -w net.ipv4.conf.oob_net0.arp_notify=1"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="virtio_net", PROGRAM="/bin/sh -c 'lspci -vv | grep -wq SimX'", NAME="oob_net0", RUN+="/sbin/sysctl -w net.ipv4.conf.oob_net0.arp_notify=1"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="lan743x", NAME="oob_net0", RUN+="/sbin/sysctl -w net.ipv4.conf.oob_net0.arp_notify=1"
EOF
fi

if [[ ! -f "${bfbdir}/initramfs/etc/udev/rules.d/92-oob_net.rules" ]]; then
  mkdir -p "${bfbdir}/initramfs/etc/udev/rules.d"
  cp "${targetdir}/etc/udev/rules.d/92-oob_net.rules" "${bfbdir}/initramfs/etc/udev/rules.d/92-oob_net.rules"
fi

# Replace OS image inside the initramfs
mkdir -p ${bfbdir}/initramfs
cd ${bfbdir}/initramfs
echo "Extracting dump-initramfs-v0 to ${bfbdir}/initramfs"
gzip -d < "${bfbdir}/dump-initramfs-v0" | cpio -id
echo "Removing original OS image from the initramfs"
/bin/rm -f "${bfbdir}/initramfs/ubuntu/image.tar.xz"
echo "Creating new OS image inside the initramfs"
XZ_OPT="--threads=0 -9 --verbose" \
  tar -cJp \
  --exclude='./var/tmp/*' \
  --exclude='./var/tmp/swap.img' \
  --exclude='./home/nvidia/*.tgz' \
  --exclude='./home/nvidia/*.bz2' \
  --exclude='./home/nvidia/*.deb' \
  --exclude='./usr/share/doca*' \
  -f "${bfbdir}/initramfs/ubuntu/image.tar.xz" \
  -C "${targetdir}" .

# Create the initramfs
echo "Creating new initramfs"
cd ${bfbdir}/initramfs
find . | cpio -o -H newc | gzip -9 > ${outputdir}/initrd
cd -

umount "${targetdir}"/boot/efi/
umount "${targetdir}"
rmdir "${targetdir}"
/bin/rm -rf "${bfbdir}"

kpartx -d "${IMG}"

cat > ${outputdir}/grub.cfg << EOF
OS_NAME="${BFB_NAME}"
export OS_NAME

set default=0
set timeout=3
if loadfont unicode ; then
  set locale_dir=\$prefix/locale
  set lang=en_US
fi

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray
if background_color 44,0,30; then
  clear
fi

menuentry "\${OS_NAME} Installation" {
  echo "Starting \${OS_NAME} Image installation..."
  echo "--------------------------------------------------"
  echo " GRUB CPU and platform: \${grub_cpu}, \${grub_platform}"
  echo " Network status:"
  net_ls_cards
  net_ls_addr
  net_ls_routes
  echo " Default interface: \${net_default_interface}"
  echo " Default IP:        \${net_default_ip}"
  echo " Default MAC:       \${net_default_mac}"
  echo " TFTP/next server:  \${net_default_server}"
  echo " PXE next server:   \${pxe_default_server}"
  echo "--------------------------------------------------"
  sleep 5
  echo "Downloading kernel (vmlinuz)..."
  linux \${OS_NAME}/vmlinuz net.ifnames=0 keep_bootcon biosdevname=0 ip=dhcp bfks=http://192.168.10.10/bfks
  echo "Downloading initrd (can take up to 20 minutes)..."
  initrd \${OS_NAME}/initrd
  echo "Transferring control to kernel..."
}
EOF

# Create bfks script
cat > ${outputdir}/bfks << 'EOF_BFKS'
cat > /etc/bf.cfg << 'EOF'


bfb_pre_install()
{
    echo "Running BFB PRE INSTALL on $device" > /dev/kmsg
    ilog "OS installation target: $device"

    wait_for_device $device

    log "Preparing custom partitioning"

        dd if=/dev/zero of=$device bs=512 count=1

    parted --script $device -- \
        mklabel gpt \
        mkpart primary fat32 1MiB 51MiB set 1 esp on \
        mkpart primary ext4 51MiB 51251MiB \
        mkpart primary 51251MiB 100%

    sync

    # Refresh partition table
    sleep 1
    blockdev --rereadpt ${device} > /dev/null 2>&1
}

EOF

EOF_BFKS

chmod +x ${outputdir}/bfks

echo "ISO installation files are created in ${outputdir}"

exit 0

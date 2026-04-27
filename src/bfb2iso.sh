#!/bin/bash -x

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <bundle.bfb> <iso.iso>"
  exit 1
fi

BFB=$(readlink -f "$1")
ISO=$(readlink -f "$2")

if [[ -z "${ISO}" || -z "${BFB}" ]]; then
  echo "Usage: $0 <bundle.bfb> <iso.iso>"
  exit 1
fi

TDIR=${TDIR:-"$(mktemp -d /tmp/bfb2iso.XXXXXXXXXX)"}
MNT_DIR=${MNT_DIR:-"$(mktemp -d /mnt/iso.XXXXXXXXXX)"}
MNT_SQUASHFS=${MNT_SQUASHFS:-"$(mktemp -d /mnt/squashfs.XXXXXXXXXX)"}
targetdir="${TDIR}/isosource"
outputdir="${TDIR}/outputdir"
G_TITLE="bf-bundle"
G_VERSION="$(echo "$BFB" | cut -d '-' -f 3,4 | sed -e 's/.bfb//')"
outputfile="${outputdir}/${G_TITLE}-${G_VERSION}.iso"

tree_dir="${targetdir}/tree"
efi_img="${targetdir}/boot/grub/efi.img"
efi_dir="${targetdir}/boot/grub/efi"
grub_cfg="${tree_dir}/boot/grub/grub.cfg"

kpartx_out=$(kpartx -asv "${ISO}")
ISO1_PARTITION="/dev/mapper/"$(echo $kpartx_out | cut -d " " -f 3)
ISO2_PARTITION="/dev/mapper/"$(echo $kpartx_out | cut -d " " -f 12)

/bin/rm -rf "${TDIR}/bfb" "${tree_dir}" "${targetdir}/boot"
mkdir -p "${TDIR}/bfb" "${outputdir}" "${tree_dir}/bfb" "${tree_dir}/boot/grub" "${efi_dir}/EFI/BOOT"

cd "${TDIR}/bfb"
mlx-mkbfb -x "${BFB}"

mount ${ISO1_PARTITION} "${MNT_DIR}"
cp -a "${MNT_DIR}"/boot/ "${tree_dir}"
cp -a "${MNT_DIR}"/efi/ "${tree_dir}"
mount "${MNT_DIR}"/casper/ubuntu-server-minimal.ubuntu-server.installer.kernel.nvidia.squashfs "${MNT_SQUASHFS}"

# Extract dump-initramfs-v0 from the BFB to add /etc/bf4-64k-release file to the iso
mkdir -p "${TDIR}/bfb/initramfs"
cd "${TDIR}/bfb/initramfs"
echo "Extracting dump-initramfs-v0 to ${TDIR}/bfb/initramfs"
gzip -d < "${TDIR}/bfb/dump-initramfs-v0" | cpio -id
mkdir -p "${TDIR}/bfb/rootfs"
EXTRACT_UNSAFE_SYMLINKS=1 tar -xJf "${TDIR}/bfb/initramfs/ubuntu/image.tar.xz" --warning=no-timestamp -C "${TDIR}/bfb/rootfs"

grep 'BF4_64K'  "${MNT_SQUASHFS}"/ai/bf4_64k-ai.yaml | sed 's/^[ ]*//' | sed 's/CHANGE_DESC_PLATFORM/Not Specified/;s/CHANGE_SERIAL_NUMBER/Not Specified/' > "${TDIR}/bfb/rootfs/etc/bf4-64k-release"
echo Added /etc/bf4-64k-release file to the initramfs
BFB_VERSION="$(cat ${TDIR}/bfb/rootfs/etc/mlnx-release)"
source "${TDIR}/bfb/rootfs/etc/bf4-64k-release"
cat "${TDIR}/bfb/rootfs/etc/bf4-64k-release"
XZ_OPT="--threads=0 -9 --verbose" tar -cJp -f "${TDIR}/bfb/initramfs/ubuntu/image.tar.xz" -C "${TDIR}/bfb/rootfs" .
find . | cpio -o -H newc | gzip -9 > "${TDIR}/bfb/dump-initramfs-v0"
cd -

umount "${MNT_SQUASHFS}"
rmdir "${MNT_SQUASHFS}"
umount "${MNT_DIR}"
rmdir "${MNT_DIR}"

if xz --format=lzma -t "${TDIR}/bfb/dump-image-v0" > /dev/null 2>&1; then
  cp "${TDIR}/bfb/dump-image-v0" "${tree_dir}/bfb/vmlinuz.lzma"
  xz --format=lzma -d "${tree_dir}/bfb/vmlinuz.lzma"
  gzip "${tree_dir}/bfb/vmlinuz"
  mv "${tree_dir}/bfb/vmlinuz.gz" "${tree_dir}/bfb/vmlinuz"
else
  cp "${TDIR}/bfb/dump-image-v0" "${tree_dir}/bfb/vmlinuz"
fi
cp "${TDIR}/bfb/dump-initramfs-v0" "${tree_dir}/bfb/initrd"

cat > "${grub_cfg}" << EOF
loadfont unicode

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

set default=0
set timeout=3

menuentry "${G_TITLE}-${G_VERSION} Installation" {
  linux /bfb/vmlinuz ${KERNEL_ARGS:-"console=earlycon console=tty0 console=ttyS0,115200"}
  initrd /bfb/initrd
}
EOF

dd if="${ISO2_PARTITION}" of="${efi_img}"

kpartx -d "${ISO}"

xorriso -as mkisofs \
  -iso-level 3 \
  -allow-lowercase \
  -volid "${G_TITLE}-${G_VERSION}" \
  -J \
  -joliet-long \
  -l \
  -c boot/boot.cat \
  -partition_offset 16 \
  -append_partition 2 0xef "${efi_img}" \
  -e --interval:appended_partition_2:all:: \
  -no-emul-boot \
  -partition_cyl_align all \
  "${tree_dir}" \
  -output "${outputfile}"

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

verbose=false
out_path=`pwd`
os="ubuntu"
#A bash-specific way to do case-insensitive matching
shopt -s nocasematch

#########################
# The command line help #
#########################
function display_help() {
    echo "Usage: $0 " >&2
    echo
    echo "   -bfb                       The bfb file you want to create an image from"
    echo "   -out                       Output directory for the created image"
    echo "   -os                        OS included in the BFB (ubuntu or centos)"
    echo "   -verbose                   Print info logs during run"
    echo
    echo "   This is a utility script to convert an BFB into a disk image."
    echo "   Currently works only for Ubuntu OS."
    exit
}

#show help
if [ "$1" == "-h" ]; then
    display_help
fi

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

#parse script arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -bfb|--bfb)
            bfb=$2
            shift # past argument
            shift # past value
            ;;
        -verbose|--verbose)
            verbose=$2
            shift
            shift
            ;;
        -out|--out)
            out_path=$2
            shift # past argument
            shift # past value
            ;;
        -os|--os)
            os=$2
            shift # past argument
            shift # past value
            ;;
        *|-*)
            log "ERROR: unknown option $1"
            exit 1
            ;;
        *)
    esac
done

#check that out_path exists
if [ ! -d "$out_path" ]; then
    log "ERROR: $out_path doesn't exist,please provide a directory that exists."
    exit 1
else
    out_path=`realpath $out_path`
fi

if [ ! -w $out_path ]; then
    log "ERROR: $out_path doesn't have write permissions. Please use -out flag to choose a directory with write permissions"
    exit 1
fi

#check verbose argument
if [[ "$verbose" != "true"  &&  "$verbose" != "false" ]]; then
    log "ERROR: verbose value can be false or true only"
    exit 1
fi

#check that file exist and it is a bfb file
if [ -f "$bfb" ]; then
	bfb=`realpath $bfb`
else
    log "ERROR: file $bfb doesn't exist"
    exit
fi

cd ${0%*/*}

#check Dockerfile exist
if [ ! -e Dockerfile ]; then
    log "ERROR: Dockerfile is missing."
    exit 1
fi

if ! (which docker > /dev/null 2>&1); then
    log "ERROR: docker is required to build BFB"
    exit 1
fi

#create working directory
id=$$
bfb_basename=`basename $bfb`
WDIR=/tmp/$bfb_basename$id
mkdir -p $WDIR

if [ "$os" == "centos" ]; then
    cp bfb_tool_raw_img.centos.sh $WDIR/bfb_tool_raw_img.sh
else
    cp bfb_tool_raw_img.sh $WDIR
fi

cp    Dockerfile \
      mlx-mkbfb.py \
      mlnx_bf_configure \
      vf-net-link-name.sh \
      mlnx_bf_udev \
      qemu-aarch64-static \
      $bfb \
      $WDIR

if [ $? -ne 0 ]; then
    log "ERROR: Couldn't copy relevant files to $WDIR"
fi

cd $WDIR
img_name=create_img_runtime:$id

if [ "`uname -m`" != "aarch64" ]; then
    log "INFO: add support to run aarch64 continer over different host architecture"
    if ! (grep -q /usr/bin/qemu-aarch64-static /etc/binfmt.d/qemu-aarch64.conf > /dev/null 2>&1); then
        cat > /etc/binfmt.d/qemu-aarch64.conf << EOF
            :qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7:\xff\xff\xff\xff\xff\xff\xff\xfc\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff:/usr/bin/qemu-aarch64-static:
EOF
    fi
    systemctl restart systemd-binfmt
fi


#build docker
docker build -t $img_name \
	     --build-arg  bfb=$bfb_basename \
	     -f Dockerfile .

if [ $? -ne 0 ]; then
    log "ERROR: Couldn't build docker image"
fi

#run docker
docker run -t --rm --privileged -e container=docker \
	   -v $PWD:/workspace \
	   --name img_$id \
	   --mount type=bind,source=/dev,target=/dev \
	   --mount type=bind,source=/sys,target=/sys \
	   --mount type=bind,source=/proc,target=/proc \
	   $img_name ${bfb##*/} $verbose

if [ $? -ne 0 ]; then
    log "ERROR: Couldn't create successfully VM image"
fi

#copy img to output path
log "INFO: copy ${bfb_basename%.*}.img to $out_path"
mv $WDIR/${bfb_basename%.*}.img $out_path

log "INFO: removing $WDIR"
rm $WDIR -rf

log "INFO: removing image create_img_runtime_$id"
docker image rm $img_name

log "INFO: script finish running successfully, ${bfb_basename%.*}.img is ready"


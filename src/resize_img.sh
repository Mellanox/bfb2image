#!/bin/bash -e

usage()
{
    cat << EOF
    Usage: $(basename $0) <img> <new size in GB>
EOF
}

check_tool()
{
    if ! which $1 > /dev/null 2>&1; then
        echo $1 is required
        exit 1
    fi
}

case $@ in
    *-h* | *--help*)
        usage
        exit 0
        ;;
esac

orig_image=$1
new_size=$2

if [[ ! -e $orig_image || -z $new_size ]]; then
    usage
    exit 1
fi

check_tool truncate
check_tool virt-resize

root_part=${root_part:-"/dev/sda2"}
current_size=$(virt-filesystems --no-title --all -l -h --block-devices -a $orig_image | grep -w $root_part | grep partition | tr -d 'G' | awk '{print int($5 + 0.5)}')

new_img="${orig_image/.img/}_${new_size}G.img"
cat << EOF
The new image with the root partition of ${new_size}G instead of ${current_size}G will be created
$new_img
EOF

dd if=/dev/zero of=$new_img iflag=fullblock bs=1M count=$((new_size*1000))
truncate -r ${orig_image} ${new_img}
truncate -s +$((${new_size}-${current_size}))G ${new_img}

virt-resize --expand ${root_part} ${orig_image} ${new_img}

if [ $? -eq 0 ]; then
    echo
    echo Created ${new_img}:
    virt-filesystems --all -l -h --block-devices -a ${new_img} | grep -vE "partition|device"
fi

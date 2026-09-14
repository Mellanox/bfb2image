# bfb2image script
**description**

This script takes a bfb or an iso and creates from it a VM image.

An iso is accepted because a bfb-built iso carries the very same initramfs as
the bfb it was built from, so both sources hold the same OS filesystem.

**prerequisites**

-bfb/iso must be based on Ubuntu OS.

-Docker must be installed to run this script.

-Can be used on arm or x86 architecture only
   
**Usage**

Usage:
./bfb_to_raw_img.sh 

   -bfb                       The bfb file you want to create an image from

   -iso                       The iso file you want to create an image from
   
   -out                       Output directory for the created image
   
   -os                        OS included in the BFB/ISO (ubuntu or centos)

   -verbose                   Print info logs during run

Exactly one of -bfb and -iso must be given.

**Examples**

    ./bfb_to_raw_img.sh -bfb bf-bundle.bfb -out /tmp/images -os ubuntu

    ./bfb_to_raw_img.sh -iso bf-bundle.iso -out /tmp/images -os ubuntu

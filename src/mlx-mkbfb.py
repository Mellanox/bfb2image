#!/usr/bin/env python3
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

"""
Create or dump a BlueField boot stream.
"""

import binascii
import os
from io import StringIO
import struct
import sys

from optparse import OptionParser, OptionGroup

# Table of all possible image types.  Order is significant, since we
# will emit images in this order unless overridden by the --expert
# switch.  ATF image IDs match those used internally by ATF; see
# atf/include/common/tbbr/tbbr_img_def.h.  UEFI image IDs are defined by
# us; see edk2/MlxPlatformPkg/Filesystem/BfbFs/BfbFs.c.
#
# Contents: (command-line option, description, image ID for header)
image_list = (
    # Images for ATF
    ("psc-bl",    "PSC bootloader image",                  36),
    ("psc-fw",    "PSC framework image",                  37),
    ("bl2r-cert", "RIoT Core (BL2R) content certificate",  31),
    ("bl2r",      "RIoT Core (BL2R) bin",                  30),
    ("bl2-cert",  "Trusted Boot Firmware BL2 certificate", 6),
    ("bl2",       "Trusted Boot Firmware BL2 bin",         1),
    ("sys",       "Running system's part number or PSID",  29),
    ("ddr-cert",  "DDR Images Content Certificate",        38),
    ("ddr_ini", "File From Which Will Load DDR (pseudo spd) Parameters", 32),
    ("snps_images", "Combined SNPS Images for all DIMM types", 33),
    ("ddr_ate_imem", "Analog Test Engine INSTRUCTIONS", 34),
    ("ddr_ate_dmem", "Analog Test Engine DATA", 35),
    ("bl30-key-cert", "SCP Firmware BL3-0 key certificate", 8),
    ("bl30-cert", "SCP Firmware BL3-0 certificate", 12),
    ("bl30", "SCP Firmware BL3-0", 2),
    ("trusted-key-cert", "Trusted key certificate", 7),
    ("bl31-key-cert", "EL3 Runtime Firmware BL3-1 key certificate", 9),
    ("bl31-cert", "EL3 Runtime Firmware BL3-1 content certificate", 13),
    ("bl31", "EL3 Runtime Firmware BL3-1 bin", 3),
    ("psc-app",   "PSC application image",                 39),
    ("bl32-key-cert", "Secure Payload BL3-2 (Trusted OS) key certificate", 10),
    ("bl32-cert", "Secure Payload BL3-2 (Trusted OS) content certificate", 14),
    ("bl32", "Secure Payload BL3-2 (Trusted OS) bin", 4),
    ("bl33-key-cert", "Non-Trusted Firmware BL3-3 key certificate", 11),
    ("bl33-cert", "Non-Trusted Firmware BL3-3 content certificate", 15),
    ("bl33", "Non-Trusted Firmware BL3-3 bin", 5),

    # Images for UEFI
    ("capsule", "UEFI capsule image", 52),
    ("boot-acpi", "Name of the ACPI table", 55),
    ("boot-dtb", "Name of the dtb file", 56),
    ("boot-desc", "Default boot menu item description", 57),
    ("boot-path", "Boot image path", 58),
    ("boot-args", "Arguments for boot image", 59),
    ("boot-timeout", "Boot menu timeout", 60),
    ("uefi-tests", "Specify what UEFI tests to run", 61),
    ("ramdisk", "RAM Disk image", 54),
    ("image", "Boot image", 62),
    ("initramfs", "In-memory filesystem", 63),
)

# Map command-line option to (description, image ID)
image_table = dict([(x, (y, z)) for (x, y, z) in image_list])

# Map image ID to (command-line option, description)
rev_image_table = dict([(z, (x, y)) for (x, y, z) in image_list])

# Did we see the -v option?
verbose = False

# Maximum allowed image version number (inclusive)
MAX_VER = 2

MAJOR_VER = 1
MINOR_VER = 2

#
# We pad images out to an even multiple of 8 bytes.
#
def num_padding_bytes(length):
    """Return the number of padding bytes needed for the given length."""

    return ((length + 7) & ~7) - length


class NoHdr(Exception):
    """
    Exception raised when we try to create an ImageHdr from a stream at
    end-of-file.
    """
    pass


class BadHdr(Exception):
    """
    Exception raised when we try to create an ImageHdr from a stream
    which contains a bad image header.
    """

    def __init__(self, msg):
        self.msg = msg

    def __str__(self):
        return self.msg


#
# Currently we produce/consume a little-endian boot stream.  If we
# ever need to change that, you'll need to modify the code below that
# packs/unpacks the header, and possibly the code that handles padding
# bytes at the end of images.
#
class ImageHdr:
    """Represent a BlueField boot stream image header."""

    magic = 0x13026642          # Magic number, "Bf^B^S"
    default_major = MAJOR_VER   # Major version number
    default_minor = MINOR_VER   # Minor version number
    length = 24                 # Header length; must be multiple of 8

    def __init__(self, infile=None, major=default_major, minor=default_minor,
                 image_id=0, image_len=0, image_crc=0, following_images=0,
                 next_img_ver=0, cur_img_ver=0):

        if infile:
            self.__set_from_file(infile)
        else:
            self.major = major
            self.minor = minor
            self.image_id = image_id
            self.next_img_ver = next_img_ver
            self.cur_img_ver = cur_img_ver
            self.image_len = image_len
            self.image_crc = image_crc
            self.following_images = following_images

    def get_header_length(self):
        """Return length of header in bytes."""
        #
        # Right now this is constant; if later versions increase the header
        # size, or include optional fields, this might vary based on the
        # specific contents of this header.
        #
        return length

    def get_image_id(self):
        """Return the image's ID."""
        return self.image_id

    def get_image_length(self):
        """
        Return the image's length in bytes.  Note that the image following
        this header in the boot stream will be padded with the minimum
        necessary number of trailing zeroes to make it an even multiple
        of 8 bytes long; this padding is not included in the length value.
        """
        return self.image_len

    def get_image_ver(self):
        """Return the image version of the current image."""
        return self.cur_img_ver

    def set_next_image_ver(self, version):
        """Set the image version of the next image following this image"""
        self.next_img_ver = version

    def get_image_crc(self):
        """
        Return the image's CRC.  Note that this covers both the bytes of
        the image, and any added padding bytes.
        """
        return self.image_crc

    def get_following_images(self):
        """Return bitmap of IDs of subsequent images."""
        return self.following_images

    def set_following_images(self, follow_map):
        """Set bitmap of IDs of subsequent images."""
        self.following_images = follow_map

    def get_bits(self):
        """Return a string containing the header."""

        w0 = (((self.magic & 0xFFFFFFFF) << 0) |
              ((self.major & 0xF) << 32) |
              ((self.minor & 0xF) << 36) |
              ((self.next_img_ver & 0xF) << 44) |
              ((self.cur_img_ver & 0xF) << 48) |
              (((self.length // 8) & 0xF) << 52) |
              ((self.image_id & 0xFF) << 56))

        w1 = (((self.image_len & 0xFFFFFFFF) << 0) |
              ((self.image_crc & 0xFFFFFFFF) << 32))

        w2 = self.following_images

        return struct.pack("<QQQ", w0, w1, w2)

    def __set_from_file(self, infile):
        """
        Parse the header at the current position of the provided file and
        set our state appropriately, consuming only the header bytes;
        if the current file position does not contain a valid header,
        raise an exception.  Note that if an exception is raised, the
        amount of data consumed from the file is indeterminate.
        """

        #
        # This will need to get more complicated if we ever have
        # variable-length headers, but for now, we can just read a fixed
        # amount.
        #
        instr = infile.read(self.length)
        if not instr:
            raise NoHdr()

        if len(instr) < self.length:
            raise BadHdr("ImageHdr too short")

        (w0, w1, w2) = struct.unpack("<QQQ", instr)

        magic = w0 & 0xFFFFFFFF
        self.major = (w0 >> 32) & 0xF
        self.minor = (w0 >> 36) & 0xF
        length = (w0 >> 52) & 0xF
        self.image_id = (w0 >> 56) & 0xFF
        self.image_len = w1 & 0xFFFFFFFF
        self.image_crc = (w1 >> 32) & 0xFFFFFFFF
        self.following_images = w2

        # The next/cur image version fields were only added in minor 2
        if self.minor <= 2:
            self.next_img_ver = (w0 >> 44) & 0xF
            self.cur_img_ver = (w0 >> 48) & 0xF
        else:
            self.next_img_ver = 0
            self.cur_img_ver = 0

        if magic != self.magic:
            raise BadHdr("Bad ImageHdr magic number 0x%x" % magic)

        #
        # Obviously the stuff below will change once we support more than
        # one version.
        #
        if self.major != self.default_major:
            raise BadHdr("Bad ImageHdr major version %d" % self.major)

        if self.minor > self.default_minor:
            raise BadHdr("Bad ImageHdr minor version %d" % self.major)

        if length != self.length / 8:
            raise BadHdr("Bad ImageHdr header length %d" % length)

    def dump(self, outfile=sys.stdout):
        """Dump out all internal state."""
        outtext = "Ver: %d.%d Len: %d ID: %d " \
                  "ImLen: %d ImCRC: 0x%x FolIm: 0x%lx" % (
                    self.major, self.minor, self.length,
                    self.image_id, self.image_len,
                    self.image_crc, self.following_images)
        if self.minor >= 2:
            outtext += " NxImVr: %d ImVr: %d" % (
                         self.next_img_ver, self.cur_img_ver)
        print(outtext, file=outfile)


class Image:
    """Represent a BlueField boot stream image."""

    def __init__(self, instream=None, infile=None, idstr=None):
        """
        Create an Image object.

        instream: File object from which to read the next header and image
          data.  There may be additional headers, images, or other random
          data following that, which will not be consumed.
        infile: Name of file from which to read image data.  Unlike when
          instream is specified, the file does not contain a header, and
          the entire file is consumed; a header will be constructed which
          describes the data we read.  Mutually exclusive with instream.
        idstr: String ID (first column of image_list) for image.  Required,
          and only useful, with infile. Can be suffixed with '-vN' to also
          indicate image version number.

        """

        if instream:
            self.__set_from_stream(instream)
        elif infile:
            self.__set_from_file(infile, idstr)
        else:
            self.header = ImageHdr()
            self.bits = None

    def get_bits(self):
        """Return image data."""
        return self.bits

    def get_padding(self):
        """Return pad bytes."""
        length = self.header.get_image_length()
        return b'\0' * num_padding_bytes(length)

    def get_image_id(self):
        """Return the numeric image ID for this image."""
        return self.header.get_image_id()

    def get_image_ver(self):
        """Return the current image ID for this image."""
        return self.header.get_image_ver()

    def set_next_image_ver(self, next_img_ver):
        """Set the image version of the next image following this image"""
        self.header.set_next_image_ver(next_img_ver)

    def get_image_length(self):
        """Return the image's length in bytes."""
        return self.header.get_image_length()

    def set_following_images(self, follow_map):
        """Set the bitmap of images following this one."""
        self.header.set_following_images(follow_map)

    def write(self, outfile):
        """Write image contents to an output stream."""

        outfile.write(self.header.get_bits())
        outfile.write(self.bits)
        outfile.write(self.get_padding())

    def dump(self, outfile=sys.stdout):
        self.header.dump(outfile)

    def __set_from_stream(self, instream):
        """
        Initialize ourselves from the given stream, which contains a header
        and then image data; only the data described by the header will be
        consumed, so you can call this repeatedly on a stream to pick off
        all of the images it contains.

        instream: stream to read.
        """

        self.header = ImageHdr(infile=instream)

        length = self.header.get_image_length()

        self.bits = instream.read(length)
        if len(self.bits) != length:
            raise Exception("Image ID %d: stream corrupted, image too short" %
                            self.header.get_image_id())

        crc = binascii.crc32(self.bits, 0)
        padding = instream.read(num_padding_bytes(length))
        crc = binascii.crc32(padding, crc)
        crc &= 0xFFFFFFFF

        if crc != self.header.get_image_crc():
            raise Exception("Image ID %d: header CRC of 0x%08x does "
                            "not match calculated CRC of 0x%08x" %
                            (self.header.get_image_id(),
                             self.header.get_image_crc(), crc))

    def __set_from_file(self, infile, idstr):
        """
        Initialize ourselves from the given filename/string.  The entire
        file or string makes up the image, and we then construct a header
        which describes that image data.

        stream: file name, or string preceded by "=".
        idstr: string ID of image. Can be suffixed with '-vN' to also indicate
          image version number.
        """

        if infile.startswith("="):
            self.bits = bytes(infile[1:], 'utf-8')
        else:
            with open(infile, "rb") as f:
                self.bits = f.read()

        length = len(self.bits)

        crc = binascii.crc32(self.bits, 0)
        crc = binascii.crc32(b'\0' * num_padding_bytes(length), crc)
        crc &= 0xFFFFFFFF

        # Check if idstr is suffixed with '-vN', while NOT assuming that
        # image names can't contain '-v' in its name.
        img_ver = 0

        if '-' in idstr:
            (img, ver) = idstr.rsplit('-', 1)
            if len(ver) > 1 and ver[0] == 'v' and ver[1:].isdigit():
                if img in image_table:
                    idstr = img
                    img_ver = int(ver[1:])

        self.header = ImageHdr(image_id=image_table[idstr][1],
                               image_len=length, image_crc=crc,
                               cur_img_ver=img_ver)


def make_stream(infnt, outfn, image_tuples, expert):
    """
    Write a boot stream to an output file.

    infnt: tuple of input file names, files with bigger index takes priority
    outfn: output file name.
    image_tuples: an iterable containing tuples, each of which contains the
      string image identifier (the first column of image_list) and the filename
      (or literal string) from the command line.
    """

    #
    # We'll construct the following_images bitmap while reading in the
    # images, and then will reduce it with every output image.
    #
    fim_map = 0

    #
    # If there's an input file, open it, and read in its contents.
    #
    infile_images = {}
    for infn in infnt:
        infile = open(infn, "rb")
        while True:
            try:
                img = Image(instream=infile)
            except NoHdr:
                break

            id = rev_image_table[img.get_image_id()][0]
            if id not in infile_images:
                infile_images[id] = {}

            infile_images[id][img.get_image_ver()] = img
            fim_map |= 1 << img.get_image_id()
        infile.close()

    #
    # If there are files from the command line, open them and read in
    # their contents.
    #
    cmdline_images = {}
    # The idver from the command line might have the -vN suffix, so we need
    # to generate one without the suffix to be used for expert mode
    cmdline_image_order = []
    for (idver, fn) in image_tuples:

        img = Image(infile=fn, idstr=idver)
        id = rev_image_table[img.get_image_id()][0]

        if id not in cmdline_images:
            cmdline_images[id] = {}

        cmdline_images[id][img.get_image_ver()] = img

        if id not in cmdline_image_order:
            cmdline_image_order.append(id)

        fim_map |= 1 << img.get_image_id()

    #
    # In expert mode, we emit images in the order we found them on the command
    # line, but otherwise, we use the order they're found in image_list.
    #
    if expert:
        image_order = cmdline_image_order
    else:
        image_order = [x[0] for x in image_list]

    outfile = open(outfn, "wb")

    #
    # Emit each image in order, preferring the version from the command line.
    #
    for i in image_order:

        images = {}

        # Note the order here will let the images from the cmdline override
        # images of the same version read from the file.
        if i in infile_images:
            images.update(infile_images[i])

        if i in cmdline_images:
            images.update(cmdline_images[i])

        if len(images) == 0:
            continue

        # Version order is strictly enforced here, even in expert mode.
        images = [images[x] for x in sorted(images.keys())]

        while len(images) > 0:
            img = images.pop(0)

            if len(images) == 0:
                fim_map &= ~(1 << img.get_image_id())
                img.set_next_image_ver(0)
            else:
                img.set_next_image_ver(images[0].get_image_ver())

            img.set_following_images(fim_map)

            # The image might be loaded from a previous bfb of a lower version
            # so make sure the generated bfb file have the current version.
            img.header.minor = MAJOR_VER
            img.header.minor = MINOR_VER

            img.write(outfile)

    outfile.close()


def dump_stream(infn, do_dump, do_extract, prefix):
    """
    Dump a description of a boot stream.

    infn: input filename.
    do_dump: if true, print table of contents.
    do_extract: if true, extract images to files.
    prefix: prefix to use with extracted image filenames.
    """

    inf = open(infn, "rb")

    while True:
        try:
            img = Image(instream=inf)
        except NoHdr:
            break

        id = img.get_image_id()
        if id in rev_image_table:
            fn = rev_image_table[id][0]
            desc = rev_image_table[id][1]
        else:
            fn = "image_id_%d" % id
            desc = "Unknown image type, ID %d" % id

        if img.header.minor >= 2:
            fn += "-v%d" % img.get_image_ver()
            desc += " (version %d)" % img.get_image_ver()

        if do_dump:
            if verbose:
                img.dump()
            else:
                print("%10d %s" % (img.get_image_length(), desc))

        if do_extract:
            xfile = open(prefix + fn, "wb")
            xfile.write(img.get_bits())
            xfile.close()

    inf.close()


def parse_image_opt(option, opt_str, value, parser):
    """Handle one of the --<image-type> options."""
    parser.values.images.append((opt_str.lstrip("-"), value))


def main(argv):
    #
    # Set up our option parser.
    #
    parser = OptionParser(
            usage="\n  %prog [ options ] [ INFILE ] [ INFILE2 ] OUTFILE\n"
                  "  %prog -[dx] [ options ] INFILE\n"
                  "  %prog [ -h | --help ]",
            description="%prog creates or dumps a BlueField boot stream.")
    parser.add_option(
            "-d", "--dump", dest="d", action="store_true",
            help="print listing of images within INFILE")
    parser.add_option(
            "-x", "--extract", dest="x", action="store_true",
            help="extract images from INFILE and write to files")
    parser.add_option(
            "-p", "--prefix", dest="p", action="store", type="string",
            metavar="PFX", default="dump-",
            help="prefix for files containing extracted images; "
                 "default is '%default'")
    parser.add_option(
            "-v", "--verbose", dest="v", action="store_true",
            help="provide more verbose output")
    parser.add_option(
            "-e", "--expert", dest="e", action="store_true",
            help="expert mode: emit images in order specified on command line")

    parser.set_defaults(images=[])

    iog = OptionGroup(parser, "Image Options",
                      'Images specified on the command line replace images '
                      'of the same type within the input file.  Note: an '
                      'image specification may either be the name of a file '
                      'which contains the image data (e.g., --image=vmlinux), '
                      'or a literal string prefixed with an equals sign '
                      '(e.g., --boot-args="=debug isolcpus=10").'
                      'An optional "-vN" can be added to the image name to '
                      'specify which version the image is, default to 0.')
    for fn in image_table:
        iog.add_option(
                "--" + fn, type="string",
                action="callback", callback=parse_image_opt, metavar="IMAGE",
                help="take data for " + image_table[fn][0] + " from IMAGE")

        # Also add the options with the "-vN" prefix in the image option
        for v in range(MAX_VER + 1):
            iog.add_option(
                    "--" + fn + "-v%d" % v, type="string", action="callback",
                    callback=parse_image_opt, metavar="IMAGE")

    parser.add_option_group(iog)

    #
    # Parse the command line and execute.
    #
    (opt, args) = parser.parse_args()

    if opt.v:
        global verbose
        verbose = True

    if (opt.d or opt.x) and len(args) > 1:
        parser.error("no output file allowed with -d/-x")

    if len(args) > 3:
        parser.error("only two input and one output file allowed")

    if opt.d or opt.x:
        if opt.e:
            parser.error("-e not applicable with -d/-x")
        if opt.images:
            parser.error("cannot specify images with -d/-x")
        dump_stream(args[0], opt.d, opt.x, opt.p)
    else:
        if len(args) <= 0:
            parser.error("must specify a file")
        elif len(args) == 1:
            infn = ()
            outfn = args[0]
            if not opt.images:
                parser.error("must specify input .bfb or at least one image "
                             "option with output file")
        elif len(args) == 2:
            infn = (args[0],)
            outfn = args[1]
            if opt.e:
                parser.error("input file not permitted with -e")

        else:
            infn = (args[0], args[1])
            outfn = args[2]
            if opt.e:
                parser.error("input file not permitted with -e")

        make_stream(infn, outfn, opt.images, opt.e)


if __name__ == "__main__":
    main(sys.argv)

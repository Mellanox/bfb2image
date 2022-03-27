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

FROM ubuntu:20.04
ARG bfb
ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /root/workspace
VOLUME ["/workspace"]
ADD bfb_tool_raw_img.sh .

ADD $bfb .
ADD mlx-mkbfb.py .
RUN apt-get update -y
RUN apt-get install -y qemu-user-static
RUN apt-get install -y python3
RUN apt-get install git -y
RUN apt-get install -y cpio
RUN apt-get install -y kpartx
RUN apt-get install -y dosfstools
ENTRYPOINT ["/root/workspace/bfb_tool_raw_img.sh"]


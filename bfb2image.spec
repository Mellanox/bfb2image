Name: bfb2image		
Version: 1.0.0	
Release: 1%{?dist}
Summary: Create an img from a bfb	

Group: System Environment/Base		
License: GLv2/BSD
URL: https://developer.nvidia.com/networking/doca		
Source: %{name}-%{version}.tar.gz	
BuildRequires: docker	
Requires:	
BuildRoot: %{?build_root:%{build_root}}%{!?build_root:/var/tmp/%{name}-%{version}-root}
Vendor: Nvidia

%description
This script takes an bfb and create from it a VM image.


%install
install -d %{buildroot}/opt/mellanox/bfb2image
make install DESTDIR=%{buildroot}
install -m 0755	src/bfb_to_raw_img.sh     %{buildroot}/opt/mellanox/hlk/bfb2image
install -m 0755	src/bfb_tool_raw_img.sh   %{buildroot}/opt/mellanox/hlk/bfb2image
install -m 0755	src/mlx-mkbfb.py          %{buildroot}/opt/mellanox/hlk/bfb2image
install -m 0755	src/qemu-aarch64-static   %{buildroot}/opt/mellanox/hlk/bfb2image
install -m 0755	src/Dockerfile            %{buildroot}/opt/mellanox/hlk/Dockerfile




%changelog


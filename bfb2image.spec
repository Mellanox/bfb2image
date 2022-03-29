Name: bfb2image		
Version: 1.0.0	
Release: 1%{?dist}
Summary: Create an img from a bfb	
Group: System Environment/Base		
License: GLv2/BSD
URL: https://developer.nvidia.com/networking/doca		
Source: %{name}-%{version}.tar.gz	
BuildRoot: %{?build_root:%{build_root}}%{!?build_root:/var/tmp/%{name}-%{version}-root}
Vendor: Nvidia

%description
This script takes an bfb and create from it a VM image.

%prep
%setup -q


%install
install -d %{buildroot}/opt/mellanox/bfb2image
install -m 0755	src/bfb_to_raw_img.sh     %{buildroot}/opt/mellanox/bfb2image/bfb_to_raw_img.sh
install -m 0755	src/bfb_tool_raw_img.sh   %{buildroot}/opt/mellanox/bfb2image/bfb_tool_raw_img.sh
install -m 0755	src/mlx-mkbfb.py          %{buildroot}/opt/mellanox/bfb2image/mlx-mkbfb.py
install -m 0755	src/Dockerfile            %{buildroot}/opt/mellanox/bfb2image/Dockerfile
%ifarch x86_64	
	install -m 0755	src/qemu-aarch64-static   %{buildroot}/opt/mellanox/bfb2image/qemu-aarch64-static
%endif


%files
/opt/mellanox/bfb2image/bfb_to_raw_img.sh
/opt/mellanox/bfb2image/bfb_tool_raw_img.sh
/opt/mellanox/bfb2image/mlx-mkbfb.py
/opt/mellanox/bfb2image/Dockerfile
%ifarch x86_64	
	/opt/mellanox/bfb2image/qemu-aarch64-static
%endif




%changelog


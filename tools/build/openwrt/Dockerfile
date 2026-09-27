# OpenWrt build environment for tools/build/remote-openwrt.sh: the same host
# prerequisites as .github/workflows/openwrt.yml (Ubuntu 24.04), and a
# non-root user, since OpenWrt refuses to build as root.
FROM ubuntu:24.04

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential clang flex bison g++ gawk gettext git libncurses-dev libssl-dev \
        python3 python3-setuptools rsync swig unzip zlib1g-dev file wget zstd xz-utils \
        bzip2 perl patch diffutils ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && userdel -r ubuntu \
    && useradd -m -u 1000 build \
    && mkdir /build && chown build:build /build

USER build
WORKDIR /build

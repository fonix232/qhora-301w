# Build environment for mainline U-Boot (arm64, native on an arm64 host) and
# the AArch32 bits (trampoline, QCA u-boot-2016 reference builds).
FROM debian:trixie

RUN apt-get update && apt-get install -y --no-install-recommends \
        bc bison build-essential ca-certificates cpio device-tree-compiler efitools \
        fdisk file flex gcc-arm-linux-gnueabihf gdisk git libgnutls28-dev libssl-dev \
        python3 python3-dev python3-libfdt python3-pyelftools python3-setuptools \
        swig u-boot-tools uuid-dev xxd \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work

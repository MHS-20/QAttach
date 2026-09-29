# Build and test environment for running lock_etcd without AWS: builds a
# GFS2 kernel with lock_etcd compiled in, then boots it in QEMU/KVM guests
# that share one raw disk image. The container's own root filesystem is
# exported read-only to the guests over 9p, so everything installed here
# is available inside them.
FROM debian:trixie
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential bc flex bison libelf-dev libssl-dev cpio xz-utils curl ca-certificates \
      python3 qemu-system-x86 gfs2-utils etcd-server etcd-client \
      procps iproute2 psmisc util-linux kmod \
    && rm -rf /var/lib/apt/lists/*

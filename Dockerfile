# Stage 1: Build static binaries from source
# Pinned to digest for reproducibility and supply chain protection
FROM ubuntu:noble@sha256:cd1dba651b3080c3686ecf4e3c4220f026b521fb76978881737d24f200828b2b AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential wget ca-certificates bzip2 \
    zlib1g-dev libssl-dev

# -------------------------------------------------------------------
# Build Dropbear from source (static)
# -------------------------------------------------------------------
ARG DROPBEAR_VERSION=2025.89
ARG DROPBEAR_SHA256=0d1f7ca711cfc336dc8a85e672cab9cfd8223a02fe2da0a4a7aeb58c9e113634

RUN wget -q https://matt.ucc.asn.au/dropbear/releases/dropbear-${DROPBEAR_VERSION}.tar.bz2 && \
    echo "${DROPBEAR_SHA256}  dropbear-${DROPBEAR_VERSION}.tar.bz2" | sha256sum -c - && \
    tar xjf dropbear-${DROPBEAR_VERSION}.tar.bz2

RUN cd dropbear-${DROPBEAR_VERSION} && \
    # Override defaults: custom sftp-server path + add ramdisk bin to root PATH \
    printf '%s\n' \
        '#undef SFTPSERVER_PATH' \
        '#define SFTPSERVER_PATH "/mnt/ramdisk/dropbear/bin/sftp-server"' \
        '#undef DEFAULT_ROOT_PATH' \
        '#define DEFAULT_ROOT_PATH "/mnt/ramdisk/dropbear/bin:/usr/sbin:/usr/bin:/sbin:/bin"' \
        > localoptions.h && \
    ./configure --disable-harden && \
    make PROGRAMS="dropbear dropbearkey dropbearconvert scp" STATIC=1 -j$(nproc) && \
    strip dropbear dropbearkey dropbearconvert scp && \
    mkdir -p /opt/bin && cp dropbear dropbearkey dropbearconvert scp /opt/bin/

# -------------------------------------------------------------------
# Build OpenSSH sftp-server (static)
# -------------------------------------------------------------------
ARG OPENSSH_VERSION=9.9p1
ARG OPENSSH_SHA256=b343fbcdbff87f15b1986e6e15d6d4fc9a7d36066be6b7fb507087ba8f966c02

RUN wget -q https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${OPENSSH_VERSION}.tar.gz && \
    echo "${OPENSSH_SHA256}  openssh-${OPENSSH_VERSION}.tar.gz" | sha256sum -c - && \
    tar xzf openssh-${OPENSSH_VERSION}.tar.gz

RUN cd openssh-${OPENSSH_VERSION} && \
    ./configure LDFLAGS="-static" --without-pam --without-selinux --without-libedit && \
    make sftp-server -j$(nproc) && \
    strip sftp-server && \
    cp sftp-server /opt/bin/

# -------------------------------------------------------------------
# Stage 2: Minimal installer image
# Same pinned digest as builder for consistency
# -------------------------------------------------------------------
FROM ubuntu:noble@sha256:cd1dba651b3080c3686ecf4e3c4220f026b521fb76978881737d24f200828b2b

COPY --from=builder /opt/bin/ /usr/local/bin/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

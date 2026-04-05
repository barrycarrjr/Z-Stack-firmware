# Docker build environment for Z-Stack coordinator/router firmware
# Builds CC1352P7/CC2652P7 firmware with increased device limits (400 vs 200)
#
# Usage:
#   docker build -t zstack-builder .
#   docker run --rm -v "$(pwd)/output:/output" zstack-builder
#
# The built hex files will appear in ./output/

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget ca-certificates python3 git patch libc6-i386 \
    libncurses6 libncursesw6 libtinfo6 \
    libusb-0.1-4 libx11-6 libxext6 libxrender1 libxtst6 \
    libxi6 libfreetype6 xz-utils unzip \
    && rm -rf /var/lib/apt/lists/*

# Fake udev for headless Docker (CCS installer needs it)
RUN ln -sf /bin/true /usr/local/bin/udevadm && \
    ln -sf /bin/true /sbin/start_udev && \
    mkdir -p /etc/udev/rules.d

# ---- Install CCS 20.1.0 ----
ARG CCS_URL=https://dr-download.ti.com/software-development/ide-configuration-compiler-or-debugger/MD-J1VdearkvK/20.1.0/CCS_20.1.0.00006_linux.zip
ARG CCS_DIR=/opt/ti/ccs

RUN wget -q "${CCS_URL}" -O /tmp/ccs.zip && \
    mkdir -p /tmp/ccs_installer && \
    unzip -q /tmp/ccs.zip -d /tmp/ccs_installer && \
    ls /tmp/ccs_installer/

RUN /tmp/ccs_installer/CCS*/ccs_setup_*.run \
       --unattendedmodeui none \
       --mode unattended \
       --prefix "${CCS_DIR}" \
       --enable-components PF_WCONN \
    || { echo "CCS installer exit code: $?"; cat /tmp/*.log 2>/dev/null; cat "${CCS_DIR}"/*.log 2>/dev/null; exit 1; }

RUN rm -rf /tmp/ccs.zip /tmp/ccs_installer

# ---- Install SimpleLink SDK 8.30.01.01 ----
ARG SDK_URL=https://dr-download.ti.com/software-development/software-development-kit-sdk/MD-BPlR3djvTV/8.30.01.01/simplelink_cc13xx_cc26xx_sdk_8_30_01_01.run
ARG SDK_DIR=/opt/ti/simplelink_cc13xx_cc26xx_sdk_8_30_01_01

RUN wget -q "${SDK_URL}" -O /tmp/sdk.run && \
    chmod +x /tmp/sdk.run && \
    /tmp/sdk.run --mode unattended --prefix "${SDK_DIR}" && \
    rm /tmp/sdk.run

# ---- Copy firmware patch and build script ----
COPY coordinator/Z-Stack_3.x.0/firmware.patch /build/firmware.patch
COPY build.sh /build/build.sh
RUN chmod +x /build/build.sh

WORKDIR ${SDK_DIR}/simplelink_cc13xx_cc26xx_sdk_8_30_01_01

CMD ["/build/build.sh"]

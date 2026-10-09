# Linux dev/verification image for the Misstype port (docs/linux-port.md).
# Ubuntu 24.04 plus fcitx5 5.1.7 dev headers and its in-process test harness
# (testfrontend/testim/testui under /usr/share/fcitx5/testing). The Zig
# toolchain is not baked in: script/zig/bootstrap.sh downloads the pinned
# version into .cache/zig (dev.sh reuses a host copy when it is a Linux ELF).
# ibus + libibus-dev for the IBus adapter (docs/ibus-port.md).
# Verified on arm64; CI runs it on x86_64.
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && sed -i 's|http://|https://|g' /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get update && apt-get install -y --no-install-recommends \
      cmake make g++ pkg-config extra-cmake-modules gettext python3 curl xz-utils \
      fcitx5 libfcitx5core-dev libfcitx5config-dev libfcitx5utils-dev fcitx5-modules-dev libgtk-4-dev libgtk-3-dev fcitx5-frontend-gtk3 xvfb xdotool dbus-x11 \
      ibus libibus-1.0-dev libglib2.0-dev \
    && rm -rf /var/lib/apt/lists/*

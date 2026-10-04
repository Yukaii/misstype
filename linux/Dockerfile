# Linux dev/verification image for the Misstype port (docs/linux-port.md).
# Swift 6.0 on Ubuntu 24.04 plus fcitx5 5.1.7 dev headers and its in-process
# test harness (testfrontend/testim/testui under /usr/share/fcitx5/testing).
# Verified 2026-09-28 on arm64; CI runs it on x86_64.
FROM swift:6.0
RUN apt-get update && apt-get install -y --no-install-recommends \
      cmake make g++ pkg-config extra-cmake-modules gettext python3 \
      fcitx5 libfcitx5core-dev libfcitx5config-dev libfcitx5utils-dev fcitx5-modules-dev \
    && rm -rf /var/lib/apt/lists/*

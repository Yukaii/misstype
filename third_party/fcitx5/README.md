# fcitx5 core and utility libraries

The Linux addon dynamically links the system-provided Fcitx5Core and
Fcitx5Utils libraries (LGPL-2.1-or-later). Misstype does not redistribute
these libraries or modify them. The addon remains MIT licensed.

License text copied unchanged from fcitx5 5.1.7:
https://github.com/fcitx/fcitx5/blob/5.1.7/LICENSES/LGPL-2.1-or-later.txt

SHA-256: `1ccf09bf2f598308df4bed9cd8e9657dc5cd0973d2800318f2e241486e2edf3f`.
Upstream source: https://github.com/fcitx/fcitx5

Users may modify the addon and replace the shared fcitx5 libraries, including
for debugging their modifications. If a future distribution bundles or
modifies those libraries, it must additionally provide their corresponding
source under the LGPL; the current system-library dependency does not ship it.

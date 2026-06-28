Self-contained — installs Log2Ram via APT (azlux's repo) and configures it
for zram-backed, zstd-compressed RAM log storage. No companion files.

Log2Ram — ramlog-like service for systemd, keeps /var/log in RAM
Source:    [https://github.com/azlux/log2ram](https://github.com/azlux/log2ram)
License:   MIT
Author:    azlux

Features:
• Adds azlux's APT repo + GPG key, with the Debian 13 Trixie pin
workaround for Debian bug #1122989 (buggy logrotate path in Debian's
own trixie log2ram package)
• Detects Pi-Apps "More RAM" (zram swap) before enabling Log2Ram's own
ZL2R zram-backing — notifies/confirms if not found, never silently
proceeds into a config that depends on missing infrastructure
• Configures /etc/log2ram.conf for zram-backed storage: ZL2R=true,
COMP_ALG=zstd, SIZE=128M (hard RAM ceiling), LOG_DISK_SIZE=256M
(logical capacity presented to the OS — paired for ~2:1 minimum
compression headroom, comfortably met by zstd's ~2.9:1 ratio)
• Optional journald drop-in (SystemMaxUse=20M, menu option 9 only — NOT
applied automatically) as a separate file rather than editing the main
journald.conf directly — fully reversible if ever used
• Pre-flight check of current /var/log size against the target RAM
disk capacity, with the documented du/journalctl --vacuum-size fix
• Rollback/crash recovery on install; clean, prompted uninstall
• System packages (rsync, e2fsprogs) retained on uninstall always

Requirements:

* Raspberry Pi OS Trixie (Debian 13) arm64
* Internet connection for the azlux APT repo
* Pi-Apps "More RAM" (zram swap) strongly recommended before enabling
ZL2R — this script checks and warns if it's missing

Usage:
chmod +x log2ram-manager.sh
./log2ram-manager.sh

Do NOT run as root. The script calls sudo internally only where needed.

Disclaimer:
Provided as-is, free of charge, for Raspberry Pi users. Not affiliated
with azlux, the log2ram project, or Raspberry Pi Ltd. Use at your own risk.

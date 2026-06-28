#!/usr/bin/env bash
# =============================================================================
# log2ram-manager.sh
# Log2Ram — RAM-backed /var/log Manager Script
# Version: 1.2.1
# Status: 🟢 GOLD candidate (built from upstream source + Debian bug tracker
#          research, awaiting real-hardware confirmation)
# Last updated: 2026-06-19
#
# Self-contained — installs Log2Ram via APT (azlux's repo) and configures it
# for zram-backed, zstd-compressed RAM log storage. No companion files.
#
# Log2Ram — ramlog-like service for systemd, keeps /var/log in RAM
#   Source:    https://github.com/azlux/log2ram
#   License:   MIT
#   Author:    azlux
#
# Features:
#   • Adds azlux's APT repo + GPG key, with the Debian 13 Trixie pin
#     workaround for Debian bug #1122989 (buggy logrotate path in Debian's
#     own trixie log2ram package)
#   • Detects Pi-Apps "More RAM" (zram swap) before enabling Log2Ram's own
#     ZL2R zram-backing — notifies/confirms if not found, never silently
#     proceeds into a config that depends on missing infrastructure
#   • Configures /etc/log2ram.conf for zram-backed storage: ZL2R=true,
#     COMP_ALG=zstd, SIZE=128M (hard RAM ceiling), LOG_DISK_SIZE=256M
#     (logical capacity presented to the OS — paired for ~2:1 minimum
#     compression headroom, comfortably met by zstd's ~2.9:1 ratio)
#   • Optional journald drop-in (SystemMaxUse=20M, menu option 9 only — NOT
#     applied automatically) as a separate file rather than editing the main
#     journald.conf directly — fully reversible if ever used
#   • Pre-flight check of current /var/log size against the target RAM
#     disk capacity, with the documented du/journalctl --vacuum-size fix
#   • Rollback/crash recovery on install; clean, prompted uninstall
#   • System packages (rsync, e2fsprogs) retained on uninstall always
#
# Requirements:
#   - Raspberry Pi OS Trixie (Debian 13) arm64
#   - Internet connection for the azlux APT repo
#   - Pi-Apps "More RAM" (zram swap) strongly recommended before enabling
#     ZL2R — this script checks and warns if it's missing
#
# Usage:
#   chmod +x log2ram-manager.sh
#   ./log2ram-manager.sh
#
# Do NOT run as root. The script calls sudo internally only where needed.
#
# Disclaimer:
#   Provided as-is, free of charge, for Raspberry Pi users. Not affiliated
#   with azlux, the log2ram project, or Raspberry Pi Ltd. Use at your own risk.
# =============================================================================
#
# AI REFERENCE NOTES — log2ram-manager.sh
# Single source of truth. Read this block in full before making any changes.
#
# ── WHAT THIS SCRIPT DOES ─────────────────────────────────────────────────────
#   Installs azlux/log2ram via APT (azlux's own repo, not Debian's bundled
#   trixie package — see Trixie pin below), then configures it for
#   zram-backed, zstd-compressed log storage. Provides a terminal menu for
#   status, logs, guided config edits, forced sync, zram/More RAM prerequisite
#   checks, update checks, an optional (never automatic) journald SystemMaxUse
#   drop-in, and clean uninstall.
#
# ── WHY APT + AZLUX REPO, NOT DEBIAN'S BUNDLED PACKAGE ───────────────────────
#   Debian 13 Trixie ships log2ram 1.7.2+ds-1 in its own repos, BUT that
#   package has a confirmed bug (Debian #1122989): its logrotate config is
#   installed at /etc/logrotate.d/log2ram/log2ram.logrotate (a file inside a
#   SUBDIRECTORY), which logrotate silently ignores entirely. Upstream's own
#   README fix — and what this script implements — is to add azlux's repo
#   and pin it with Pin-Priority: 1001 so apt always prefers azlux's
#   (non-buggy) build over Debian's, on Trixie specifically.
#   Ref: https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1122989
#        https://github.com/azlux/log2ram/issues/264
#
# ── ZL2R / SIZE / LOG_DISK_SIZE — HOW THEY ACTUALLY RELATE ───────────────────
#   Confirmed by reading log2ram's actual source (createZramLogDrive()):
#     modprobe zram  (or grabs a free device via /sys/class/zram-control/hot_add)
#     echo "$COMP_ALG"     > /sys/block/zram$N/comp_algorithm
#     echo "$LOG_DISK_SIZE" > /sys/block/zram$N/disksize     # logical/uncompressed size presented to the OS (mke2fs'd as ext4)
#     echo "$SIZE"          > /sys/block/zram$N/mem_limit    # HARD ceiling on actual compressed RAM usage — never exceeded regardless of compression ratio
#   So with ZL2R=true: SIZE is the real RAM cost ceiling, LOG_DISK_SIZE is
#   the apparent filesystem capacity. They must be sized together: the ratio
#   LOG_DISK_SIZE/SIZE is the minimum compression ratio needed to actually
#   use the full logical capacity. Default conf ships SIZE=128M /
#   LOG_DISK_SIZE=256M (2:1 minimum) — easily met by zstd's ~2.9:1, lz4's
#   ~2.1:1. This script keeps that exact pairing.
#   ZL2R uses its OWN zram device via hot_add — it does NOT reuse or collide
#   with the zram swap devices Pi-Apps "More RAM" creates (those are
#   dedicated swap, separate /dev/zramN minor numbers). The precondition in
#   upstream's README ("configure a zram swap before enabling this option")
#   is really just "prove zram works on this kernel/board" — which Pi-Apps
#   More RAM already does. This script checks for zram-swap.service /
#   zram.sh / an active zram module as that proof, and prompts for
#   confirmation if none is found rather than blocking outright.
#   Ref: https://github.com/azlux/log2ram/blob/master/log2ram (source)
#        https://deepwiki.com/azlux/log2ram/3.1-ram-storage-options
#
# ── KEY PATHS (APT package layout, confirmed via Debian package file list) ───
#   /usr/bin/log2ram                              — main script/binary
#   /usr/lib/systemd/system/log2ram.service       — boot-time service
#   /usr/lib/systemd/system/log2ram-daily.{service,timer} — daily disk sync
#   /etc/log2ram.conf                             — config (edited by this script)
#   /etc/apt/sources.list.d/azlux.list            — azlux repo (added by this script)
#   /usr/share/keyrings/azlux-archive-keyring.gpg — azlux GPG key (added by this script)
#   /etc/apt/preferences.d/log2ram.pref           — Trixie pin (added by this script, Trixie only)
#   /etc/systemd/journald.conf.d/log2ram-journal-limit.conf — journald drop-in (added by this script)
#   /var/log/log2ram.log                          — log2ram's own log
#   $STATE_DIR (~/.local/share/log2ram-manager)   — rollback backups, user-owned
#
# ── PIPEWIRE / AUDIO SAFETY ───────────────────────────────────────────────────
#   Zero interaction with PipeWire or any audio subsystem. log2ram only
#   touches the /var/log mountpoint and journald's disk-usage limit. No
#   audio packages, no systemd --user services, no boot-time daemons beyond
#   log2ram's own (which long predates this Pi and is the documented,
#   intended use case — not an analogue to the shairport-sync/PipeWire
#   boot-daemon conflict).
#
# ── ENVIRONMENT ───────────────────────────────────────────────────────────────
#   Raspberry Pi 4, Pi OS Trixie (Debian 13 arm64), labwc Wayland compositor.
#   Pi-Apps "More RAM" (zram swap) + Pi-Apps Botspot ecosystem already in use.
#   Terminal-menu only — no GTK GUI, by explicit request (this is a sysadmin
#   utility run occasionally from a terminal, not an app launched repeatedly).
#
# ── UNINSTALL COMPLETENESS ────────────────────────────────────────────────────
#   Removes (always, after confirmation):
#     log2ram package itself (apt purge — takes /etc/log2ram.conf with it)
#     /etc/systemd/journald.conf.d/log2ram-journal-limit.conf, IF it exists
#     (+ journald restart) — only present at all if menu option 9 was ever
#     explicitly used; never created automatically
#   Removes (prompted separately — these are system-wide apt sources, not
#   just this app's files):
#     /etc/apt/sources.list.d/azlux.list
#     /usr/share/keyrings/azlux-archive-keyring.gpg
#     /etc/apt/preferences.d/log2ram.pref
#   Retained (never removed — shared system packages):
#     rsync, e2fsprogs — both are common, low-risk, useful to other tools
#
# ── VERSION HISTORY ───────────────────────────────────────────────────────────
#   v1.2.1 (2026-06-19) — Second audit pass. Found and fixed a real crash:
#     do_uninstall() deletes $STATE_DIR entirely, but the script loops back
#     to the menu afterward rather than exiting — so Uninstall followed by
#     Install/Reconfigure/Edit-config/journald-dropin in the SAME session
#     would hit _rollback_begin() trying to write into a directory that no
#     longer existed, crashing with a raw "No such file or directory" error.
#     Confirmed via an isolated test, fixed with a defensive `mkdir -p
#     "$STATE_DIR"` at the top of _rollback_begin(), re-verified the fix
#     resolves it. Also added journald drop-in state to show_status() for
#     visibility now that it's an independent opt-in toggle. Re-ran the full
#     syntax/shellcheck/rollback-simulation suite from v1.1.1 end to end to
#     confirm nothing regressed from the v1.2.0 opt-in refactor.
#   v1.2.0 (2026-06-19) — Made the journald SystemMaxUse drop-in fully opt-in
#     (new menu option 9, offer_journald_dropin()), removed entirely from the
#     automatic install/reconfigure flow. Decided after Kaleb shared his live,
#     already-working /etc/log2ram.conf and /etc/systemd/journald.conf:
#     log2ram.conf matched this script's targets almost exactly (SIZE=128M,
#     ZL2R=true, COMP_ALG=zstd, LOG_DISK_SIZE=256M — confirming this script's
#     defaults against a real running system, not just upstream docs), but
#     journald.conf turned out to be the untouched stock default (no
#     /etc/systemd/journald.conf.d/ directory existed at all) — meaning the
#     SystemMaxUse=20M Kaleb remembered setting wasn't actually active, yet
#     the system had run fine regardless. Kaleb's call: don't need it,
#     leave journald alone by default. The capability is kept, just no
#     longer assumed.
#   v1.1.1 (2026-06-19) — Full audit pass, requested before relying on this on
#     real hardware. Found and fixed a REAL bug: the EXIT trap read a
#     separate _EXIT_CODE variable that was only ever updated by an ERR
#     trap — but explicit `exit 1` calls (i.e. every error() call) don't
#     fire the ERR trap, so _EXIT_CODE stayed 0 and rollback silently took
#     the "clean success" branch on every error()-triggered failure,
#     skipping the restore entirely. Confirmed via isolated bash tests, then
#     fixed by reading `$?` directly in the EXIT trap (`trap '_rollback_cleanup
#     "$?"' EXIT`), then re-verified end-to-end with a full simulated failed
#     install against the real rollback functions (conf correctly restored,
#     created repo/keyring files correctly removed). Also fixed: the
#     "reconfigure only" and "edit config" paths weren't wrapped in
#     _rollback_begin/_rollback_end, which could leave stale CREATED_*_FLAG
#     files that a later, unrelated failed install could misread as
#     "created this session" and wrongly delete — now wrapped consistently,
#     and _rollback_begin() also defensively clears stale flags up front.
#     configure_log2ram_conf() now refreshes the rollback-tracked backup
#     itself (not just once in _rollback_begin, before the file may even
#     exist on a fresh install). detect_codename() now sources os-release in
#     a subshell to avoid leaking NAME/ID/etc. into global scope. Downgraded
#     error() (whole-script exit) to warn() in force_sync()/check_for_updates(),
#     and guarded a couple of unguarded pipes in show_logs()/check_var_log_size()
#     — diagnostic/utility menu options should never be able to kill the
#     whole interactive session; only the active rollback-wrapped install
#     phase should. Re-verified config key names/defaults (SIZE=128M,
#     ZL2R=false, COMP_ALG=lz4, LOG_DISK_SIZE=256M, JOURNALD_AWARE=true,
#     #USE_RSYNC commented) directly against the current upstream
#     log2ram.conf — all sed targets confirmed correct, and the
#     SIZE=128M/LOG_DISK_SIZE=256M pairing this script applies turns out to
#     be upstream's own unmodified shipped default, not just a derived
#     guess. Also confirmed `systemctl reload log2ram` -> `log2ram write`
#     directly against the actual systemd unit (this is also what
#     log2ram-daily.service itself calls), so force_sync() is accurate.
#   v1.1.0 (2026-06-19) — Added ensure_zram_prereq(): when "More RAM" isn't
#     detected during install, offers to install Pi-Apps itself (if missing)
#     then "More RAM" via `~/pi-apps/manage install-if-not-installed "More RAM"`
#     — the same idempotent CLI mode Pi-Apps uses internally for app
#     dependencies (e.g. Wine -> Box86). Re-checks zram after each step;
#     only falls back to a manual "continue anyway?" prompt if installation
#     wasn't accepted or didn't take. Same offer added to the standalone
#     "Check zram / More RAM" menu option. Confirmed via Pi-Apps' own CLI
#     docs (pi-apps.io/wiki) and the More RAM install script source that
#     this applies immediately, no reboot required.
#   v1.0.0 (2026-06-19) — Initial build. Researched against upstream README,
#     actual log2ram source script, Debian bug #1122989, and Botspot's
#     "More RAM" install script before writing any code. ZL2R+zstd,
#     SIZE=128M/LOG_DISK_SIZE=256M, journald SystemMaxUse=20M drop-in,
#     terminal-menu only (no GTK), per explicit user decisions.
#
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# CONSTANTS
# =============================================================================
SCRIPT_NAME="log2ram-manager.sh"
APP_VERSION="1.2.1"

UPSTREAM_URL="https://github.com/azlux/log2ram"
PI_APPS_DIR="$HOME/pi-apps"

LOG2RAM_CONF="/etc/log2ram.conf"
AZLUX_KEYRING="/usr/share/keyrings/azlux-archive-keyring.gpg"
AZLUX_LIST="/etc/apt/sources.list.d/azlux.list"
AZLUX_PIN="/etc/apt/preferences.d/log2ram.pref"
JOURNALD_DROPIN_DIR="/etc/systemd/journald.conf.d"
JOURNALD_DROPIN="$JOURNALD_DROPIN_DIR/log2ram-journal-limit.conf"

# Target config values this script configures log2ram for.
TARGET_SIZE="128M"
TARGET_LOG_DISK_SIZE="256M"
TARGET_COMP_ALG="zstd"
TARGET_SYSTEMMAXUSE="20M"

STATE_DIR="$HOME/.local/share/log2ram-manager"
PARTIAL_MARKER="$STATE_DIR/install.partial"
BACKUP_CONF="$STATE_DIR/log2ram.conf.backup"
CREATED_LIST_FLAG="$STATE_DIR/.created_azlux_list"
CREATED_KEYRING_FLAG="$STATE_DIR/.created_azlux_keyring"
CREATED_PIN_FLAG="$STATE_DIR/.created_azlux_pin"
CREATED_DROPIN_FLAG="$STATE_DIR/.created_journald_dropin"
mkdir -p "$STATE_DIR"

# =============================================================================
# COLOURS
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# =============================================================================
# HELPERS
# =============================================================================
info()  { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
step()  { echo -e "\n${BOLD}${CYAN}==> $*${RESET}"; }

require_no_root() {
    if [[ "$EUID" -eq 0 ]]; then
        error "Do not run this script as root. Run as your normal Pi user — it calls sudo internally where needed."
    fi
}

is_installed() {
    command -v log2ram >/dev/null 2>&1 || dpkg -s log2ram >/dev/null 2>&1
}

log2ram_service_active() {
    systemctl is-active --quiet log2ram 2>/dev/null
}

# =============================================================================
# ROLLBACK / CRASH RECOVERY
# Mirrors the pattern used in cava-manager.sh / adarkroom-manager.sh:
# a partial marker + backups in $STATE_DIR, restored on any non-zero exit
# during an active operation. Newly-created files (which have no "before"
# state) are tracked via flag files and simply deleted on rollback.
# =============================================================================
_ROLLBACK_OP=""

_rollback_cleanup() {
    local exit_code="${1:-0}"
    local op="$_ROLLBACK_OP"

    if [[ -f "$PARTIAL_MARKER" && "$exit_code" -ne 0 ]]; then
        warn "Operation '${op}' did not complete — rolling back changes..."

        if [[ -f "$BACKUP_CONF" ]]; then
            sudo cp -f "$BACKUP_CONF" "$LOG2RAM_CONF" \
                && info "Restored: $LOG2RAM_CONF" \
                || warn "Could not restore $LOG2RAM_CONF — check it manually."
            rm -f "$BACKUP_CONF"
        fi

        if [[ -f "$CREATED_LIST_FLAG" && -f "$AZLUX_LIST" ]]; then
            sudo rm -f "$AZLUX_LIST" && info "Removed: $AZLUX_LIST"
        fi
        if [[ -f "$CREATED_KEYRING_FLAG" && -f "$AZLUX_KEYRING" ]]; then
            sudo rm -f "$AZLUX_KEYRING" && info "Removed: $AZLUX_KEYRING"
        fi
        if [[ -f "$CREATED_PIN_FLAG" && -f "$AZLUX_PIN" ]]; then
            sudo rm -f "$AZLUX_PIN" && info "Removed: $AZLUX_PIN"
        fi
        if [[ -f "$CREATED_DROPIN_FLAG" && -f "$JOURNALD_DROPIN" ]]; then
            sudo rm -f "$JOURNALD_DROPIN" && info "Removed: $JOURNALD_DROPIN"
        fi

        rm -f "$PARTIAL_MARKER" "$CREATED_LIST_FLAG" "$CREATED_KEYRING_FLAG" \
              "$CREATED_PIN_FLAG" "$CREATED_DROPIN_FLAG"
        echo ""
        warn "Rollback complete. Fix the issue above, then run this script again."

    elif [[ -f "$PARTIAL_MARKER" && "$exit_code" -eq 0 ]]; then
        rm -f "$PARTIAL_MARKER" "$BACKUP_CONF" "$CREATED_LIST_FLAG" \
              "$CREATED_KEYRING_FLAG" "$CREATED_PIN_FLAG" "$CREATED_DROPIN_FLAG"
    fi
}

trap '_rollback_cleanup "$?"' EXIT
trap 'echo ""; warn "Interrupted."; exit 130' INT TERM HUP

_rollback_begin() {
    _ROLLBACK_OP="$1"
    # STATE_DIR may have been deleted by a prior Uninstall earlier in this
    # same session (the script loops back to the menu rather than exiting),
    # so recreate it defensively before relying on it existing.
    mkdir -p "$STATE_DIR"
    # Defensively clear any stale flags from a prior session before this
    # operation creates its own — a leftover flag here would otherwise be
    # mistaken for "created this session" if this operation later fails.
    rm -f "$CREATED_LIST_FLAG" "$CREATED_KEYRING_FLAG" "$CREATED_PIN_FLAG" "$CREATED_DROPIN_FLAG"
    echo "$1" > "$PARTIAL_MARKER"
    if [[ -f "$LOG2RAM_CONF" ]]; then
        sudo cp -f "$LOG2RAM_CONF" "$BACKUP_CONF"
        info "Config backed up for rollback: $BACKUP_CONF"
    fi
}

_rollback_end() {
    _ROLLBACK_OP=""
    rm -f "$PARTIAL_MARKER" "$BACKUP_CONF" "$CREATED_LIST_FLAG" \
          "$CREATED_KEYRING_FLAG" "$CREATED_PIN_FLAG" "$CREATED_DROPIN_FLAG"
}

# =============================================================================
# DETECTION HELPERS
# =============================================================================

detect_codename() {
    (
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "${VERSION_CODENAME:-unknown}"
    )
}

detect_more_ram() {
    # Returns 0 (true) if Pi-Apps "More RAM" (or any working zram setup)
    # appears to be present. Checks multiple independent signals since
    # Pi-Apps doesn't install a single canonical marker file.
    local found=1
    systemctl is-enabled --quiet zram-swap.service 2>/dev/null && found=0
    systemctl is-active  --quiet zram-swap.service 2>/dev/null && found=0
    [[ -x /usr/bin/zram.sh ]] && found=0
    if command -v zramctl >/dev/null 2>&1; then
        zramctl --noheadings 2>/dev/null | grep -q . && found=0
    fi
    lsmod 2>/dev/null | grep -q '^zram' && found=0
    return "$found"
}

detect_pi_apps() {
    [[ -x "$PI_APPS_DIR/manage" ]] || command -v pi-apps >/dev/null 2>&1
}

install_pi_apps() {
    # Official one-line installer. Ref: https://github.com/Botspot/pi-apps
    step "Installing Pi-Apps"
    if wget -qO- https://raw.githubusercontent.com/Botspot/pi-apps/master/install | bash; then
        if [[ -x "$PI_APPS_DIR/manage" ]]; then
            ok "Pi-Apps installed."
            return 0
        fi
    fi
    warn "Pi-Apps install did not complete as expected — $PI_APPS_DIR/manage not found."
    return 1
}

install_more_ram() {
    # install-if-not-installed is the same idempotent mode Pi-Apps itself
    # uses internally when one app depends on another (e.g. Wine -> Box86).
    # Ref: https://pi-apps.io/wiki/getting-started/command-line-interface/
    step "Installing 'More RAM' via Pi-Apps"
    if "$PI_APPS_DIR/manage" install-if-not-installed "More RAM"; then
        ok "'More RAM' install command completed."
        return 0
    fi
    warn "'More RAM' install command reported a failure — you can also install it"
    warn "manually from the Pi-Apps GUI (Tools category)."
    return 1
}

ensure_zram_prereq() {
    # Returns 0 if it's safe to proceed with ZL2R (zram confirmed, or the
    # user explicitly chose to proceed without it). Returns 1 to abort.
    if detect_more_ram; then
        ok "Detected zram (Pi-Apps 'More RAM' or equivalent) — ZL2R prerequisite satisfied."
        return 0
    fi

    warn "Could not detect Pi-Apps 'More RAM' (zram-swap.service / zram.sh / an active"
    warn "zram module). log2ram's ZL2R zram-backing relies on zram already working on"
    warn "this kernel — upstream explicitly recommends having a zram swap configured"
    warn "first. (Ref: https://github.com/systemd/zram-generator, linked from the"
    warn "log2ram README's ZL2R section.)"
    echo ""

    if ! detect_pi_apps; then
        warn "Pi-Apps itself isn't installed either."
        read -rp "  Install Pi-Apps, then 'More RAM', now? [y/N]: " yn
        if [[ "$yn" =~ ^[Yy]$ ]]; then
            install_pi_apps || true
        fi
        echo ""
    fi

    if detect_pi_apps && ! detect_more_ram; then
        read -rp "  Install 'More RAM' through Pi-Apps now? [y/N]: " yn
        if [[ "$yn" =~ ^[Yy]$ ]]; then
            install_more_ram || true
        fi
        echo ""
    fi

    if detect_more_ram; then
        ok "'More RAM' is active — continuing."
        return 0
    fi

    warn "zram still not detected."
    read -rp "  Continue with ZL2R anyway, without a confirmed zram setup? [y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]]
}

check_var_log_size() {
    # Pre-flight check: warn if current /var/log usage is already close to
    # (or over) the RAM disk capacity we're about to configure. With
    # ZL2R=true, the relevant ceiling is LOG_DISK_SIZE (the logical
    # capacity), not SIZE — confirmed from log2ram's own source (TP_SIZE
    # is set to LOG_DISK_SIZE when ZL2R=true before the size-check du call).
    local target_mb threshold_mb current_kb current_mb
    target_mb=$(grep -oE '[0-9]+' <<< "$TARGET_LOG_DISK_SIZE")
    threshold_mb=$(( target_mb * 70 / 100 ))
    current_kb=$(sudo du -sk /var/log 2>/dev/null | cut -f1)
    current_mb=$(( current_kb / 1024 ))

    if (( current_mb >= threshold_mb )); then
        warn "/var/log is currently ~${current_mb}M — that's over 70% of the"
        warn "planned ${TARGET_LOG_DISK_SIZE} RAM disk capacity. log2ram can fail to"
        warn "start if /var/log is too large on first run."
        echo ""
        info "Largest items in /var/log right now:"
        sudo du -hs /var/log/* 2>/dev/null | sort -h | tail -n 3 | sed 's/^/    /' || true
        echo ""
        if sudo du -sh /var/log/journal 2>/dev/null | grep -q .; then
            info "If /var/log/journal is the culprit, you can shrink it now with:"
            echo "    sudo journalctl --vacuum-size=32M"
            echo ""
        fi
        read -rp "  Continue anyway? [y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] || return 1
    else
        ok "/var/log size (~${current_mb}M) is well within the planned ${TARGET_LOG_DISK_SIZE} capacity."
    fi
    return 0
}

# =============================================================================
# INSTALL
# =============================================================================
do_install() {
    if is_installed; then
        warn "log2ram already appears to be installed."
        echo ""
        echo "  1) Reconfigure settings only (re-apply SIZE/ZL2R/COMP_ALG/LOG_DISK_SIZE)"
        echo "  2) Full reinstall (apt reinstall log2ram, then reconfigure)"
        echo "  3) Cancel"
        read -rp "  Choose [1-3]: " sub
        case "$sub" in
            1)
                _rollback_begin "reconfigure"
                configure_log2ram_conf
                _rollback_end
                print_install_summary
                return
                ;;
            2) ;; # fall through to full install below
            *) info "Cancelled."; return ;;
        esac
    fi

    step "Pre-flight checks"
    check_var_log_size || { info "Install cancelled — shrink /var/log first, then re-run."; return; }

    echo ""
    ensure_zram_prereq || { info "Install cancelled. Install Pi-Apps 'More RAM' first, then re-run this script."; return; }

    local codename
    codename=$(detect_codename)
    info "Detected Debian/Pi OS codename: ${codename}"

    _rollback_begin "install"

    # -- Add azlux repo + key --------------------------------------------------
    step "Adding azlux APT repo + GPG key"
    if [[ ! -f "$AZLUX_KEYRING" ]]; then
        sudo wget -q -O "$AZLUX_KEYRING" https://azlux.fr/repo.gpg \
            || error "Failed to download azlux's GPG key. Check your internet connection."
        touch "$CREATED_KEYRING_FLAG"
        ok "GPG key installed: $AZLUX_KEYRING"
    else
        info "GPG key already present: $AZLUX_KEYRING"
    fi

    if [[ ! -f "$AZLUX_LIST" ]]; then
        echo "deb [signed-by=${AZLUX_KEYRING}] http://packages.azlux.fr/debian/ ${codename} main" \
            | sudo tee "$AZLUX_LIST" >/dev/null
        touch "$CREATED_LIST_FLAG"
        ok "Repo added: $AZLUX_LIST"
    else
        info "Repo already present: $AZLUX_LIST"
    fi

    # -- Trixie pin workaround for Debian bug #1122989 -------------------------
    if [[ "$codename" == "trixie" ]]; then
        if [[ ! -f "$AZLUX_PIN" ]]; then
            step "Applying Trixie pin (Debian bug #1122989 workaround)"
            sudo tee "$AZLUX_PIN" >/dev/null <<EOF
Package: log2ram
Pin: origin packages.azlux.fr
Pin-Priority: 1001
EOF
            touch "$CREATED_PIN_FLAG"
            ok "Pin applied: azlux's log2ram build will take priority over Debian's bundled package."
        else
            info "Trixie pin already present: $AZLUX_PIN"
        fi
    fi

    # -- Install -----------------------------------------------------------------
    step "Installing log2ram (+ rsync, e2fsprogs)"
    sudo apt update || error "apt update failed. Check the repo/network and try again."
    sudo apt install -y log2ram rsync e2fsprogs \
        || error "apt install failed. See the error above."
    ok "Package installed."

    [[ -f "$LOG2RAM_CONF" ]] || error "Install reported success but $LOG2RAM_CONF is missing — something's wrong."

    # -- Configure ---------------------------------------------------------------
    configure_log2ram_conf

    _rollback_end
    print_install_summary
}

configure_log2ram_conf() {
    step "Configuring $LOG2RAM_CONF"
    [[ -f "$LOG2RAM_CONF" ]] || error "$LOG2RAM_CONF not found — install log2ram first."

    sudo cp -f "$LOG2RAM_CONF" "${LOG2RAM_CONF}.pre-manager.bak" 2>/dev/null || true
    # Also refresh the rollback-tracked backup here (not just in _rollback_begin),
    # since on a fresh install this file doesn't exist yet when _rollback_begin
    # runs — this is the copy _rollback_cleanup actually restores from.
    sudo cp -f "$LOG2RAM_CONF" "$BACKUP_CONF" 2>/dev/null || true

    sudo sed -i \
        -e "s/^SIZE=.*/SIZE=${TARGET_SIZE}/" \
        -e "s/^ZL2R=.*/ZL2R=true/" \
        -e "s/^COMP_ALG=.*/COMP_ALG=${TARGET_COMP_ALG}/" \
        -e "s/^LOG_DISK_SIZE=.*/LOG_DISK_SIZE=${TARGET_LOG_DISK_SIZE}/" \
        "$LOG2RAM_CONF"

    # JOURNALD_AWARE must be true for the journald-rotation-before-sync logic
    # to run at all (and it requires rsync, which we just ensured is installed).
    if grep -q "^JOURNALD_AWARE=" "$LOG2RAM_CONF"; then
        sudo sed -i "s/^JOURNALD_AWARE=.*/JOURNALD_AWARE=true/" "$LOG2RAM_CONF"
    fi

    ok "SIZE=${TARGET_SIZE}  ZL2R=true  COMP_ALG=${TARGET_COMP_ALG}  LOG_DISK_SIZE=${TARGET_LOG_DISK_SIZE}"
    info "A pre-edit backup was kept at: ${LOG2RAM_CONF}.pre-manager.bak"

    if log2ram_service_active; then
        info "Restarting log2ram to apply new config..."
        sudo systemctl restart log2ram \
            && ok "log2ram restarted." \
            || warn "Restart failed — a reboot will apply the new config instead."
    fi
}

configure_journald_dropin() {
    step "Adding journald drop-in (SystemMaxUse=${TARGET_SYSTEMMAXUSE})"
    if [[ -f "$JOURNALD_DROPIN" ]]; then
        info "Drop-in already present: $JOURNALD_DROPIN"
    else
        sudo mkdir -p "$JOURNALD_DROPIN_DIR"
        sudo tee "$JOURNALD_DROPIN" >/dev/null <<EOF
# Added by log2ram-manager.sh — keeps /var/log/journal from outgrowing
# log2ram's RAM disk. Value must stay smaller than log2ram's SIZE setting.
# Reversible: delete this file and run 'sudo systemctl restart systemd-journald'.
[Journal]
SystemMaxUse=${TARGET_SYSTEMMAXUSE}
EOF
        touch "$CREATED_DROPIN_FLAG"
        ok "Drop-in created: $JOURNALD_DROPIN"
    fi
    sudo systemctl restart systemd-journald \
        && ok "systemd-journald restarted." \
        || warn "Could not restart systemd-journald — it will pick up the limit on next boot."
}

offer_journald_dropin() {
    step "journald SystemMaxUse cap (optional)"
    if [[ -f "$JOURNALD_DROPIN" ]]; then
        ok "Already present: $JOURNALD_DROPIN"
        return
    fi
    info "This is NOT applied automatically by Install/Repair — it's only added if you"
    info "explicitly choose it here. Your existing journald.conf will not be touched"
    info "either way; this adds a separate drop-in file instead."
    echo ""
    read -rp "  Add a SystemMaxUse=${TARGET_SYSTEMMAXUSE} journald drop-in now? [y/N]: " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        _rollback_begin "journald-dropin"
        configure_journald_dropin
        _rollback_end
    else
        info "Skipped — no changes made."
    fi
}

print_install_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}║          log2ram configured successfully!            ║${RESET}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  Config:  ${CYAN}$LOG2RAM_CONF${RESET}  (SIZE=${TARGET_SIZE}, ZL2R=true, COMP_ALG=${TARGET_COMP_ALG}, LOG_DISK_SIZE=${TARGET_LOG_DISK_SIZE})"
    echo ""
    info "journald's SystemMaxUse cap was NOT touched — your existing journald.conf is left exactly as-is."
    info "(Available separately from the main menu if you ever want it: option 9.)"
    echo ""
    echo -e "  ${YELLOW}Upstream recommends a REBOOT before installing anything else${RESET}"
    echo -e "  ${YELLOW}that writes logs heavily, so the RAM disk is fully active first.${RESET}"
    echo ""
    read -rp "  Reboot now? [y/N]: " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        info "Rebooting..."
        sudo reboot
    else
        info "Okay — reboot manually when convenient: sudo reboot"
        info "After reboot, check status from this menu (option 3)."
    fi
    echo ""
}

# =============================================================================
# UNINSTALL
# =============================================================================
do_uninstall() {
    step "Uninstalling log2ram"

    if ! is_installed; then
        warn "log2ram doesn't appear to be installed — checking for leftover files anyway."
    else
        sudo systemctl stop log2ram 2>/dev/null || true
        sudo apt purge -y log2ram \
            && ok "Package purged (config removed with it)." \
            || warn "apt purge reported an issue — check 'dpkg -l | grep log2ram' manually."
    fi

    if [[ -f "${LOG2RAM_CONF}.pre-manager.bak" ]]; then
        sudo rm -f "${LOG2RAM_CONF}.pre-manager.bak"
        ok "Removed leftover backup: ${LOG2RAM_CONF}.pre-manager.bak"
    fi

    if [[ -f "$JOURNALD_DROPIN" ]]; then
        sudo rm -f "$JOURNALD_DROPIN"
        sudo systemctl restart systemd-journald 2>/dev/null || true
        ok "Removed journald drop-in: $JOURNALD_DROPIN"
    fi

    if mount | grep -q log2ram; then
        warn "A log2ram mount is still active on /var/log — a reboot will clear it."
    fi

    echo ""
    if [[ -f "$AZLUX_LIST" || -f "$AZLUX_KEYRING" || -f "$AZLUX_PIN" ]]; then
        echo -e "${YELLOW}The azlux APT repo, its GPG key, and the Trixie pin are still on your${RESET}"
        echo -e "${YELLOW}system. These are system-wide apt sources, not just log2ram's files —${RESET}"
        echo -e "${YELLOW}removing them is optional and only matters if you don't plan to use any${RESET}"
        echo -e "${YELLOW}other azlux-packaged software.${RESET}"
        echo ""
        read -rp "  Remove the azlux apt repo, GPG key, and Trixie pin too? [y/N]: " yn
        if [[ "$yn" =~ ^[Yy]$ ]]; then
            [[ -f "$AZLUX_LIST" ]]    && sudo rm -f "$AZLUX_LIST"    && ok "Removed: $AZLUX_LIST"
            [[ -f "$AZLUX_KEYRING" ]] && sudo rm -f "$AZLUX_KEYRING" && ok "Removed: $AZLUX_KEYRING"
            [[ -f "$AZLUX_PIN" ]]     && sudo rm -f "$AZLUX_PIN"     && ok "Removed: $AZLUX_PIN"
            sudo apt update || true
        else
            info "Repo, key, and pin retained."
        fi
    fi

    rm -rf "$STATE_DIR"

    echo ""
    echo -e "${GREEN}${BOLD}log2ram uninstalled.${RESET}"
    echo -e "  ${CYAN}Note:${RESET} rsync and e2fsprogs were retained — removing them could"
    echo -e "         break other Pi OS tools that depend on them."
    echo ""
}

# =============================================================================
# STATUS / LOGS / EDIT / SYNC / UPDATE CHECK
# =============================================================================
show_status() {
    step "log2ram status"
    if ! is_installed; then
        warn "log2ram is not installed."
        return
    fi
    systemctl status log2ram --no-pager 2>/dev/null || true
    echo ""
    info "RAM disk mount info:"
    df -hT 2>/dev/null | grep -i log2ram | sed 's/^/    /' || warn "  No log2ram mount found — has it been rebooted since install?"
    echo ""
    info "Mount options:"
    mount 2>/dev/null | grep -i log2ram | sed 's/^/    /' || true
    echo ""
    if command -v zramctl >/dev/null 2>&1; then
        info "All zram devices on this system (More RAM swap + log2ram's own device):"
        zramctl 2>/dev/null | sed 's/^/    /' || true
    fi
    echo ""
    info "Current config ($LOG2RAM_CONF):"
    grep -E '^(SIZE|ZL2R|COMP_ALG|LOG_DISK_SIZE|JOURNALD_AWARE)=' "$LOG2RAM_CONF" 2>/dev/null | sed 's/^/    /' || true
    echo ""
    if [[ -f "$JOURNALD_DROPIN" ]]; then
        info "journald SystemMaxUse cap: active ($JOURNALD_DROPIN)"
    else
        info "journald SystemMaxUse cap: not set (optional — menu option 9)"
    fi
}

show_logs() {
    step "log2ram logs"
    if ! is_installed; then
        warn "log2ram is not installed."
        return
    fi
    info "Recent journal entries (press q to exit):"
    journalctl -u log2ram -e --no-pager -n 50 2>/dev/null || true
    echo ""
    if [[ -f /var/log/log2ram.log ]]; then
        info "Tail of /var/log/log2ram.log:"
        sudo tail -n 30 /var/log/log2ram.log 2>/dev/null | sed 's/^/    /' || true
    fi
}

edit_config() {
    step "Edit log2ram config"
    if ! is_installed; then
        warn "log2ram is not installed."
        return
    fi
    echo "  1) Re-apply this script's recommended settings (ZL2R+zstd, ${TARGET_SIZE}/${TARGET_LOG_DISK_SIZE})"
    echo "  2) Open $LOG2RAM_CONF directly in nano"
    echo "  3) Cancel"
    read -rp "  Choose [1-3]: " sub
    case "$sub" in
        1)
            _rollback_begin "edit-config"
            configure_log2ram_conf
            _rollback_end
            ;;
        2)
            sudo cp -f "$LOG2RAM_CONF" "$BACKUP_CONF" 2>/dev/null || true
            sudo nano "$LOG2RAM_CONF"
            info "Edited. Restart log2ram to apply: sudo systemctl restart log2ram"
            ;;
        *) info "Cancelled." ;;
    esac
}

force_sync() {
    step "Forcing a write-to-disk sync now"
    if ! is_installed; then
        warn "log2ram is not installed."
        return
    fi
    sudo systemctl reload log2ram \
        && ok "Sync triggered (ExecReload runs 'log2ram write')." \
        || warn "Reload failed — check 'systemctl status log2ram'."
}

check_zram_status() {
    step "More RAM / zram prerequisite check"
    if detect_more_ram; then
        ok "zram appears active on this system."
        echo ""
        if command -v zramctl >/dev/null 2>&1; then
            info "zramctl output:"
            zramctl 2>/dev/null | sed 's/^/    /' || true
        fi
        return
    fi

    warn "No zram-swap.service, zram.sh, or active zram module detected."
    warn "Install Pi-Apps 'More RAM' before relying on log2ram's ZL2R zram-backing."
    echo ""

    if ! detect_pi_apps; then
        read -rp "  Pi-Apps isn't installed either. Install Pi-Apps, then 'More RAM', now? [y/N]: " yn
        if [[ "$yn" =~ ^[Yy]$ ]]; then
            install_pi_apps || true
        fi
        echo ""
    fi

    if detect_pi_apps && ! detect_more_ram; then
        read -rp "  Install 'More RAM' through Pi-Apps now? [y/N]: " yn
        if [[ "$yn" =~ ^[Yy]$ ]]; then
            install_more_ram || true
        fi
        echo ""
    fi

    if detect_more_ram; then
        ok "'More RAM' is now active."
    else
        info "Still not detected — install it from the Pi-Apps GUI (Tools category) when ready."
    fi
}

check_for_updates() {
    step "Checking for log2ram updates"
    if ! is_installed; then
        warn "log2ram is not installed."
        return
    fi
    sudo apt update || { warn "apt update failed."; return; }
    if apt list --upgradable 2>/dev/null | grep -qi log2ram; then
        ok "An update is available:"
        apt list --upgradable 2>/dev/null | grep -i log2ram | sed 's/^/    /'
        echo ""
        read -rp "  Upgrade now? [y/N]: " yn
        if [[ "$yn" =~ ^[Yy]$ ]]; then
            sudo apt install -y --only-upgrade log2ram \
                && ok "Upgraded." \
                || warn "Upgrade failed."
        fi
    else
        ok "log2ram is up to date."
    fi
}

# =============================================================================
# MAIN MENU
# =============================================================================
main_menu() {
    clear
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║          LOG2RAM — Manager Script v${APP_VERSION}              ║${RESET}"
    echo -e "${BOLD}${CYAN}║          RAM-backed /var/log, zram + zstd             ║${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  Upstream: ${CYAN}${UPSTREAM_URL}${RESET}"
    echo ""

    if is_installed; then
        if log2ram_service_active; then
            echo -e "  Status: ${GREEN}${BOLD}Installed & active${RESET}"
        else
            echo -e "  Status: ${YELLOW}${BOLD}Installed, not active${RESET} (reboot may be needed)"
        fi
    else
        echo -e "  Status: ${YELLOW}Not installed${RESET}"
    fi

    echo ""
    echo -e "  ${BOLD}1)${RESET} Install / Repair"
    echo -e "  ${BOLD}2)${RESET} Uninstall"
    echo -e "  ${BOLD}3)${RESET} Status & RAM disk info"
    echo -e "  ${BOLD}4)${RESET} View logs"
    echo -e "  ${BOLD}5)${RESET} Edit config"
    echo -e "  ${BOLD}6)${RESET} Force write-to-disk sync now"
    echo -e "  ${BOLD}7)${RESET} Check zram / More RAM prerequisite"
    echo -e "  ${BOLD}8)${RESET} Check for updates"
    echo -e "  ${BOLD}9)${RESET} Add journald SystemMaxUse cap (optional, not applied automatically)"
    echo -e "  ${BOLD}Q)${RESET} Quit"
    echo ""
    read -rp "  Select an option: " choice

    case "$choice" in
        1) do_install ;;
        2) do_uninstall ;;
        3) show_status ;;
        4) show_logs ;;
        5) edit_config ;;
        6) force_sync ;;
        7) check_zram_status ;;
        8) check_for_updates ;;
        9) offer_journald_dropin ;;
        [Qq])
            echo ""
            info "Goodbye!"
            echo ""
            exit 0
            ;;
        *)
            warn "Invalid option: $choice"
            ;;
    esac
}

# =============================================================================
# ENTRY POINT
# =============================================================================
require_no_root

while true; do
    main_menu
    echo ""
    read -rp "Press Enter to return to the menu..." _
done

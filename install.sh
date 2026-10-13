#!/usr/bin/env bash
#
# macospills — one-command installer for the GNOME backend.
#
# Usage:
#   ./install.sh
#
# What it does:
#   1. Copies gnome/macospills@ali120b.github.io to
#      ~/.local/share/gnome-shell/extensions/<uuid>
#   2. Compiles the gsettings schema (toggle-layout accelerator)
#   3. Removes the retired layout-toggle.sh media-keys binding
#      (it would double-fire with the extension)
#   4. Enables the extension with gnome-extensions
#   5. Checks input sources + caps-lock LED, warns if broken
#
# Then it asks you to LOG OUT and back in (Wayland has no shell
# restart, and disable/enable does not reload extension code).
#
# Needs sudo (password prompt) ONLY to install a missing dependency
# (glib2 → glib-compile-schemas). Everything else is per-user.

set -euo pipefail

UUID="macospills@ali120b.github.io"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/gnome/$UUID"
DST="$HOME/.local/share/gnome-shell/extensions/$UUID"

# --- pretty output -------------------------------------------------
if [[ -t 1 ]]; then
    C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
else
    C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""; C_RESET=""
fi
info() { printf "%s==>%s %s\n" "$C_BOLD" "$C_RESET" "$*"; }
ok()   { printf "%sOK%s  %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "%sWARN%s %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail() { printf "%sFAIL%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Run a command as root, prompting for the password only when needed.
# Usage: need_root <command> [args...]
need_root() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        "$@"
    elif have sudo; then
        sudo --prompt="[sudo] password for %u (needed to install $1): " "$@"
    elif have pkexec; then
        pkexec "$@"
    else
        return 1
    fi
}

install_pkg() {
    # $1 = apt|dnf|pacman|zypper package name, rest = managers already tried message
    local pkg="$1"
    info "Missing dependency, trying to install '$pkg' (may ask for your password)…"
    if have apt-get; then
        need_root apt-get update && need_root apt-get install -y "$pkg"
    elif have dnf; then
        need_root dnf install -y "$pkg"
    elif have pacman; then
        need_root pacman -Sy --noconfirm "$pkg"
    elif have zypper; then
        need_root zypper install -yn "$pkg"
    else
        return 1
    fi
}

echo "${C_BOLD}macospills GNOME installer${C_RESET}"

# --- 0. sanity ------------------------------------------------------
[[ -d "$SRC" ]] || fail "Extension source not found: $SRC (run $0 from the repo root)"
[[ -f "$SRC/metadata.json" ]] || fail "Broken checkout: $SRC/metadata.json missing"
[[ -f "$SRC/schemas/org.gnome.shell.extensions.macospills.gschema.xml" ]] \
    || fail "Broken checkout: toggle-layout schema missing"

if ! have gnome-shell && ! have gnome-extensions; then
    warn "No GNOME Shell detected. This installer is GNOME-only — KDE/Hyprland use other backends."
    warn "Continuing anyway; the extension will only work under GNOME 50/51."
fi

# Shell-version compatibility (advisory only)
if have gnome-shell; then
    SHELL_VER="$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
    if [[ -n "${SHELL_VER:-}" ]]; then
        if grep -q "\"$SHELL_VER\"" "$SRC/metadata.json"; then
            ok "GNOME Shell $SHELL_VER supported."
        else
            warn "GNOME Shell $SHELL_VER is not listed in metadata.json (supports: $(grep -o '"shell-version":[^]]*]' "$SRC/metadata.json")). It may still work — continuing."
        fi
    fi
fi

# --- 1. dependencies ------------------------------------------------
for cmd in gsettings gnome-extensions; do
    have "$cmd" || fail "Required command '$cmd' not found. Install GNOME Shell first."
done

if ! have glib-compile-schemas; then
    warn "'glib-compile-schemas' not found (package: glib2)."
    if ! install_pkg glib2; then
        fail "Could not install glib2 automatically. Install it yourself, e.g.:
  Fedora:  sudo dnf install -y glib2
  Ubuntu:  sudo apt-get install -y libglib2.0-bin
  Arch:    sudo pacman -S --noconfirm glib2
  openSUSE: sudo zypper install -n glib2-tools"
    fi
    have glib-compile-schemas || fail "'glib-compile-schemas' still missing after installing glib2."
fi
ok "Dependencies present."

# --- 2. copy extension ----------------------------------------------
info "Installing extension to $DST …"
mkdir -p "$(dirname "$DST")"
rm -rf "$DST"
cp -r "$SRC" "$DST"
# Never ship a stale compiled schema from the checkout.
rm -f "$DST/schemas/gschemas.compiled"
ok "Files copied."

# --- 3. compile schemas ----------------------------------------------
info "Compiling gsettings schema (Ctrl+Shift+Space binding) …"
glib-compile-schemas "$DST/schemas"
[[ -f "$DST/schemas/gschemas.compiled" ]] || fail "Schema compile produced no output."
ok "Schema compiled."

# --- 4. remove retired toggle binding --------------------------------
# layout-toggle.sh used to add a media-keys custom binding that wrote the
# DEPRECATED org.gnome.desktop.input-sources `current` key (switches
# nothing) — and it would double-fire with the extension's in-process
# Ctrl+Shift+Space handler. Remove any such leftover.
info "Checking for the retired layout-toggle.sh keybinding …"
REMOVED=0
CURRENT_LIST="$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null || echo "@as []")"
# Iterate every custom binding path, drop ones named 'Toggle input source'.
CUSTOM_PATHS="$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null \
    | tr ',' '\n' | grep -oE "'/[^']+/'" | tr -d "'" || true)"
for path in $CUSTOM_PATHS; do
    name="$(gsettings get "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" name 2>/dev/null || true)"
    binding="$(gsettings get "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" binding 2>/dev/null || true)"
    if echo "$name" | grep -qi "toggle input source" || echo "$binding" | grep -qi "Primary.*Shift.*space"; then
        gsettings reset "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" name 2>/dev/null || true
        gsettings reset "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" command 2>/dev/null || true
        gsettings reset "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" binding 2>/dev/null || true
        # Drop the path from the list
        CURRENT_LIST="$(echo "$CURRENT_LIST" | sed "s#'${path}'##g; s#,,#,#g; s#\[,# [#; s#, *\]#]#")"
        REMOVED=1
    fi
done
if [[ "$REMOVED" -eq 1 ]]; then
    # Normalize list (remove empty entries like [, ]).
    CLEANED="$(echo "$CURRENT_LIST" | sed -E "s/,\s*,/,/g; s/\[\s*,/[/; s/,\s*\]/]/")"
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$CLEANED"
    ok "Removed legacy 'Toggle input source' binding (extension owns Ctrl+Shift+Space now)."
else
    ok "No conflicting legacy binding found."
fi

# --- 5. pre-flight checks (warnings only) ----------------------------
# 5a. Need ≥2 input sources for any layout switch to make sense.
if SOURCES="$(gsettings get org.gnome.desktop.input-sources sources 2>/dev/null)"; then
    N_SOURCES="$(echo "$SOURCES" | grep -o "('xkb'\|('ibus'" | wc -l | tr -d ' ')"
    if [[ "${N_SOURCES:-0}" -lt 2 ]]; then
        warn "Only $N_SOURCES input source configured — layout flash/switch needs ≥2.
  Add one in Settings → Keyboard → Input Sources (e.g. English + Arabic)."
    else
        ok "$N_SOURCES input sources configured."
    fi
fi

# 5b. Caps-lock LED must be readable, else the pill never shows.
if ! cat /sys/class/leds/*capslock/brightness >/dev/null 2>&1; then
    warn "Caps-lock LED not readable (/sys/class/leds/*capslock/brightness).
  The pill reads the kernel LED — on VMs / some laptops it is missing and the pill stays hidden."
else
    ok "Caps-lock LED readable."
fi

# --- 6. enable --------------------------------------------------------
info "Enabling extension $UUID …"
if gnome-extensions enable "$UUID" 2>&1; then
    ok "Extension enabled."
else
    warn "'gnome-extensions enable' could not talk to the Shell (normal over SSH / live USB).
  It will still enable on next login — just log out and back in."
fi

# --- 7. verify ---------------------------------------------------------
echo ""
info "Verification:"
if gnome-extensions info "$UUID" 2>/dev/null | grep -qi "state.*ENABLED\|state.*ACTIVE"; then
    ok "Extension reports ENABLED."
else
    warn "Could not confirm ENABLED state (Shell not reachable right now — re-check after re-login with: gnome-extensions info $UUID)."
fi
[[ -f "$DST/schemas/gschemas.compiled" ]] && ok "Compiled schema present."
command -v gnome-extensions >/dev/null && ok "Shortcut owner: extension handles Ctrl+Shift+Space in-process (no manual keybinding needed)."

echo ""
echo "${C_GREEN}${C_BOLD}Done.${C_RESET} Now ${C_BOLD}LOG OUT and LOG BACK IN${C_RESET} —"
echo "Wayland cannot reload extension code without a fresh login."
echo ""
echo "After login, test in any text field (e.g. Text Editor):"
echo "  1. Turn Caps Lock ON, type a letter  → blue ⇪ pill under the caret."
echo "  2. Press Ctrl+Shift+Space            → pill flashes EN/ARA for 1 s."
echo "  3. Super+Space / top-bar menu switch → same flash."
echo "Debug: cat /tmp/macospills-caret.log  (written while the flash is live)"

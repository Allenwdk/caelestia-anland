#!/usr/bin/env bash
# The anland/droidspaces container profile. Anland is the display stack of the
# droidspaces Android container: KWin renders into buffers owned by the Android
# app, brokered by a display daemon. KWin itself is a patched distro build that
# carries the anland output backend, and the container has no display manager,
# no udev, no kernel input devices, and no NetworkManager. Every adjustment in
# here follows from one of those facts.
if [[ -z "${CAELESTIA_ANLAND_SOURCED:-}" ]]; then
CAELESTIA_ANLAND_SOURCED=1

# Detection is cached: callers ask repeatedly across steps, and each ask would
# otherwise re-grep /etc/environment. CAELESTIA_FORCE_ANLAND lets a test or a
# user force either answer without touching the machine.
caelestia_is_anland() {
    if [[ -n "${CAELESTIA_ANLAND_CACHE:-}" ]]; then
        [[ "$CAELESTIA_ANLAND_CACHE" == "1" ]]
        return
    fi

    local detected=0
    if [[ -n "${CAELESTIA_FORCE_ANLAND:-}" ]]; then
        [[ "$CAELESTIA_FORCE_ANLAND" == "1" ]] && detected=1
    elif [[ -n "${ANLAND:-}" || -n "${ANLAND_SOCKET:-}" || -n "${ANLAND_DRM_DEVICE:-}" ]]; then
        detected=1
    elif [[ -S /run/display.sock ]]; then
        detected=1
    elif grep -q '^ANLAND=1' /etc/environment 2>/dev/null; then
        detected=1
    fi

    export CAELESTIA_ANLAND_CACHE=$detected
    [[ "$detected" == "1" ]]
}

# Appends any of $@ that pacman.conf does not already pin to the effective
# [options] IgnorePkg list. Only the section before the first repository header
# takes effect, which is where the line goes. The anland backend lives in a
# patched distro kwin, so a repository upgrade would silently replace it with a
# build that cannot drive the display at all.
caelestia_ensure_ignorepkg() {
    local conf=/etc/pacman.conf
    [[ -f "$conf" ]] || return 0

    local missing=() pkg
    for pkg in "$@"; do
        grep -Eq "^[[:space:]]*IgnorePkg[[:space:]]*=.*(^|[[:space:]])${pkg}([[:space:]]|$)" "$conf" \
            || missing+=("$pkg")
    done
    ((${#missing[@]})) || return 0

    local line="IgnorePkg = ${missing[*]}"
    info "Pinning ${missing[*]} in pacman.conf (the anland display stack must not be upgraded away)."
    if grep -q '^\[core\]' "$conf"; then
        caelestia_sudo sed -i "/^\[core\]/i $line" "$conf"
    else
        printf '%s\n' "$line" | caelestia_sudo tee -a "$conf" >/dev/null
    fi
}

# Builds and installs an AUR package with bare makepkg. This is the no-yay
# fallback for machines like anland containers, which ship no AUR helper: the
# dependencies go in through caelestia_sudo pacman first, because makepkg's own
# -s would invoke sudo interactively, and the built package is installed with
# pacman -U rather than makepkg -si for the same reason.
caelestia_aur_makepkg_install() {
    local pkg="$1"
    local cache="${XDG_CACHE_HOME:-$HOME/.cache}/caelestia-kde/aur"
    local dir="$cache/$pkg"

    caelestia_is_anland || return 1
    command -v makepkg >/dev/null 2>&1 || {
        warn "makepkg not found; cannot build the AUR package $pkg."
        return 1
    }

    if [[ ! -f "$dir/PKGBUILD" ]]; then
        mkdir -p "$cache"
        info "Fetching AUR package $pkg..."
        git clone --depth 1 "https://aur.archlinux.org/${pkg}.git" "$dir" 2>/dev/null || {
            warn "AUR package $pkg not found."
            rm -rf "$dir"
            return 1
        }
    fi

    local -a deps=()
    # shellcheck disable=SC2046
    while IFS= read -r dep; do
        package_present "$dep" || deps+=("$dep")
    done < <(
        cd "$dir" 2>/dev/null || exit 0
        makepkg --printsrcinfo 2>/dev/null \
            | awk -F' = ' '/^(make)?depends(_[a-z0-9_]+)? =/ {print $2}'
    )

    if ((${#deps[@]} > 0)); then
        info "Installing dependencies for $pkg (${deps[*]})..."
        caelestia_sudo pacman -S --needed --asdeps --noconfirm "${deps[@]}" 2>/dev/null || {
            warn "Could not install the dependencies of $pkg."
            return 1
        }
    fi

    info "Building $pkg from AUR (this can take a while)..."
    (
        cd "$dir" || exit 1
        makepkg -f --noconfirm
    ) || {
        warn "AUR build of $pkg failed."
        return 1
    }

    local built
    built="$(ls -t "$dir"/*.pkg.tar.zst "$dir"/*.pkg.tar.xz 2>/dev/null | head -n1)"
    [[ -n "$built" ]] || {
        warn "makepkg produced no package archive for $pkg."
        return 1
    }

    caelestia_sudo pacman -U --noconfirm "$built" || {
        warn "Installing the built $pkg package failed."
        return 1
    }
}

fi # CAELESTIA_ANLAND_SOURCED

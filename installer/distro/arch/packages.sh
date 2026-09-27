#!/usr/bin/env bash

set -uo pipefail

# shellcheck source=scripts/lib/log.sh
source "${BUNDLE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}/scripts/lib/log.sh"
# shellcheck source=scripts/lib/toolchain.sh
source "${BUNDLE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}/scripts/lib/toolchain.sh"
# shellcheck source=scripts/lib/privileges.sh
source "${BUNDLE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}/scripts/lib/privileges.sh"
# shellcheck source=scripts/lib/packages.sh
source "${BUNDLE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}/scripts/lib/packages.sh"
# shellcheck source=scripts/lib/darkly.sh
source "${BUNDLE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}/scripts/lib/darkly.sh"

info "Installing Arch packages..."

INSTALL_FISH="${INSTALL_FISH:-true}"
INSTALL_PAPIRUS="${INSTALL_PAPIRUS:-true}"
INSTALL_DARKLY="${INSTALL_DARKLY:-true}"

if ! command -v yay >/dev/null 2>&1; then
    info "yay not found - installing..."
    caelestia_sudo pacman -S --needed --noconfirm base-devel git || true
    tmpdir="$(mktemp -d)"
    git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$tmpdir"
    (
        cd "$tmpdir" || exit 1
        makepkg -si --noconfirm
    )
    rm -rf "$tmpdir"
fi

PACKAGE_GROUP="${PACKAGE_GROUP:-all}"

CORE_PACKAGES=(
    cmake ninja ccache qt6-tools extra-cmake-modules gcc-libs glibc rsync

    wl-clipboard cliphist wl-clip-persist inotify-tools app2unit wireplumber trash-cli jq

    aubio lm_sensors libpipewire pulseaudio-qt libpulse fftw

    qt6-base qt6-declarative qt6-wayland qt6-shadertools qt6-svg
    qt6-multimedia qt6-5compat qt6-imageformats

    kglobalaccel kglobalacceld kguiaddons kwindowsystem
    kcoreaddons kconfig networkmanager-qt kpipewire kwin

    ffmpeg libqalculate libsecret ksshaskpass libx11 vulkan-headers
)

SHELL_PACKAGES=(
    quickshell matugen python
    foot eza fastfetch starship btop bash
)

THEME_PACKAGES=(
    adw-gtk-theme ttf-jetbrains-mono-nerd ttf-material-symbols-variable
    ttf-rubik-vf ttf-cascadia-code-nerd noto-fonts noto-fonts-cjk noto-fonts-emoji
)

UTILITY_PACKAGES=(
    fuzzel swappy ddcutil networkmanager imagemagick tesseract tesseract-data-eng
    satty spectacle gpu-screen-recorder slurp grim brightnessctl power-profiles-daemon
    xdg-utils sassc bat ripgrep lazygit xdg-user-dirs
)

PACKAGES=()
case "$PACKAGE_GROUP" in
    core)   PACKAGES=("${CORE_PACKAGES[@]}") ;;
    shell)  PACKAGES=("${SHELL_PACKAGES[@]}") ;;
    themes) PACKAGES=("${THEME_PACKAGES[@]}") ;;
    utils)  PACKAGES=("${UTILITY_PACKAGES[@]}") ;;
    all|*)  PACKAGES=("${CORE_PACKAGES[@]}" "${SHELL_PACKAGES[@]}" "${THEME_PACKAGES[@]}" "${UTILITY_PACKAGES[@]}") ;;
esac

if [[ "$PACKAGE_GROUP" == "all" || "$PACKAGE_GROUP" == "shell" ]]; then
    if [[ "$INSTALL_FISH" == "true" ]]; then
        PACKAGES+=(fish)
    else
        info "Skipping Fish installation by user choice."
    fi
fi

if [[ "$PACKAGE_GROUP" == "all" || "$PACKAGE_GROUP" == "themes" ]]; then
    if [[ "$INSTALL_PAPIRUS" == "true" ]]; then
        PACKAGES+=(papirus-icon-theme)
    else
        info "Skipping Papirus icon theme installation by user choice."
    fi
fi

if [[ "$PACKAGE_GROUP" == "all" || "$PACKAGE_GROUP" == "core" ]]; then
    if cava_sdk_installed || install_cava_sdk arch; then
        info "CAVA SDK ready."
    else
        PACKAGES+=(libcava)
    fi
fi
if [[ "$PACKAGE_GROUP" == "all" || "$PACKAGE_GROUP" == "themes" ]]; then
    if [[ "$INSTALL_DARKLY" == "true" ]]; then
        PACKAGES+=(darkly-bin)
    else
        info "Skipping Darkly package installation by user choice."
    fi
fi

if grep -q '^\[caelestia-bin\]' /etc/pacman.conf 2>/dev/null; then
    info "Removing stale caelestia-bin repo entry from pacman.conf..."
    caelestia_sudo sed -i '/^\[caelestia-bin\]/,/^$/d' /etc/pacman.conf
fi

info "Installing packages (group: $PACKAGE_GROUP)..."
FAILED_PKGS=()

SOURCE_BUILD_REPOS=(
    "ttf-rubik-vf        https://github.com/googlefonts/rubik"
    "app2unit            https://github.com/Vladimir-csp/app2unit"
)

source_repo_for() {
    local name="$1" entry pkg url
    for entry in "${SOURCE_BUILD_REPOS[@]}"; do
        read -r pkg url <<<"$entry"
        if [[ "$pkg" == "$name" ]]; then
            echo "$url"
            return 0
        fi
    done
    echo ""
    return 1
}

build_from_source() {
    local pkg="$1" repo="$2" tmpdir
    tmpdir="$(mktemp -d)"
    if ! git clone --depth 1 "$repo" "$tmpdir"; then
        err "Failed to clone source for $pkg from $repo."
        rm -rf "$tmpdir"
        return 1
    fi
    (
        cd "$tmpdir" || exit 1
        if [ -f "meson.build" ]; then
            meson setup build && meson compile -C build && caelestia_sudo meson install -C build
        elif [ -f "CMakeLists.txt" ]; then
            cmake -B build && cmake --build build && caelestia_sudo cmake --install build
        elif [ -x "autogen.sh" ] || [ -f "configure.ac" ] || [ -f "configure" ]; then
            if [ -x "autogen.sh" ]; then ./autogen.sh; fi
            ./configure && make && caelestia_sudo make install
        elif [ -f "Makefile" ] || [ -f "makefile" ] || [ -f "GNUmakefile" ]; then
            make && caelestia_sudo make install
        else
            err "No recognized build system for $pkg; skipping source build."
            exit 1
        fi
    ) || {
        err "Manual build for $pkg failed."
        rm -rf "$tmpdir"
        return 1
    }
    rm -rf "$tmpdir"
    return 0
}

mapfile -t MISSING_PKGS < <(filter_missing "${PACKAGES[@]}")

if caelestia_is_anland; then
    info "Anland container detected - applying the container package profile."
    # Hardware that does not exist inside the container: no network devices of
    # its own (Android shares its connection), no backlight, no external
    # monitors with DDC, and a GPU path gpu-screen-recorder cannot record.
    local_pkgs=()
    for pkg in "${PACKAGES[@]}"; do
        case "$pkg" in
            networkmanager|brightnessctl|power-profiles-daemon|ddcutil|gpu-screen-recorder) ;;
            *) local_pkgs+=("$pkg") ;;
        esac
    done
    PACKAGES=("${local_pkgs[@]}")
    # darkly-bin ships an x86_64-only prebuilt; the AUR source package builds anywhere.
    for i in "${!PACKAGES[@]}"; do
        [[ "${PACKAGES[$i]}" == "darkly-bin" ]] && PACKAGES[$i]=darkly
    done
    # Tiling that the Nexus window controls drive; installed through the AUR fallback.
    PACKAGES+=(kwin-scripts-krohnkite)
    mapfile -t MISSING_PKGS < <(filter_missing "${PACKAGES[@]}")
fi

# Split what is missing into packages the sync repos can satisfy and the rest, so
# a machine with no AUR helper (an anland container ships none) still batch-
# installs everything the repos carry before the per-package fallbacks run.
# pacman -T prints exactly the names it cannot resolve; rc 127 mirrors that.
declare -A _unresolved=()
mapfile -t _UNRESOLVED_PKGS < <(pacman -T "${MISSING_PKGS[@]}" 2>/dev/null || true)
for pkg in "${_UNRESOLVED_PKGS[@]}"; do _unresolved["$pkg"]=1; done
REPO_PKGS=()
AUR_PKGS=()
for pkg in "${MISSING_PKGS[@]}"; do
    if [[ -n "${_unresolved[$pkg]:-}" ]]; then
        AUR_PKGS+=("$pkg")
    else
        REPO_PKGS+=("$pkg")
    fi
done
unset _unresolved _UNRESOLVED_PKGS

if (( ${#REPO_PKGS[@]} > 0 )); then
    if ! yay -S --needed --noconfirm "${REPO_PKGS[@]}"; then
        info "Batch install had failures. Retrying individually..."
        for pkg in "${REPO_PKGS[@]}"; do
            if package_present "$pkg"; then
                continue
            fi
            if ! yay -S --needed --noconfirm "$pkg"; then
                info "yay failed to install $pkg. Trying pacman..."
                if ! caelestia_sudo pacman -S --needed --noconfirm "$pkg"; then
                    err "Could not install $pkg from the repositories."
                    FAILED_PKGS+=("$pkg")
                fi
            fi
        done
    fi
fi

if (( ${#AUR_PKGS[@]} > 0 )); then
    info "Installing AUR packages: ${AUR_PKGS[*]}"
    for pkg in "${AUR_PKGS[@]}"; do
        if package_present "$pkg"; then
            continue
        fi
        if ! yay -S --needed --noconfirm "$pkg"; then
            info "yay is not available or failed for $pkg. Attempting manual build from AUR..."
            _built=no
            if caelestia_aur_makepkg_install "$pkg"; then
                _built=yes
            else
                tmpdir="$(mktemp -d)"
                if git clone --depth 1 "https://aur.archlinux.org/${pkg}.git" "$tmpdir"; then
                    (
                        cd "$tmpdir" || exit 1
                        makepkg -si --noconfirm
                    ) && _built=yes || {
                        err "Manual build from AUR for $pkg failed."
                    }
                else
                    err "Could not fetch AUR repository for $pkg."
                fi
                rm -rf "$tmpdir"
            fi

            if [[ "$_built" != "yes" ]]; then
                repo="$(source_repo_for "$pkg")"
                if [[ -n "$repo" ]]; then
                    info "Compiling $pkg from source ($repo)..."
                    if build_from_source "$pkg" "$repo"; then
                        info "Built $pkg from source."
                    else
                        FAILED_PKGS+=("$pkg")
                    fi
                else
                    err "No source repository mapping for $pkg."
                    FAILED_PKGS+=("$pkg")
                fi
            fi
        fi
    done
fi

if (( ${#MISSING_PKGS[@]} == 0 )); then
    info "All requested packages for group $PACKAGE_GROUP are already installed."
fi

if caelestia_is_anland && package_present kwin-scripts-krohnkite; then
    info "Enabling the Krohnkite KWin script..."
    kwriteconfig6 --file kwinrc --group Plugins --key krohnkiteEnabled true
fi

if [[ "$PACKAGE_GROUP" == "all" || "$PACKAGE_GROUP" == "themes" ]]; then
    if [[ "$INSTALL_DARKLY" == "true" ]]; then
        if ! darkly_gtk_installed; then
            info "Installing Darkly GTK theme..."
            yay -S --needed --noconfirm sassc >/dev/null 2>&1 || caelestia_sudo pacman -S --needed --noconfirm sassc >/dev/null 2>&1 || true
            install_darkly_gtk_theme || FAILED_PKGS+=("darkly-gtk")
        fi
    else
        info "Skipping Darkly GTK theme by user choice."
    fi
fi

if command -v xdg-user-dirs-update >/dev/null 2>&1; then
    xdg-user-dirs-update || true
fi

if command -v sassc >/dev/null 2>&1 && ! command -v sass >/dev/null 2>&1; then
    caelestia_sudo ln -sf /usr/bin/sassc /usr/local/bin/sass || true
fi

if [ ${#FAILED_PKGS[@]} -ne 0 ]; then
    mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/caelestia-kde"
    err "The following packages could not be installed:"
    for pkg in "${FAILED_PKGS[@]}"; do
        err "  - $pkg"
        echo "$pkg" >> "${XDG_CACHE_HOME:-$HOME/.cache}/caelestia-kde/failed_packages.txt"
    done
fi

info "Arch package installation complete."

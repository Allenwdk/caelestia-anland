# Caelestia on anland (droidspaces)

This document describes how the Caelestia installer adapts to the
[anland](https://github.com/SuperTurtleDev/anland) display stack used by the
droidspaces Android container, and what to expect from the result.

## What anland is

Anland is a buffer-sharing protocol, not a compositor replacement. The guest
runs a **patched distro KWin** that carries a native `AnlandBackend` output
backend (`--anland` / `ANLAND_SOCKET`): KWin stays the real compositor and
renders each frame into dma-bufs owned by the Android app, which presents them
through SurfaceFlinger. Input, clipboard, audio (PipeWire), and camera come
back through the same daemon.

Everything that means for the desktop:

| Container fact | Consequence for Caelestia |
|---|---|
| KWin is the compositor (anland-patched 6.7.4) | The whole shell works: workspace-tracker effect, D-Bus, kglobalaccel, screen edges, kwinrulesrc |
| No DRM card node, only `renderD128` (mesa kgsl) | GPU stats come from `/sys/class/kgsl/kgsl-3d0/` (handled in the plugin) |
| No udev, no `/dev/input`, no `/dev/uinput` | ydotool/OSK key injection is skipped; the Android keyboard + anland IME path is the text input |
| No SDDM; the anland app starts the session | SDDM theme step auto-skips; the lock screen greeter still applies |
| No NetworkManager / backlight / DDC | Network and brightness cards degrade to "unavailable" (existing behavior) |
| Session runs under systemd (user manager active) | `caelestia-shell.service` autostart works as on any Plasma system |

## Installer behavior on anland

Detection (`scripts/lib/anland.sh`, `caelestia_is_anland`): the `ANLAND*`
environment variables, the `/run/display.sock` daemon socket, or
`ANLAND=1` in `/etc/environment`. Override with `CAELESTIA_FORCE_ANLAND=1|0`.

Steps that change:

- **00-refresh-mirrors** — keeps the configured Arch Linux ARM mirrorlist.
  `reflector` would rewrite it with archlinux.org URLs, which serve x86_64
  packages.
- **00a-system-update** — pins `kwin`, `xorg-xwayland` and `mesa` in
  `pacman.conf` `IgnorePkg`, then skips the full `pacman -Syu` by default
  (`SKIP_SYSTEM_UPDATE=false` to run it anyway). A repository KWin upgrade
  replaces the anland backend with a build that cannot drive the display.
- **01-ensure-prereqs** — does not install yay. AUR packages are built through
  the makepkg fallback in `lib/anland.sh` (deps via `pacman --asdeps`, build as
  user, install via `pacman -U`), so no interactive sudo is needed.
- **packages** — drops hardware-only packages (networkmanager,
  brightnessctl, power-profiles-daemon, ddcutil, gpu-screen-recorder), builds
  `darkly` from source (`darkly-bin` is x86_64-only), and installs
  `kwin-scripts-krohnkite` + enables it for the Nexus tiling controls.
- **05-sddm-theme** — skipped; the session is started by the anland app.
- **06-services** — skips udev rules, the input group and ydotoold.
- **09-system-tweaks** — additionally normalizes `kwinrc [Compositing]
  Enabled=true` (some anland images ship it false; the anland backend only
  composites through OpenGL and effects refuse to load otherwise).

## KWin effect plugins

Some anland images ship a `kwin` package built without the stock effect
plugins (`/usr/lib/qt6/plugins/kwin/effects/plugins/` is empty). The Caelestia
workspace-tracker effect installs independently and works either way; the
stock effects (blur, magiclamp, overview, ...) come back by rebuilding the
kwin package with anland's own `producers/kde/Arch_v5/build.sh` (the PKGBUILD
builds them) and reinstalling it:

```sh
cd anland/producers/kde/Arch_v5
JOBS=6 INSTALL=1 ./build.sh
```

Afterwards verify both halves survived:
`ls /usr/lib/qt6/plugins/kwin/effects/plugins/` and
`strings /usr/bin/kwin_wayland | grep AnlandBackend`.

## Package pinning

`/etc/pacman.conf` must keep, inside the effective `[options]` section:

```
IgnorePkg = kwin xorg-xwayland mesa
```

- **kwin / xorg-xwayland** — only the anland-patched builds contain the
  anland backend / kgsl fixes. When anland upstream rebases to a newer
  Plasma, rerun its `build.sh` to produce new packages, then lift the pin.
- **mesa** — the image pins the mesa build known to work with the kgsl
  driver on this device. Unpin only together with a display-stack update.

`00a-system-update.sh` re-asserts the pin automatically on every run.

## Known degradations on anland

- On-screen keyboard (ydotoold) is unavailable — use the Android keyboard;
  its text arrives through KWin's `InputMethod::commitText` path.
- The network card shows "unavailable" (no NetworkManager in the container);
  battery/brightness depend on what upowerd and the output protocol expose.
- Blur stays off unless an effect providing per-window-class force blur
  (better_blur_dx/forceblur) is built against the patched kwin source; stock
  KWin blur cannot blur the quickshell surfaces.
- Swipe-to-switch-desktop animation requires the workspace-tracker effect to
  build and load; without it desktop switching falls back to plain D-Bus.

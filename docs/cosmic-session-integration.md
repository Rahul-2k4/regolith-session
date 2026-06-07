# COSMIC Session Integration Notes (Experimental)

## Scope

This branch adds a separate `regolith-session-cosmic` package for the experimental Regolith COSMIC session. The existing GNOME-backed `regolith-session-sway` package is left intact.

## Added Artifacts

- `usr/bin/regolith-session-cosmic-launch`
- `usr/lib/regolith/regolith-session-cosmic.sh`
- `usr/lib/regolith/regolith-session-cosmic-runtime`
- `usr/share/wayland-sessions/regolith-cosmic.desktop`
- `debian/regolith-session-cosmic.install`

## Behavior

The launcher initializes Regolith trawl resources, sets `XDG_CURRENT_DESKTOP=Regolith-Wayland:COSMIC:sway`, and runs Sway through `cosmic-session`. The runtime wrapper waits for the Wayland socket before starting COSMIC-side helpers.

## GNOME Dependency Boundary

`regolith-session-cosmic` does not depend on `gnome-session-bin`, `gnome-settings-daemon`, `regolith-inputd`, or `regolith-displayd`. The legacy Wayland package still carries those dependencies until the experimental session is validated enough to replace it.

## Current Helper Strategy

- COSMIC runtime owns `cosmic-settings-daemon` and delayed `cosmic-osd` startup.
- `cosmolith` starts after the Sway IPC socket is available.
- Legacy `regolith-init-inputd.service` and `regolith-init-displayd.service` are stopped/reset for this experimental session path.
- `cosmic-idle` is opt-in with `REGOLITH_COSMIC_ENABLE_IDLE=true` until lock/idle validation is complete.

## Validation

Run:

```bash
bash tests/regolith-cosmic-autostart.sh
bash tests/regolith-cosmic-status-bar.sh
dpkg-source --before-build .
dpkg-buildpackage -us -uc -b
```

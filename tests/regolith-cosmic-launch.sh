#!/bin/bash
set -Eeu -o pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$ROOT_DIR/usr/bin/regolith-session-cosmic-launch"
MANPAGE="$ROOT_DIR/usr/share/man/man1/regolith-session-cosmic-launch.1"
grep -Fq 'usr/share/man/man1/regolith-session-cosmic-launch.1' "$ROOT_DIR/debian/regolith-session-cosmic.install"
test -f "$MANPAGE"
grep -Fq '.TH REGOLITH-SESSION-COSMIC-LAUNCH 1' "$MANPAGE"
grep -Fq 'export XDG_CURRENT_DESKTOP="Regolith-Wayland:COSMIC:sway"' "$LAUNCHER"
grep -Fq 'export XDG_SESSION_DESKTOP="cosmic"' "$LAUNCHER"
grep -Fq 'export DESKTOP_SESSION="cosmic"' "$LAUNCHER"
grep -Fq 'export REGOLITH_COSMIC_LAUNCHER_OWNED=1' "$LAUNCHER"
grep -Fq 'exec dbus-run-session -- /usr/bin/cosmic-session "${sway_command[@]}"' "$LAUNCHER"
! grep -Fq 'exec cosmic-session "${sway_command[@]}"' "$LAUNCHER"

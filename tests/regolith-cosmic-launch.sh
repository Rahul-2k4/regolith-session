#!/bin/bash
set -Eeu -o pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$ROOT_DIR/usr/bin/regolith-session-cosmic-launch"
grep -Fq 'export XDG_CURRENT_DESKTOP="Regolith-Wayland:COSMIC:sway"' "$LAUNCHER"
grep -Fq 'export XDG_SESSION_DESKTOP="cosmic"' "$LAUNCHER"
grep -Fq 'export DESKTOP_SESSION="cosmic"' "$LAUNCHER"
grep -Fq 'exec dbus-run-session -- /usr/bin/cosmic-session "${sway_command[@]}"' "$LAUNCHER"
! grep -Fq 'exec cosmic-session "${sway_command[@]}"' "$LAUNCHER"

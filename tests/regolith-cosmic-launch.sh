#!/bin/bash
set -Eeu -o pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$ROOT_DIR/usr/bin/regolith-session-cosmic-launch"
grep -Fq 'export XDG_CURRENT_DESKTOP="Regolith-Wayland:COSMIC:sway"' "$LAUNCHER"
grep -Fq 'export XDG_SESSION_DESKTOP="cosmic"' "$LAUNCHER"
grep -Fq 'export DESKTOP_SESSION="cosmic"' "$LAUNCHER"
grep -Fq 'systemctl --user set-environment' "$LAUNCHER"
grep -Fq 'XDG_CURRENT_DESKTOP=COSMIC' "$LAUNCHER"
grep -Fq 'XDG_SESSION_DESKTOP=cosmic' "$LAUNCHER"
grep -Fq 'DESKTOP_SESSION=cosmic' "$LAUNCHER"
set_environment_line="$(grep -n 'systemctl --user set-environment' "$LAUNCHER" | cut -d: -f1)"
exec_line="$(grep -n 'exec dbus-run-session -- /usr/bin/cosmic-session' "$LAUNCHER" | cut -d: -f1)"
[ -n "$set_environment_line" ] && [ -n "$exec_line" ] && [ "$set_environment_line" -lt "$exec_line" ]
grep -Fq 'exec dbus-run-session -- /usr/bin/cosmic-session "${sway_command[@]}"' "$LAUNCHER"
! grep -Fq 'exec cosmic-session "${sway_command[@]}"' "$LAUNCHER"

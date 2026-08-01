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
launch_line="$(grep -n 'dbus-run-session -- /usr/bin/cosmic-session' "$LAUNCHER" | cut -d: -f1)"
set_nonzero_line="$(grep -nF 'set +e' "$LAUNCHER" | cut -d: -f1)"
status_line="$(grep -nF 'session_status=$?' "$LAUNCHER" | cut -d: -f1)"
unset_environment_line="$(grep -nF 'systemctl --user unset-environment XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP DESKTOP_SESSION' "$LAUNCHER" | cut -d: -f1)"
restore_errexit_line="$(grep -nF 'set -e' "$LAUNCHER" | tail -n1 | cut -d: -f1)"
exit_status_line="$(grep -nF 'exit "$session_status"' "$LAUNCHER" | cut -d: -f1)"
[ -n "$set_environment_line" ] && [ -n "$set_nonzero_line" ] && [ -n "$launch_line" ]
[ -n "$status_line" ] && [ -n "$unset_environment_line" ] && [ -n "$restore_errexit_line" ] && [ -n "$exit_status_line" ]
[ "$set_environment_line" -lt "$launch_line" ]
[ "$set_nonzero_line" -lt "$launch_line" ]
[ "$launch_line" -lt "$status_line" ]
[ "$status_line" -lt "$unset_environment_line" ]
[ "$unset_environment_line" -lt "$restore_errexit_line" ]
[ "$restore_errexit_line" -lt "$exit_status_line" ]
! grep -Fq 'exec dbus-run-session -- /usr/bin/cosmic-session' "$LAUNCHER"
! grep -Fq 'exec cosmic-session "${sway_command[@]}"' "$LAUNCHER"

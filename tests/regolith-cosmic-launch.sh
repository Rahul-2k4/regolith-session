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
launch_line="$(grep -nF 'dbus-run-session -- /usr/bin/cosmic-session "${sway_command[@]}" &' "$LAUNCHER" | cut -d: -f1)"
alive_line="$(grep -nF 'if ! kill -0 "$session_pid"' "$LAUNCHER" | tail -n1 | cut -d: -f1)"
sway_wait_function_line="$(grep -nF 'regolith_cosmic_wait_for_sway_socket()' "$LAUNCHER" | cut -d: -f1)"
sway_wait_timeout_line="$(grep -nF 'local timeout_seconds="${REGOLITH_COSMIC_SWAY_SOCKET_TIMEOUT_SECONDS:-15}"' "$LAUNCHER" | cut -d: -f1)"
sway_wait_loop_line="$(grep -nF 'while (( SECONDS < deadline )); do' "$LAUNCHER" | cut -d: -f1)"
sway_wait_child_line="$(grep -nF 'if ! kill -0 "$session_pid"' "$LAUNCHER" | head -n1 | cut -d: -f1)"
sway_socket_glob_line="$(grep -nF 'for candidate in "$runtime_dir"/sway-ipc.*.sock; do' "$LAUNCHER" | cut -d: -f1)"
sway_wait_sleep_line="$(grep -nF 'sleep 0.1' "$LAUNCHER" | cut -d: -f1)"
sway_wait_call_line="$(grep -nF 'if ! regolith_cosmic_wait_for_sway_socket; then' "$LAUNCHER" | cut -d: -f1)"
start_target_line="$(grep -nF 'systemctl --user start cosmic-session.target' "$LAUNCHER" | cut -d: -f1)"
target_status_line="$(grep -nF 'target_status=$?' "$LAUNCHER" | cut -d: -f1)"
target_failure_line="$(grep -nF 'if [ "$target_status" -ne 0 ]' "$LAUNCHER" | cut -d: -f1)"
abort_lines="$(grep -nF 'regolith_cosmic_abort_session "$session_pid"' "$LAUNCHER" | cut -d: -f1)"
normal_wait_line="$(grep -nF 'wait "$session_pid"' "$LAUNCHER" | tail -n1 | cut -d: -f1)"
stop_target_line="$(grep -nF 'systemctl --user stop cosmic-session.target' "$LAUNCHER" | tail -n1 | cut -d: -f1)"
unset_call_line="$(grep -nF 'regolith_cosmic_unset_manager_environment' "$LAUNCHER" | tail -n1 | cut -d: -f1)"
exit_status_line="$(grep -nF 'exit "$session_status"' "$LAUNCHER" | cut -d: -f1)"
set_nonzero_line="$(grep -nF 'set +e' "$LAUNCHER" | cut -d: -f1)"
[ -n "$set_environment_line" ] && [ -n "$set_nonzero_line" ] && [ -n "$launch_line" ]
[ -n "$sway_wait_function_line" ] && [ -n "$sway_wait_timeout_line" ] && [ -n "$sway_wait_loop_line" ]
[ -n "$sway_wait_child_line" ] && [ -n "$sway_socket_glob_line" ] && [ -n "$sway_wait_sleep_line" ] && [ -n "$sway_wait_call_line" ]
[ -n "$alive_line" ] && [ -n "$start_target_line" ] && [ -n "$target_status_line" ] && [ -n "$target_failure_line" ]
[ -n "$abort_lines" ] && [ -n "$normal_wait_line" ] && [ -n "$stop_target_line" ] && [ -n "$unset_call_line" ] && [ -n "$exit_status_line" ]
[ "$set_environment_line" -lt "$launch_line" ]
[ "$set_nonzero_line" -lt "$launch_line" ]
[ "$launch_line" -lt "$alive_line" ]
[ "$sway_wait_function_line" -lt "$sway_wait_call_line" ]
[ "$sway_wait_timeout_line" -lt "$sway_wait_loop_line" ]
[ "$sway_wait_loop_line" -lt "$sway_wait_child_line" ]
[ "$sway_wait_child_line" -lt "$sway_socket_glob_line" ]
[ "$sway_socket_glob_line" -lt "$sway_wait_sleep_line" ]
[ "$alive_line" -lt "$sway_wait_call_line" ]
[ "$sway_wait_call_line" -lt "$start_target_line" ]
[ "$alive_line" -lt "$start_target_line" ]
[ "$start_target_line" -lt "$target_status_line" ]
[ "$target_status_line" -lt "$target_failure_line" ]
[ "$normal_wait_line" -lt "$stop_target_line" ]
[ "$stop_target_line" -lt "$unset_call_line" ]
[ "$unset_call_line" -lt "$exit_status_line" ]
[ "$(printf '%s\n' "$abort_lines" | head -n1)" -lt "$target_failure_line" ]
[ "$(printf '%s\n' "$abort_lines" | tail -n1)" -gt "$target_failure_line" ]
grep -Fq 'REGOLITH_COSMIC_SWAY_SOCKET_TIMEOUT_SECONDS' "$LAUNCHER"
grep -Fq 'sway-ipc.*.sock' "$LAUNCHER"
grep -Fq 'if ! kill -0 "$session_pid"' "$LAUNCHER"
grep -Fq 'sleep 0.1' "$LAUNCHER"
grep -Fq 'regolith_cosmic_abort_session "$session_pid"' "$LAUNCHER"
grep -Fq 'kill "$pid"' "$LAUNCHER"
grep -Fq 'wait "$pid"' "$LAUNCHER"
grep -Fq 'systemctl --user stop cosmic-session.target' "$LAUNCHER"
grep -Fq 'systemctl --user unset-environment XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP DESKTOP_SESSION' "$LAUNCHER"
! grep -Fq 'exec dbus-run-session -- /usr/bin/cosmic-session' "$LAUNCHER"
! grep -Fq 'exec cosmic-session "${sway_command[@]}"' "$LAUNCHER"

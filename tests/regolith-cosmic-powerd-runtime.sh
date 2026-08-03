#!/bin/bash
set -Eeu -o pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
RUNTIME="$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic-runtime"
LOG_FILE=$(mktemp)

fail() { echo "COSMIC powerd runtime test: $*" >&2; exit 1; }
cleanup() {
    if [ -n "${compositor_pid-}" ]; then
        kill "$compositor_pid" >/dev/null 2>&1 || true
        wait "$compositor_pid" >/dev/null 2>&1 || true
    fi
    rm -f "$LOG_FILE"
}
trap cleanup EXIT

[ -f "$RUNTIME" ] || fail "missing COSMIC runtime"
bash -n "$RUNTIME" || fail "COSMIC runtime has invalid shell syntax"
if grep -Fq "XDG_CURRENT_DESKTOP" "$RUNTIME"; then
    fail "runtime must not select this path by XDG_CURRENT_DESKTOP"
fi

gnome_state=enabled
wayland_state=enabled
powerd_state=enabled
cosmic_active=false
fail_mask_target=
fail_stop_target=
helper_start_status=0

fake_systemctl() {
    local action=
    local target=

    printf '%s\n' "$*" >>"$LOG_FILE"
    shift
    action="$1"
    shift

    case "$action" in
        is-enabled)
            target="$1"
            case "$target" in
                regolith-gnome.target) printf '%s\n' "$gnome_state" ;;
                regolith-wayland.target) printf '%s\n' "$wayland_state" ;;
                regolith-init-powerd.service) printf '%s\n' "$powerd_state" ;;
                *) return 1 ;;
            esac
            ;;
        is-active)
            [ "$cosmic_active" = true ]
            ;;
        start)
            target="$1"
            [ "$target" = cosmic-session.target ] || return 1
            cosmic_active=true
            ;;
        stop)
            target="$1"
            [ "$target" != "$fail_stop_target" ] || return 1
            if [ "$target" = cosmic-session.target ]; then
                cosmic_active=false
            fi
            ;;
        mask)
            shift
            target="$1"
            [ "$target" != "$fail_mask_target" ] || return 1
            case "$target" in
                regolith-gnome.target) gnome_state=masked-runtime ;;
                regolith-wayland.target) wayland_state=masked-runtime ;;
                regolith-init-powerd.service) powerd_state=masked-runtime ;;
            esac
            ;;
        unmask)
            target="$1"
            case "$target" in
                regolith-gnome.target) gnome_state=enabled ;;
                regolith-wayland.target) wayland_state=enabled ;;
                regolith-init-powerd.service) powerd_state=enabled ;;
            esac
            ;;
        *) return 1 ;;
    esac
}
systemctl() { fake_systemctl "$@"; }
export -f systemctl fake_systemctl

assert_log_order() {
    local first="$1"
    local second="$2"
    local first_line
    local second_line

    first_line=$(grep -nF -- "$first" "$LOG_FILE" | head -n1 | cut -d: -f1)
    second_line=$(grep -nF -- "$second" "$LOG_FILE" | head -n1 | cut -d: -f1)
    [ -n "$first_line" ] || fail "missing log entry: $first"
    [ -n "$second_line" ] || fail "missing log entry: $second"
    [ "$first_line" -lt "$second_line" ] || fail "expected '$first' before '$second'"
}

reset_case() {
    : >"$LOG_FILE"
    gnome_state=enabled
    wayland_state=enabled
    powerd_state=enabled
    cosmic_active=false
    fail_mask_target=
    fail_stop_target=
    helper_start_status=0
    target_started=false
    legacy_gnome_target_mask_owned=false
    legacy_wayland_target_mask_owned=false
    legacy_powerd_mask_owned=false
}

REGOLITH_COSMIC_SESSION_HELPERS="$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic.sh"
export REGOLITH_COSMIC_SESSION_HELPERS
source "$RUNTIME"
start_regolith_cosmic_helpers() { return "$helper_start_status"; }

reset_case
sleep 30 &
compositor_pid=$!
target_started=true
cosmic_active=true
mask_regolith_legacy_targets_for_cosmic || fail "enabled-unit isolation failed"
assert_log_order "--user mask --runtime regolith-init-powerd.service" "--user stop regolith-init-powerd.service"
if regolith_cosmic_runtime_abort_session 7; then
    fail "abort unexpectedly succeeded"
fi
[ "$gnome_state" = enabled ] || fail "owned GNOME mask was not removed"
[ "$wayland_state" = enabled ] || fail "owned Wayland mask was not removed"
[ "$powerd_state" = enabled ] || fail "owned powerd mask was not removed"
[ "$cosmic_active" = false ] || fail "started COSMIC target was not stopped"
if kill -0 "$compositor_pid" >/dev/null 2>&1; then
    fail "abort left the compositor running"
fi
assert_log_order "--user stop cosmic-session.target" "--user unmask regolith-init-powerd.service"

reset_case
gnome_state=masked
wayland_state=masked-runtime
powerd_state=masked-runtime
mask_regolith_legacy_targets_for_cosmic || fail "pre-masked-unit isolation failed"
target_started=true
cosmic_active=true
sleep 30 &
compositor_pid=$!
if regolith_cosmic_runtime_abort_session 7; then
    fail "pre-mask abort unexpectedly succeeded"
fi
if grep -Fq -- "--user unmask regolith-gnome.target" "$LOG_FILE"; then
    fail "pre-existing GNOME mask was removed"
fi
if grep -Fq -- "--user unmask regolith-init-powerd.service" "$LOG_FILE"; then
    fail "pre-existing powerd mask was removed"
fi
if grep -Fq -- "--user mask --runtime regolith-gnome.target" "$LOG_FILE"; then
    fail "pre-existing GNOME mask was masked again"
fi
if grep -Fq -- "--user mask --runtime regolith-wayland.target" "$LOG_FILE"; then
    fail "pre-existing Wayland mask was masked again"
fi
if grep -Fq -- "--user mask --runtime regolith-init-powerd.service" "$LOG_FILE"; then
    fail "pre-existing powerd mask was masked again"
fi
[ "$gnome_state" = masked ] || fail "pre-existing GNOME mask state changed"
[ "$wayland_state" = masked-runtime ] || fail "pre-existing Wayland mask state changed"
[ "$powerd_state" = masked-runtime ] || fail "pre-existing powerd mask state changed"

reset_case
fail_mask_target=regolith-init-powerd.service
target_started=true
cosmic_active=true
sleep 30 &
compositor_pid=$!
if mask_regolith_legacy_targets_for_cosmic; then
    fail "mask failure unexpectedly succeeded"
fi
if regolith_cosmic_runtime_abort_session 1; then
    fail "mask failure abort unexpectedly succeeded"
fi
[ "$cosmic_active" = false ] || fail "mask failure left target active"
if kill -0 "$compositor_pid" >/dev/null 2>&1; then
    fail "mask failure left compositor running"
fi

reset_case
fail_stop_target=regolith-init-powerd.service
target_started=true
cosmic_active=true
sleep 30 &
compositor_pid=$!
if mask_regolith_legacy_targets_for_cosmic; then
    fail "stop failure unexpectedly succeeded"
fi
if regolith_cosmic_runtime_abort_session 1; then
    fail "stop failure abort unexpectedly succeeded"
fi
assert_log_order "--user mask --runtime regolith-init-powerd.service" "--user stop regolith-init-powerd.service"
if kill -0 "$compositor_pid" >/dev/null 2>&1; then
    fail "stop failure left compositor running"
fi

reset_case
fail_stop_target=regolith-gnome.target
if mask_regolith_legacy_targets_for_cosmic; then
    fail "GNOME target stop failure unexpectedly succeeded"
fi
[ "$gnome_state" = enabled ] || fail "GNOME mask was not unwound after stop failure"
[ "$wayland_state" = enabled ] || fail "Wayland mask was not unwound after stop failure"
[ "$powerd_state" = enabled ] || fail "powerd mask was not unwound after stop failure"

reset_case
fail_stop_target=regolith-wayland.target
if mask_regolith_legacy_targets_for_cosmic; then
    fail "Wayland target stop failure unexpectedly succeeded"
fi
[ "$gnome_state" = enabled ] || fail "GNOME mask was not unwound after Wayland stop failure"
[ "$wayland_state" = enabled ] || fail "Wayland mask was not unwound after Wayland stop failure"
[ "$powerd_state" = enabled ] || fail "powerd mask was not unwound after Wayland stop failure"

reset_case
helper_start_status=1
cosmic_active=true
wait_for_regolith_cosmic_wayland_socket() { return 0; }
wait_for_regolith_cosmic_sway_socket() { return 0; }
if regolith_cosmic_runtime_main sleep 30; then
    fail "helper failure unexpectedly succeeded"
fi
[ "$cosmic_active" = false ] || fail "helper failure left target active"
[ "$target_started" = false ] || fail "helper failure left target ownership active"
[ "$gnome_state" = enabled ] || fail "helper failure left GNOME mask"
[ "$wayland_state" = enabled ] || fail "helper failure left Wayland mask"
[ "$powerd_state" = enabled ] || fail "helper failure left powerd mask"
if kill -0 "$compositor_pid" >/dev/null 2>&1; then
    fail "helper failure left compositor running"
fi

echo "COSMIC powerd runtime behavior: PASS"

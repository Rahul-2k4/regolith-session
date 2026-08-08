#!/bin/bash

set -Eeu -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER_SCRIPT="$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic.sh"

if [ ! -f "$HELPER_SCRIPT" ]; then
    echo "missing helper script: $HELPER_SCRIPT" >&2
    exit 1
fi

workdir="$(mktemp -d)"
socket_pids=()
cleanup() {
    local pid=

    for pid in "${socket_pids[@]}"; do
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" 2>/dev/null || true
    done

    rm -rf "$workdir"
}
trap cleanup EXIT

log_file="$workdir/autostart.log"
stub_dir="$workdir/bin"
runtime_dir="$workdir/runtime"
mkdir -p "$stub_dir" "$runtime_dir"

make_stub() {
    local command_name="$1"

    cat >"$stub_dir/$command_name" <<'EOF'
#!/bin/bash
printf '%s argc=%s args=%s\n' "$(basename "$0")" "$#" "$*" >>"$REGOLITH_COSMIC_TEST_LOG"

if [ "${REGOLITH_COSMIC_TEST_HOLD:-}" = "$(basename "$0")" ]; then
    sleep 5
fi
EOF
    chmod +x "$stub_dir/$command_name"
}

start_socket_listener() {
    local socket_path="$1"
    local _=

    python3 - "$socket_path" <<'PY' &
import os
import socket
import sys
import time

path = sys.argv[1]

try:
    os.unlink(path)
except FileNotFoundError:
    pass

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(path)
sock.listen(1)

try:
    time.sleep(30)
finally:
    sock.close()
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
PY
    socket_pids+=("$!")

    for _ in $(seq 1 50); do
        if [ -S "$socket_path" ]; then
            return 0
        fi

        sleep 0.05
    done

    echo "expected unix socket listener at $socket_path" >&2
    exit 1
}

make_stub "cosmic-settings-daemon"
make_stub "cosmic-osd"
make_stub "cosmic-idle"
make_stub "cosmolith"

assert_wayland_socket_fallback() {
    local socket_dir="${XDG_RUNTIME_DIR:-}"
    local resolved_socket=

    resolved_socket="$(XDG_RUNTIME_DIR="$socket_dir" WAYLAND_DISPLAY="" regolith_cosmic_wayland_socket_path 2>/dev/null || true)"

    if ! printf '%s\n' "$resolved_socket" | grep -Eq "^$socket_dir/wayland-[0-9]+$"; then
        echo "expected wayland socket fallback to resolve a live wayland-* socket under $socket_dir" >&2
        exit 1
    fi
}

assert_wayland_wait_sets_display() {
    local socket_dir="${XDG_RUNTIME_DIR:-}"

    WAYLAND_DISPLAY=""
    export WAYLAND_DISPLAY

    XDG_RUNTIME_DIR="$socket_dir" wait_for_regolith_cosmic_wayland_socket

    if ! printf '%s\n' "${WAYLAND_DISPLAY:-}" | grep -Eq '^wayland-[0-9]+$'; then
        echo "expected wait_for_regolith_cosmic_wayland_socket to export WAYLAND_DISPLAY" >&2
        exit 1
    fi
}

assert_sway_socket_fallback() {
    local socket_dir="${XDG_RUNTIME_DIR:-}"
    local expected_socket="$1"
    local resolved_socket=

    resolved_socket="$(XDG_RUNTIME_DIR="$socket_dir" SWAYSOCK="" regolith_cosmic_sway_socket_path 2>/dev/null || true)"

    if [ "$resolved_socket" != "$expected_socket" ]; then
        echo "expected sway socket fallback to resolve $expected_socket, got ${resolved_socket:-<empty>}" >&2
        exit 1
    fi
}

assert_sway_wait_sets_socket() {
    local socket_dir="${XDG_RUNTIME_DIR:-}"
    local expected_socket="$1"

    SWAYSOCK=""
    export SWAYSOCK

    XDG_RUNTIME_DIR="$socket_dir" wait_for_regolith_cosmic_sway_socket

    if [ "${SWAYSOCK:-}" != "$expected_socket" ]; then
        echo "expected wait_for_regolith_cosmic_sway_socket to export $expected_socket, got ${SWAYSOCK:-<empty>}" >&2
        exit 1
    fi
}

assert_runtime_waits_for_sway_socket_before_helpers() {
    local runtime_script="$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic-runtime"
    local sway_wait_line=
    local helper_line=

    sway_wait_line="$(grep -n 'if wait_for_regolith_cosmic_sway_socket' "$runtime_script" | cut -d: -f1)"
    helper_line="$(grep -n '^[[:space:]]*start_regolith_cosmic_helpers$' "$runtime_script" | head -n1 | cut -d: -f1)"

    if [ -z "$sway_wait_line" ] || [ -z "$helper_line" ] || [ "$sway_wait_line" -ge "$helper_line" ]; then
        echo "expected runtime to discover Sway IPC before starting COSMIC helpers" >&2
        exit 1
    fi

    if ! grep -Fq 'Sway IPC socket was not found; skipping COSMIC helper startup' "$runtime_script"; then
        echo "expected runtime to report and skip helper startup without a Sway IPC socket" >&2
        exit 1
    fi
}

wait_for_log_entry() {
    local entry="$1"
    local _=

    for _ in $(seq 1 20); do
        if [ -f "$log_file" ] && grep -qx "$entry" "$log_file"; then
            return 0
        fi

        sleep 0.05
    done

    return 1
}

export PATH="$stub_dir:$PATH"
export REGOLITH_COSMIC_TEST_LOG="$log_file"
export XDG_RUNTIME_DIR="$runtime_dir"

start_socket_listener "$XDG_RUNTIME_DIR/wayland-1"
expected_sway_socket="$XDG_RUNTIME_DIR/sway-ipc.1000.1.sock"
start_socket_listener "$expected_sway_socket"

# shellcheck disable=SC1090
source "$HELPER_SCRIPT"

assert_wayland_socket_fallback
assert_wayland_wait_sets_display
assert_sway_socket_fallback "$expected_sway_socket"
assert_sway_wait_sets_socket "$expected_sway_socket"
assert_runtime_waits_for_sway_socket_before_helpers
SWAYSOCK="$(regolith_cosmic_sway_socket_path 2>/dev/null || true)"
export SWAYSOCK

rm -f "$log_file"
export REGOLITH_COSMIC_DISABLE_PROCESS_CHECK=true
regolith_cosmic_start_optional_process_after 0.1 cosmic-osd

if ! wait_for_log_entry 'cosmic-osd argc=0 args='; then
    echo "expected delayed helper startup to launch cosmic-osd" >&2
    exit 1
fi

if ! grep -qx 'cosmic-osd argc=0 args=' "$log_file"; then
    echo "expected delayed helper startup to launch cosmic-osd without extra arguments" >&2
    exit 1
fi

unset REGOLITH_COSMIC_DISABLE_PROCESS_CHECK
rm -f "$log_file"
REGOLITH_COSMIC_TEST_HOLD=cosmic-settings-daemon cosmic-settings-daemon &
existing_pid="$!"
sleep 0.1
regolith_cosmic_start_optional_process cosmic-settings-daemon
sleep 0.1

if ! wait_for_log_entry 'cosmic-settings-daemon argc=0 args='; then
    echo "expected long process names to be detected as already running" >&2
    kill "$existing_pid" >/dev/null 2>&1 || true
    wait "$existing_pid" 2>/dev/null || true
    exit 1
fi

if [ "$(grep -c '^cosmic-settings-daemon argc=0 args=$' "$log_file")" -ne 1 ]; then
    echo "expected long process names to be logged exactly once" >&2
    kill "$existing_pid" >/dev/null 2>&1 || true
    wait "$existing_pid" 2>/dev/null || true
    exit 1
fi

kill "$existing_pid" >/dev/null 2>&1 || true
wait "$existing_pid" 2>/dev/null || true

rm -f "$log_file"
export REGOLITH_COSMIC_DISABLE_PROCESS_CHECK=true
export REGOLITH_COSMIC_OSD_DELAY_SECONDS=0.1
start_regolith_cosmic_helpers


if ! wait_for_log_entry 'cosmolith argc=0 args='; then
    echo "expected cosmolith to autostart when a sway socket is available" >&2
    exit 1
fi

if ! wait_for_log_entry 'cosmic-settings-daemon argc=0 args='; then
    echo "expected cosmic-settings-daemon to autostart" >&2
    exit 1
fi

if ! wait_for_log_entry 'cosmic-osd argc=0 args='; then
    echo "expected cosmic-osd to autostart" >&2
    exit 1
fi

if grep -qx 'cosmic-idle argc=0 args=' "$log_file"; then
    echo "expected cosmic-idle to stay disabled by default" >&2
    exit 1
fi

rm -f "$log_file"
REGOLITH_COSMIC_ENABLE_IDLE=true start_regolith_cosmic_helpers
sleep 0.2

if [ -f "$log_file" ] && grep -qx 'cosmic-idle argc=0 args=' "$log_file"; then
    echo "expected the session helper not to create a second idle owner" >&2
    exit 1
fi

runtime_helper_script="$workdir/runtime-helper.sh"
cat >"$runtime_helper_script" <<'EOF'
#!/bin/bash
wait_for_regolith_cosmic_wayland_socket() {
    [ "${REGOLITH_COSMIC_TEST_READY:-false}" = true ]
}

wait_for_regolith_cosmic_sway_socket() {
    [ "${REGOLITH_COSMIC_TEST_READY:-false}" = true ]
}

start_regolith_cosmic_helpers() {
    printf '%s\n' helpers >>"$REGOLITH_COSMIC_TEST_LOG"
}
EOF
chmod +x "$runtime_helper_script"

runtime_script="$workdir/regolith-session-cosmic-runtime"
sed "s|source /usr/lib/regolith/regolith-session-cosmic.sh|source \"$runtime_helper_script\"|" \
    "$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic-runtime" >"$runtime_script"
chmod +x "$runtime_script"

cat >"$stub_dir/systemctl" <<'EOF'
#!/bin/bash
printf 'systemctl argc=%s args=%s\n' "$#" "$*" >>"$REGOLITH_COSMIC_TEST_LOG"

if [ "$2" = is-active ]; then
    if [ "${REGOLITH_COSMIC_TEST_SYSTEMCTL_PREACTIVE:-false}" = true ]; then
        exit 0
    fi

    exit "${REGOLITH_COSMIC_TEST_SYSTEMCTL_STATE_STATUS:-3}"
fi

if [ "$2" = is-enabled ]; then
    if [ "${REGOLITH_COSMIC_TEST_SYSTEMCTL_IS_ENABLED_FAIL:-}" = true ] || \
        [ "${REGOLITH_COSMIC_TEST_SYSTEMCTL_IS_ENABLED_FAIL:-}" = "$3" ]; then
        exit 1
    fi

    case "$3" in
        regolith-gnome.target)
            state="${REGOLITH_COSMIC_TEST_GNOME_TARGET_ENABLED_STATE:-disabled}"
            ;;
        regolith-wayland.target)
            state="${REGOLITH_COSMIC_TEST_WAYLAND_TARGET_ENABLED_STATE:-disabled}"
            ;;
        *)
            state=disabled
            ;;
    esac

    printf '%s\n' "$state"

    case "$state" in
        enabled|enabled-runtime)
            exit 0
            ;;
        *)
            exit 1
            ;;
    esac
fi

if [ "${REGOLITH_COSMIC_TEST_SYSTEMCTL_START_FAIL:-false}" = true ] && [ "$2" = start ]; then
    exit 1
fi

if [ "$2" = mask ] && { [ "${REGOLITH_COSMIC_TEST_SYSTEMCTL_MASK_FAIL:-false}" = true ] ||
    [ "${REGOLITH_COSMIC_TEST_SYSTEMCTL_MASK_FAIL_TARGET:-}" = "$4" ]; }; then
    exit 1
fi

if [ -n "${REGOLITH_COSMIC_TEST_EXIT_AFTER_TARGET_START:-}" ] && [ "$2" = start ]; then
    : >"$REGOLITH_COSMIC_TEST_EXIT_AFTER_TARGET_START"
    sleep 0.1
fi
EOF
chmod +x "$stub_dir/systemctl"

run_runtime() {
    local ready="$1"
    shift

    REGOLITH_COSMIC_TEST_READY="$ready" \
        REGOLITH_COSMIC_TEST_SYSTEMCTL_START_FAIL="${REGOLITH_COSMIC_TEST_SYSTEMCTL_START_FAIL:-false}" \
        REGOLITH_COSMIC_TEST_SYSTEMCTL_PREACTIVE="${REGOLITH_COSMIC_TEST_SYSTEMCTL_PREACTIVE:-false}" \
        REGOLITH_COSMIC_TEST_SYSTEMCTL_STATE_STATUS="${REGOLITH_COSMIC_TEST_SYSTEMCTL_STATE_STATUS:-3}" \
        REGOLITH_COSMIC_TEST_SYSTEMCTL_MASK_FAIL="${REGOLITH_COSMIC_TEST_SYSTEMCTL_MASK_FAIL:-false}" \
        REGOLITH_COSMIC_TEST_SYSTEMCTL_MASK_FAIL_TARGET="${REGOLITH_COSMIC_TEST_SYSTEMCTL_MASK_FAIL_TARGET:-}" \
        REGOLITH_COSMIC_TEST_SYSTEMCTL_IS_ENABLED_FAIL="${REGOLITH_COSMIC_TEST_SYSTEMCTL_IS_ENABLED_FAIL:-}" \
        REGOLITH_COSMIC_TEST_GNOME_TARGET_ENABLED_STATE="${REGOLITH_COSMIC_TEST_GNOME_TARGET_ENABLED_STATE:-disabled}" \
        REGOLITH_COSMIC_TEST_WAYLAND_TARGET_ENABLED_STATE="${REGOLITH_COSMIC_TEST_WAYLAND_TARGET_ENABLED_STATE:-disabled}" \
        REGOLITH_COSMIC_TEST_EXIT_AFTER_TARGET_START="${REGOLITH_COSMIC_TEST_EXIT_AFTER_TARGET_START:-}" \
        "$runtime_script" "$@"
}

assert_runtime_uses_installed_helper() {
    if ! grep -Fqx 'source /usr/lib/regolith/regolith-session-cosmic.sh' \
        "$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic-runtime"; then
        echo "expected package runtime to source the installed COSMIC helper" >&2
        exit 1
    fi
}

assert_legacy_target_mask_queries_once() {
    if [ "$(grep -c "^systemctl argc=3 args=--user is-enabled regolith-gnome.target$" "$log_file")" -ne 1 ]; then
        echo "expected COSMIC runtime to query the GNOME Regolith target mask state exactly once" >&2
        exit 1
    fi

    if [ "$(grep -c "^systemctl argc=3 args=--user is-enabled regolith-wayland.target$" "$log_file")" -ne 1 ]; then
        echo "expected COSMIC runtime to query the Wayland Regolith target mask state exactly once" >&2
        exit 1
    fi
}
assert_legacy_target_masked_once() {
    local target="$1"

    if [ "$(grep -c "^systemctl argc=4 args=--user mask --runtime $target$" "$log_file")" -ne 1 ]; then
        echo "expected COSMIC runtime to runtime-mask $target exactly once" >&2
        exit 1
    fi
}

assert_legacy_targets_masked_once() {
    assert_legacy_target_masked_once regolith-gnome.target
    assert_legacy_target_masked_once regolith-wayland.target
}

assert_legacy_target_unmasked_once() {
    local target="$1"

    if [ "$(grep -c "^systemctl argc=3 args=--user unmask $target$" "$log_file")" -ne 1 ]; then
        echo "expected COSMIC runtime to unmask $target exactly once" >&2
        exit 1
    fi
}

assert_legacy_target_not_unmasked() {
    local target="$1"

    if grep -Fq "args=--user unmask $target" "$log_file" 2>/dev/null; then
        echo "expected COSMIC runtime not to unmask pre-existing mask for $target" >&2
        exit 1
    fi
}
assert_legacy_target_not_masked() {
    local target="$1"

    if grep -Fq "args=--user mask --runtime $target" "$log_file" 2>/dev/null; then
        echo "expected COSMIC runtime not to runtime-mask $target" >&2
        exit 1
    fi
}


assert_legacy_targets_unmasked_once() {
    assert_legacy_target_unmasked_once regolith-gnome.target
    assert_legacy_target_unmasked_once regolith-wayland.target
}

assert_legacy_targets_not_unmasked() {
    assert_legacy_target_not_unmasked regolith-gnome.target
    assert_legacy_target_not_unmasked regolith-wayland.target
}

assert_legacy_targets_not_masked() {
    if grep -Fq "args=--user mask --runtime regolith-gnome.target" "$log_file" 2>/dev/null ||
        grep -Fq "args=--user mask --runtime regolith-wayland.target" "$log_file" 2>/dev/null ||
        grep -Fq "args=--user unmask regolith-gnome.target" "$log_file" 2>/dev/null ||
        grep -Fq "args=--user unmask regolith-wayland.target" "$log_file" 2>/dev/null; then
        echo "expected COSMIC failure path not to mask or unmask legacy Regolith targets" >&2
        exit 1
    fi
}

assert_helpers_not_started() {
    if grep -qx helpers "$log_file" 2>/dev/null; then
        echo "expected helper startup to be skipped" >&2
        exit 1
    fi
}

assert_legacy_targets_stopped_once() {
    if [ "$(grep -c '^systemctl argc=3 args=--user stop regolith-gnome.target$' "$log_file")" -ne 1 ] ||
        [ "$(grep -c '^systemctl argc=3 args=--user stop regolith-wayland.target$' "$log_file")" -ne 1 ]; then
        echo "expected COSMIC availability to stop each legacy Regolith target once" >&2
        exit 1
    fi
}

assert_legacy_targets_not_stopped() {
    if grep -Fq 'args=--user stop regolith-gnome.target' "$log_file" 2>/dev/null ||
        grep -Fq 'args=--user stop regolith-wayland.target' "$log_file" 2>/dev/null; then
        echo "expected COSMIC failure path not to stop legacy Regolith targets" >&2
        exit 1
    fi
}


assert_runtime_target_lifecycle() {
    rm -f "$log_file"

    set +e
    run_runtime true bash -c 'sleep 1; exit 23'
    runtime_status=$?
    set -e

    if [ "$runtime_status" -ne 23 ]; then
        echo "expected runtime to preserve compositor exit status, got $runtime_status" >&2
        exit 1
    fi

    if [ "$(grep -c '^systemctl argc=4 args=--user is-active --quiet cosmic-session.target$' "$log_file")" -ne 1 ]; then
        echo "expected runtime to query cosmic-session.target before readiness cleanup" >&2
        exit 1
    fi

    if [ "$(grep -c '^systemctl argc=3 args=--user stop regolith-gnome.target$' "$log_file")" -ne 1 ]; then
        echo "expected COSMIC runtime to stop the GNOME Regolith target exactly once" >&2
        exit 1
    fi

    if [ "$(grep -c '^systemctl argc=3 args=--user stop regolith-wayland.target$' "$log_file")" -ne 1 ]; then
        echo "expected COSMIC runtime to stop the Wayland Regolith target exactly once" >&2
        exit 1
    fi

    if grep -Fq 'args=--user stop gnome-session.target' "$log_file" 2>/dev/null; then
        echo "expected COSMIC runtime not to stop generic gnome-session.target" >&2
        exit 1
    fi

    if [ "$(grep -c '^systemctl argc=3 args=--user start cosmic-session.target$' "$log_file")" -ne 1 ]; then
        echo "expected runtime to start cosmic-session.target exactly once after readiness" >&2
        exit 1
    fi

    if [ "$(grep -c '^systemctl argc=3 args=--user stop cosmic-session.target$' "$log_file")" -ne 1 ]; then
        echo "expected runtime to stop cosmic-session.target during compositor cleanup" >&2
        exit 1
    fi

    assert_legacy_target_mask_queries_once
    assert_legacy_targets_masked_once
    assert_legacy_targets_unmasked_once

    if ! grep -qx helpers "$log_file"; then
        echo "expected runtime to preserve COSMIC optional helper startup" >&2
        exit 1
    fi
}

assert_runtime_does_not_stop_preactive_target() {
    rm -f "$log_file"

    export REGOLITH_COSMIC_TEST_SYSTEMCTL_PREACTIVE=true
    set +e
    run_runtime true bash -c 'sleep 0.1; exit 37'
    runtime_status=$?
    set -e
    unset REGOLITH_COSMIC_TEST_SYSTEMCTL_PREACTIVE

    if [ "$runtime_status" -ne 37 ]; then
        echo "expected pre-active target path to preserve compositor exit status, got $runtime_status" >&2
        exit 1
    fi

    if [ "$(grep -c '^systemctl argc=4 args=--user is-active --quiet cosmic-session.target$' "$log_file")" -ne 1 ]; then
        echo "expected runtime to query the pre-active COSMIC target" >&2
        exit 1
    fi

    if grep -Fq 'args=--user start cosmic-session.target' "$log_file" 2>/dev/null; then
        echo "expected runtime not to start an already active COSMIC target" >&2
        exit 1
    fi

    if grep -Fq 'args=--user stop cosmic-session.target' "$log_file" 2>/dev/null; then
        echo "expected runtime not to stop a pre-active COSMIC target" >&2
        exit 1
    fi

    assert_legacy_target_mask_queries_once
    assert_legacy_targets_masked_once
    assert_legacy_targets_unmasked_once

    if ! grep -qx helpers "$log_file"; then
        echo "expected pre-active COSMIC target to preserve helper startup" >&2
        exit 1
    fi
}

assert_runtime_skips_target_before_readiness() {
    rm -f "$log_file"

    set +e
    run_runtime false bash -c 'exit 17'
    runtime_status=$?
    set -e

    if [ "$runtime_status" -ne 17 ]; then
        echo "expected early compositor failure status to be preserved, got $runtime_status" >&2
        exit 1
    fi

    if grep -Fq 'args=--user start cosmic-session.target' "$log_file" 2>/dev/null; then
        echo "expected runtime not to start cosmic-session.target before compositor readiness" >&2
        exit 1
    fi

    if grep -Fq 'args=--user stop cosmic-session.target' "$log_file" 2>/dev/null; then
        echo "expected runtime not to stop an unowned target before compositor readiness" >&2
        exit 1
    fi
    if grep -Fq 'args=--user stop regolith-gnome.target' "$log_file" 2>/dev/null ||
        grep -Fq 'args=--user stop regolith-wayland.target' "$log_file" 2>/dev/null; then
        echo "expected early compositor exit not to stop legacy Regolith targets" >&2
        exit 1
    fi

    assert_legacy_targets_not_masked
}

assert_runtime_does_not_stop_failed_target_start() {
    rm -f "$log_file"

    export REGOLITH_COSMIC_TEST_SYSTEMCTL_START_FAIL=true
    set +e
    run_runtime true bash -c 'sleep 0.1; exit 29'
    runtime_status=$?
    set -e
    unset REGOLITH_COSMIC_TEST_SYSTEMCTL_START_FAIL

    if [ "$runtime_status" -ne 29 ]; then
        echo "expected target-start failure path to preserve compositor exit status, got $runtime_status" >&2
        exit 1
    fi

    if [ "$(grep -c '^systemctl argc=3 args=--user start cosmic-session.target$' "$log_file")" -ne 1 ]; then
        echo "expected failed target start to be attempted once" >&2
        exit 1
    fi

    if grep -Fq 'args=--user stop cosmic-session.target' "$log_file" 2>/dev/null; then
        echo "expected failed target start not to stop an unowned target" >&2
        exit 1
    fi

    assert_legacy_targets_not_masked

    if grep -qx helpers "$log_file"; then
        echo "expected helper startup to be skipped after target start failure" >&2
        exit 1
    fi
}

assert_runtime_skips_helpers_when_first_legacy_mask_fails() {
    rm -f "$log_file"

    export REGOLITH_COSMIC_TEST_SYSTEMCTL_MASK_FAIL=true
    set +e
    run_runtime true bash -c 'sleep 0.1; exit 53'
    runtime_status=$?
    set -e
    unset REGOLITH_COSMIC_TEST_SYSTEMCTL_MASK_FAIL

    if [ "$runtime_status" -ne 53 ]; then
        echo "expected mask-failure path to preserve compositor exit status, got $runtime_status" >&2
        exit 1
    fi
    assert_legacy_target_masked_once regolith-gnome.target
    assert_legacy_target_not_masked regolith-wayland.target
    assert_legacy_targets_not_unmasked
    assert_helpers_not_started
    assert_legacy_targets_not_stopped

    if [ "$(grep -c '^systemctl argc=3 args=--user stop cosmic-session.target$' "$log_file")" -ne 1 ]; then
        echo "expected owned COSMIC target cleanup after legacy mask failure" >&2
        exit 1
    fi
}

assert_runtime_rolls_back_first_legacy_mask_when_second_fails() {
    rm -f "$log_file"

    export REGOLITH_COSMIC_TEST_SYSTEMCTL_MASK_FAIL_TARGET=regolith-wayland.target
    set +e
    run_runtime true bash -c 'sleep 0.1; exit 71'
    runtime_status=$?
    set -e
    unset REGOLITH_COSMIC_TEST_SYSTEMCTL_MASK_FAIL_TARGET

    if [ "$runtime_status" -ne 71 ]; then
        echo "expected second-mask failure path to preserve compositor exit status, got $runtime_status" >&2
        exit 1
    fi

    assert_legacy_target_mask_queries_once
    assert_legacy_targets_masked_once
    assert_legacy_target_unmasked_once regolith-gnome.target
    assert_legacy_target_not_unmasked regolith-wayland.target
    assert_helpers_not_started
    assert_legacy_targets_not_stopped

    if [ "$(grep -c '^systemctl argc=3 args=--user stop cosmic-session.target$' "$log_file")" -ne 1 ]; then
        echo "expected owned COSMIC target cleanup after second legacy mask failure" >&2
        exit 1
    fi
}

assert_runtime_skips_helpers_when_legacy_mask_state_query_fails() {
    rm -f "$log_file"

    export REGOLITH_COSMIC_TEST_SYSTEMCTL_IS_ENABLED_FAIL=regolith-wayland.target
    set +e
    run_runtime true bash -c 'sleep 0.1; exit 59'
    runtime_status=$?
    set -e
    unset REGOLITH_COSMIC_TEST_SYSTEMCTL_IS_ENABLED_FAIL

    if [ "$runtime_status" -ne 59 ]; then
        echo "expected mask-state-query failure path to preserve compositor exit status, got $runtime_status" >&2
        exit 1
    fi

    assert_legacy_target_mask_queries_once
    assert_legacy_targets_not_masked
    assert_legacy_targets_not_stopped
    assert_helpers_not_started
}

assert_runtime_cleans_up_target_after_post_start_compositor_exit() {
    local exit_marker="$workdir/post-start-exit"

    rm -f "$log_file" "$exit_marker"

    export REGOLITH_COSMIC_TEST_EXIT_AFTER_TARGET_START="$exit_marker"
    set +e
    run_runtime true bash -c 'while [ ! -e "$REGOLITH_COSMIC_TEST_EXIT_AFTER_TARGET_START" ]; do sleep 0.01; done; exit 31'
    runtime_status=$?
    set -e
    unset REGOLITH_COSMIC_TEST_EXIT_AFTER_TARGET_START

    if [ "$runtime_status" -ne 31 ]; then
        echo "expected post-start compositor failure status to be preserved, got $runtime_status" >&2
        exit 1
    fi

    if [ "$(grep -c '^systemctl argc=3 args=--user start cosmic-session.target$' "$log_file")" -ne 1 ]; then
        echo "expected target start before post-start compositor liveness check" >&2
        exit 1
    fi

    if [ "$(grep -c '^systemctl argc=3 args=--user stop cosmic-session.target$' "$log_file")" -ne 1 ]; then
        echo "expected target cleanup after post-start compositor exit" >&2
        exit 1
    fi

    assert_legacy_targets_not_masked

    if grep -qx helpers "$log_file"; then
        echo "expected helper startup to be skipped after post-start compositor exit" >&2
        exit 1
    fi
}

assert_runtime_uses_installed_helper
assert_runtime_target_lifecycle
assert_runtime_does_not_stop_preactive_target
assert_runtime_skips_target_before_readiness
assert_runtime_does_not_stop_failed_target_start
assert_runtime_skips_helpers_when_first_legacy_mask_fails
assert_runtime_rolls_back_first_legacy_mask_when_second_fails
assert_runtime_skips_helpers_when_legacy_mask_state_query_fails
assert_runtime_cleans_up_target_after_post_start_compositor_exit

assert_runtime_stops_legacy_targets_after_cosmic_availability() {
    rm -f "$log_file"
    set +e
    run_runtime true bash -c 'sleep 0.1; exit 43'
    runtime_status=$?
    set -e
    [ "$runtime_status" -eq 43 ] || exit 1
    assert_legacy_targets_stopped_once
    assert_legacy_target_mask_queries_once
    assert_legacy_targets_masked_once
    assert_legacy_targets_unmasked_once

    rm -f "$log_file"
    export REGOLITH_COSMIC_TEST_SYSTEMCTL_PREACTIVE=true
    set +e
    run_runtime true bash -c 'sleep 0.1; exit 47'
    runtime_status=$?
    set -e
    unset REGOLITH_COSMIC_TEST_SYSTEMCTL_PREACTIVE
    [ "$runtime_status" -eq 47 ] || exit 1
    assert_legacy_targets_stopped_once
    assert_legacy_target_mask_queries_once
    assert_legacy_targets_masked_once
    assert_legacy_targets_unmasked_once
}

assert_runtime_preserves_preexisting_legacy_masks() {
    rm -f "$log_file"

    export REGOLITH_COSMIC_TEST_GNOME_TARGET_ENABLED_STATE=masked
    export REGOLITH_COSMIC_TEST_WAYLAND_TARGET_ENABLED_STATE=masked-runtime
    set +e
    run_runtime true bash -c 'sleep 0.1; exit 61'
    runtime_status=$?
    set -e
    unset REGOLITH_COSMIC_TEST_GNOME_TARGET_ENABLED_STATE
    unset REGOLITH_COSMIC_TEST_WAYLAND_TARGET_ENABLED_STATE

    if [ "$runtime_status" -ne 61 ]; then
        echo "expected pre-existing mask path to preserve compositor exit status, got $runtime_status" >&2
        exit 1
    fi

    assert_legacy_target_mask_queries_once
    assert_legacy_targets_masked_once
    assert_legacy_targets_not_unmasked
    assert_legacy_targets_stopped_once

    if ! grep -qx helpers "$log_file"; then
        echo "expected helper startup when legacy masks were already present" >&2
        exit 1
    fi
}

assert_runtime_unmasks_only_owned_legacy_masks() {
    rm -f "$log_file"

    export REGOLITH_COSMIC_TEST_GNOME_TARGET_ENABLED_STATE=masked
    export REGOLITH_COSMIC_TEST_WAYLAND_TARGET_ENABLED_STATE=disabled
    set +e
    run_runtime true bash -c 'sleep 0.1; exit 67'
    runtime_status=$?
    set -e
    unset REGOLITH_COSMIC_TEST_GNOME_TARGET_ENABLED_STATE
    unset REGOLITH_COSMIC_TEST_WAYLAND_TARGET_ENABLED_STATE

    if [ "$runtime_status" -ne 67 ]; then
        echo "expected mixed mask ownership path to preserve compositor exit status, got $runtime_status" >&2
        exit 1
    fi

    assert_legacy_target_mask_queries_once
    assert_legacy_targets_masked_once
    assert_legacy_target_not_unmasked regolith-gnome.target
    assert_legacy_target_unmasked_once regolith-wayland.target
    assert_legacy_targets_stopped_once

    if ! grep -qx helpers "$log_file"; then
        echo "expected helper startup when legacy mask ownership is known" >&2
        exit 1
    fi
}

assert_runtime_keeps_legacy_targets_on_target_state_query_error() {
    rm -f "$log_file"
    export REGOLITH_COSMIC_TEST_SYSTEMCTL_STATE_STATUS=1
    set +e
    run_runtime true bash -c 'sleep 0.1; exit 41'
    runtime_status=$?
    set -e
    unset REGOLITH_COSMIC_TEST_SYSTEMCTL_STATE_STATUS
    [ "$runtime_status" -eq 41 ] || exit 1
    assert_legacy_targets_not_masked
    assert_legacy_targets_not_stopped
}

assert_runtime_keeps_legacy_targets_on_target_start_failure() {
    rm -f "$log_file"
    export REGOLITH_COSMIC_TEST_SYSTEMCTL_START_FAIL=true
    set +e
    run_runtime true bash -c 'sleep 0.1; exit 29'
    runtime_status=$?
    set -e
    unset REGOLITH_COSMIC_TEST_SYSTEMCTL_START_FAIL
    [ "$runtime_status" -eq 29 ] || exit 1
    assert_legacy_targets_not_masked
    assert_legacy_targets_not_stopped
}

assert_runtime_keeps_legacy_targets_on_early_compositor_exit() {
    rm -f "$log_file"
    set +e
    run_runtime false bash -c 'exit 17'
    runtime_status=$?
    set -e
    [ "$runtime_status" -eq 17 ] || exit 1
    assert_legacy_targets_not_masked
    assert_legacy_targets_not_stopped
}

assert_runtime_stops_legacy_targets_after_cosmic_availability
assert_runtime_preserves_preexisting_legacy_masks
assert_runtime_unmasks_only_owned_legacy_masks
assert_runtime_keeps_legacy_targets_on_target_state_query_error
assert_runtime_keeps_legacy_targets_on_target_start_failure
assert_runtime_keeps_legacy_targets_on_early_compositor_exit

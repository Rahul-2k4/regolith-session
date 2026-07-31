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

if ! wait_for_log_entry 'cosmic-idle argc=0 args='; then
    echo "expected cosmic-idle to autostart when enabled explicitly" >&2
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

if [ "${REGOLITH_COSMIC_TEST_SYSTEMCTL_START_FAIL:-false}" = true ] && [ "$2" = start ]; then
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

assert_runtime_target_lifecycle() {
    rm -f "$log_file"

    set +e
    run_runtime true bash -c 'sleep 0.1; exit 23'
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

    if grep -qx helpers "$log_file"; then
        echo "expected helper startup to be skipped after target start failure" >&2
        exit 1
    fi
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
assert_runtime_cleans_up_target_after_post_start_compositor_exit

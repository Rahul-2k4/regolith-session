#!/bin/bash

set -Eeu -o pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
workdir="$(mktemp -d)"
cleanup() {
    local pid=

    for pid in $(cat "$workdir/pids" 2>/dev/null || true); do
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" 2>/dev/null || true
    done

    rm -rf "$workdir"
}
trap cleanup EXIT

export REGOLITH_COSMIC_SESSION_HELPERS="$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic.sh"
source "$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic-runtime"
mock_parent_executable() {
    case "$1" in
        501) printf '%s\n' cosmic-session ;;
        502) printf '%s\n' unrelated-parent ;;
        503) printf '%s\n' dbus-run-session ;;
        504) return 1 ;; # unreadable /proc/<pid>/exe
        *) return 1 ;;
    esac
}
mock_parent_pid() {
    case "$1" in
        501) printf '%s\n' 503 ;;
        502) printf '%s\n' 1 ;;
        503) printf '%s\n' 1 ;;
        *) return 1 ;;
    esac
}
regolith_cosmic_runtime_parent_executable() { mock_parent_executable "$1"; }
regolith_cosmic_runtime_parent_pid() { mock_parent_pid "$1"; }
regolith_cosmic_runtime_parent_start_pid() { printf '%s\n' 501; }
[ "$(regolith_cosmic_runtime_find_owned_parent)" = 501 ] || {
    echo "expected exact cosmic-session ancestry to be accepted" >&2
    exit 1
}
regolith_cosmic_runtime_parent_start_pid() { printf '%s\n' 502; }
if regolith_cosmic_runtime_find_owned_parent >/dev/null; then
    echo "expected arbitrary parent ancestry to be rejected" >&2
    exit 1
fi
regolith_cosmic_runtime_parent_start_pid() { printf '%s\n' 503; }
[ "$(regolith_cosmic_runtime_find_owned_parent)" = 503 ] || {
    echo "expected exact dbus-run-session ancestry to be accepted" >&2
    exit 1
}
signal_log=""
kill() { signal_log="$*"; }
regolith_cosmic_runtime_parent_start_pid() { printf '%s\n' 501; }
regolith_cosmic_runtime_terminate_owned_parent
[ "$signal_log" = "-TERM 501" ] || {
    echo "expected only the verified COSMIC parent to receive TERM" >&2
    exit 1
}
signal_log=""
regolith_cosmic_runtime_parent_start_pid() { printf '%s\n' 502; }
regolith_cosmic_runtime_terminate_owned_parent
[ -z "$signal_log" ] || {
    echo "expected arbitrary parent teardown to be a no-op" >&2
    exit 1
}
signal_log=""
regolith_cosmic_runtime_parent_start_pid() { printf '%s\n' 504; }
regolith_cosmic_runtime_terminate_owned_parent
[ -z "$signal_log" ] || {
    echo "expected unreadable ancestry teardown to be a no-op" >&2
    exit 1
}
unset -f kill
unset -f regolith_cosmic_runtime_parent_executable regolith_cosmic_runtime_parent_pid regolith_cosmic_runtime_parent_start_pid

stub_dir="$workdir/bin"
runtime_dir="$workdir/runtime"
mkdir -p "$stub_dir" "$runtime_dir/regolith-cosmic"

helper_script="$workdir/helpers.sh"
printf 'source "%s/usr/lib/regolith/regolith-session-cosmic.sh"\n' "$ROOT_DIR/" >"$helper_script"
printf 'wait_for_regolith_cosmic_wayland_socket() { return 0; }\n' >>"$helper_script"
printf 'wait_for_regolith_cosmic_sway_socket() { return 0; }\n' >>"$helper_script"

cat >"$stub_dir/systemctl" <<'EOF'
#!/bin/bash
if [ "$*" = "--user is-active --quiet cosmic-session.target" ]; then
    exit 3
fi
if [ "$2" = "is-enabled" ]; then
    echo disabled
fi
if [ "$2" = "import-environment" ] && [ -n "${REGOLITH_COSMIC_TEST_BLOCK_IMPORT:-}" ]; then
    printf '%s\n' ready >"$REGOLITH_COSMIC_TEST_BLOCK_IMPORT"
    sleep 1
fi
exit 0
EOF
chmod +x "$stub_dir/systemctl"

cat >"$stub_dir/cosmolith" <<'EOF'
#!/bin/bash
sleep 30 &
printf '%s\n' "$!" >"$REGOLITH_COSMIC_TEST_HELPER_DESCENDANT_PID"
printf '%s\n' "$BASHPID" >"$REGOLITH_COSMIC_TEST_HELPER_PID"
while :; do sleep 1; done
EOF
chmod +x "$stub_dir/cosmolith"

cat >"$stub_dir/cosmic-osd" <<'EOF'
#!/bin/bash
printf '%s\n' "$BASHPID" >"$REGOLITH_COSMIC_TEST_DELAYED_HELPER_PID"
while :; do sleep 1; done
EOF
chmod +x "$stub_dir/cosmic-osd"

cat >"$stub_dir/sway" <<'EOF'
#!/bin/bash
sleep 30 &
printf '%s\n' "$!" >"$REGOLITH_COSMIC_TEST_COMPOSITOR_DESCENDANT_PID"
while :; do sleep 1; done
EOF
chmod +x "$stub_dir/sway"

export PATH="$stub_dir:$PATH"
export XDG_RUNTIME_DIR="$runtime_dir"
export REGOLITH_COSMIC_TEST_HELPER_PID="$workdir/helper.pid"
export REGOLITH_COSMIC_TEST_HELPER_DESCENDANT_PID="$workdir/helper-descendant.pid"
export REGOLITH_COSMIC_TEST_DELAYED_HELPER_PID="$workdir/delayed-helper.pid"
export REGOLITH_COSMIC_TEST_COMPOSITOR_DESCENDANT_PID="$workdir/compositor-descendant.pid"
export REGOLITH_COSMIC_SESSION_HELPERS="$helper_script"
export REGOLITH_COSMIC_ENABLE_OSD=true
export REGOLITH_COSMIC_OSD_DELAY_SECONDS=10

# Cleanup is deliberately safe to repeat because the runtime's EXIT trap calls
# it after the normal compositor-exit path has already cleaned up.
regolith_cosmic_runtime_cleanup
regolith_cosmic_runtime_cleanup

export REGOLITH_COSMIC_TEST_BLOCK_IMPORT="$workdir/early-term.ready"
"$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic-runtime" sway >"$workdir/early-runtime.log" 2>&1 &
early_runtime_pid="$!"
for _ in $(seq 1 50); do
    [ -e "$REGOLITH_COSMIC_TEST_BLOCK_IMPORT" ] && break
    sleep 0.02
done
if [ ! -e "$REGOLITH_COSMIC_TEST_BLOCK_IMPORT" ]; then
    echo "expected early teardown synchronization point" >&2
    exit 1
fi
kill -TERM "$early_runtime_pid"
early_status=0
wait "$early_runtime_pid" 2>/dev/null || early_status="$?"
if [ "$early_status" -ne 143 ]; then
    echo "expected early TERM to preserve runtime status 143, got $early_status" >&2
    exit 1
fi
if [ ! -s "$REGOLITH_COSMIC_TEST_COMPOSITOR_DESCENDANT_PID" ] ||
    kill -0 "$(cat "$REGOLITH_COSMIC_TEST_COMPOSITOR_DESCENDANT_PID")" >/dev/null 2>&1; then
    echo "expected early teardown to stop compositor descendants" >&2
    exit 1
fi
unset REGOLITH_COSMIC_TEST_BLOCK_IMPORT

"$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic-runtime" sway >"$workdir/runtime.log" 2>&1 &
runtime_pid="$!"

for _ in $(seq 1 50); do
    if [ -s "$workdir/helper.pid" ]; then
        break
    fi
    sleep 0.1
done

if [ ! -s "$workdir/helper.pid" ]; then
    echo "expected COSMIC helper to start before teardown" >&2
    exit 1
fi

helper_pid="$(cat "$workdir/helper.pid")"
printf '%s\n' "$runtime_pid" "$helper_pid" "$(cat "$REGOLITH_COSMIC_TEST_HELPER_DESCENDANT_PID")" >"$workdir/pids"
kill -TERM "$runtime_pid"
runtime_status=0
wait "$runtime_pid" 2>/dev/null || runtime_status="$?"

if [ "$runtime_status" -ne 143 ]; then
    echo "expected TERM to preserve runtime status 143, got $runtime_status" >&2
    exit 1
fi

if kill -0 "$helper_pid" >/dev/null 2>&1; then
    echo "expected runtime teardown to stop owned COSMIC helper" >&2
    exit 1
fi

if kill -0 "$(cat "$REGOLITH_COSMIC_TEST_HELPER_DESCENDANT_PID")" >/dev/null 2>&1; then
    echo "expected runtime teardown to stop helper descendants" >&2
    exit 1
fi

if [ -s "$REGOLITH_COSMIC_TEST_DELAYED_HELPER_PID" ]; then
    echo "expected delayed helper not to start before teardown" >&2
    exit 1
fi

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
exit 0
EOF
chmod +x "$stub_dir/systemctl"

cat >"$stub_dir/cosmolith" <<'EOF'
#!/bin/bash
printf '%s\n' "$BASHPID" >"$REGOLITH_COSMIC_TEST_HELPER_PID"
while :; do sleep 1; done
EOF
chmod +x "$stub_dir/cosmolith"

cat >"$stub_dir/sway" <<'EOF'
#!/bin/bash
while :; do sleep 1; done
EOF
chmod +x "$stub_dir/sway"

export PATH="$stub_dir:$PATH"
export XDG_RUNTIME_DIR="$runtime_dir"
export REGOLITH_COSMIC_TEST_HELPER_PID="$workdir/helper.pid"
export REGOLITH_COSMIC_SESSION_HELPERS="$helper_script"

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
printf '%s\n' "$runtime_pid" "$helper_pid" >"$workdir/pids"
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

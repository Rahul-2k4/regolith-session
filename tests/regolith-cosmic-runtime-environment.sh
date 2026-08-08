#!/bin/bash

set -Eeu -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="$(mktemp -d)"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

stub_dir="$workdir/bin"
mkdir -p "$stub_dir"
log_file="$workdir/events.log"
runtime_script="$workdir/runtime.sh"
helper_script="$workdir/helper.sh"

cat >"$helper_script" <<'EOF'
wait_for_regolith_cosmic_wayland_socket() { return 0; }
wait_for_regolith_cosmic_sway_socket() { return 0; }
start_regolith_cosmic_helpers() { printf '%s\n' helpers >>"$REGOLITH_COSMIC_TEST_LOG"; }
EOF

sed "s|source \"\${REGOLITH_COSMIC_SESSION_HELPERS:-/usr/lib/regolith/regolith-session-cosmic.sh}\"|source \"$helper_script\"|" \
    "$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic-runtime" >"$runtime_script"
chmod +x "$runtime_script"

cat >"$stub_dir/systemctl" <<'EOF'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$REGOLITH_COSMIC_TEST_LOG"
case "${2-}" in
    is-active) exit 0 ;;
    is-enabled) printf '%s\n' disabled; exit 1 ;;
esac
EOF
chmod +x "$stub_dir/systemctl"

cat >"$stub_dir/bash" <<'EOF'
#!/bin/bash
printf '%s\n' compositor-start >>"$REGOLITH_COSMIC_TEST_LOG"
sleep 0.1
printf '%s\n' compositor-exit >>"$REGOLITH_COSMIC_TEST_LOG"
exit 0
EOF
chmod +x "$stub_dir/bash"

export PATH="$stub_dir:$PATH"
export REGOLITH_COSMIC_TEST_LOG="$log_file"
export WAYLAND_DISPLAY=wayland-1
export SWAYSOCK="$workdir/sway.sock"

python3 - "$SWAYSOCK" <<'PY' &
import socket
import sys
import time

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(sys.argv[1])
sock.listen(1)
time.sleep(2)
sock.close()
PY
socket_pid=$!

"$runtime_script" bash -c 'sleep 0.1'
wait "$socket_pid" || true

line_number() {
    local event="$1"
    awk -v event="$event" '$0 == event { print NR; exit }' "$log_file"
}

import_line="$(line_number 'systemctl --user import-environment WAYLAND_DISPLAY SWAYSOCK')"
restart_line="$(line_number 'systemctl --user restart regolith-cosmic.target')"
start_line="$(line_number 'systemctl --user start cosmic-session.target')"
unset_line="$(line_number 'systemctl --user unset-environment WAYLAND_DISPLAY SWAYSOCK')"

[ -n "$import_line" ] || { echo "missing WAYLAND_DISPLAY and SWAYSOCK import" >&2; exit 1; }
[ -n "$restart_line" ] || { echo "missing COSMIC target reinitialization" >&2; exit 1; }
[ -z "$start_line" ] || { echo "COSMIC target must be reinitialized, not merely started" >&2; exit 1; }
[ -n "$unset_line" ] || { echo "missing WAYLAND_DISPLAY and SWAYSOCK cleanup" >&2; exit 1; }
[ "$import_line" -lt "$restart_line" ] || { echo "compositor environment import must precede target reinitialization" >&2; exit 1; }
[ "$restart_line" -lt "$unset_line" ] || { echo "compositor environment cleanup must follow target lifecycle" >&2; exit 1; }

echo "COSMIC runtime environment lifecycle: PASS"

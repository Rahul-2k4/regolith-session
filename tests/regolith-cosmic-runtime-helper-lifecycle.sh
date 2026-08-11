#!/bin/bash

set -Eeu -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="$(mktemp -d)"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

stub_dir="$workdir/bin"
log_file="$workdir/events.log"
helper_script="$workdir/helpers.sh"
mkdir -p "$stub_dir"

cat >"$helper_script" <<'EOF'
wait_for_regolith_cosmic_wayland_socket() { return 0; }
wait_for_regolith_cosmic_sway_socket() { return 0; }
start_regolith_cosmic_helpers() { printf '%s\n' helpers >>"$REGOLITH_COSMIC_TEST_LOG"; }
EOF

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
sleep 0.2
EOF
chmod +x "$stub_dir/bash"

cat >"$stub_dir/setsid" <<'EOF'
#!/bin/bash
shift
exec "$@"
EOF
chmod +x "$stub_dir/setsid"

export PATH="$stub_dir:$PATH"
export REGOLITH_COSMIC_TEST_LOG="$log_file"
export REGOLITH_COSMIC_SESSION_HELPERS="$helper_script"
export XDG_CURRENT_DESKTOP="Regolith-Wayland:COSMIC:sway"
export WAYLAND_DISPLAY=wayland-1
export SWAYSOCK="$workdir/sway.sock"

"$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic-runtime" bash -c 'sleep 0.2'

if grep -Fqx 'systemctl --user restart regolith-cosmic.target' "$log_file"; then
    echo "successful COSMIC startup must not restart its already-active helper target" >&2
    exit 1
fi

grep -Fqx 'systemctl --user start regolith-cosmic.target' "$log_file" \
    || { echo "successful COSMIC startup must idempotently start its helper target" >&2; exit 1; }

echo "COSMIC helper target lifecycle: PASS"

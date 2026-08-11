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

line_number() {
    local event="$1"
    awk -v event="$event" '$0 == event { print NR; exit }' "$log_file"
}

if grep -Fqx 'systemctl --user restart regolith-cosmic.target' "$log_file"; then
    echo "successful COSMIC startup must not restart its already-active helper target" >&2
    exit 1
fi

target_start_line="$(line_number 'systemctl --user start regolith-cosmic.target')"
legacy_mask_line="$(line_number 'systemctl --user mask --runtime regolith-gnome.target')"
legacy_stop_line="$(line_number 'systemctl --user stop regolith-gnome.target')"
parent_stop_line="$(line_number 'systemctl --user stop cosmic-session.target')"

[ -n "$target_start_line" ] || { echo "successful COSMIC startup must idempotently start its helper target" >&2; exit 1; }
[ -n "$legacy_mask_line" ] || { echo "successful COSMIC startup must isolate the legacy GNOME target" >&2; exit 1; }
[ -n "$legacy_stop_line" ] || { echo "successful COSMIC startup must stop the legacy GNOME target" >&2; exit 1; }
[ -n "$parent_stop_line" ] || { echo "active COSMIC parent must stop after compositor exit" >&2; exit 1; }
[ "$legacy_mask_line" -lt "$target_start_line" ] \
    || { echo "legacy target isolation must precede COSMIC helper target startup" >&2; exit 1; }
[ "$legacy_stop_line" -lt "$target_start_line" ] \
    || { echo "legacy target shutdown must precede COSMIC helper target startup" >&2; exit 1; }

echo "COSMIC helper target lifecycle: PASS"

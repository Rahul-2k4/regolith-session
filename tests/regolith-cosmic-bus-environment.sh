#!/bin/bash
set -Eeu -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic-bus"
workdir="$(mktemp -d)"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

stub_dir="$workdir/bin"
mkdir -p "$stub_dir"
log_file="$workdir/events.log"

cat >"$stub_dir/systemctl" <<'EOF'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$REGOLITH_COSMIC_TEST_LOG"
EOF
chmod +x "$stub_dir/systemctl"

cat >"$stub_dir/child" <<'EOF'
#!/bin/bash
printf 'child XDG_CURRENT_DESKTOP=%s\n' "${XDG_CURRENT_DESKTOP-}" >>"$REGOLITH_COSMIC_TEST_LOG"
EOF
chmod +x "$stub_dir/child"

export PATH="$stub_dir:$PATH"
export REGOLITH_COSMIC_TEST_LOG="$log_file"
export XDG_CURRENT_DESKTOP="Regolith-Wayland:COSMIC:sway"
export XDG_SESSION_DESKTOP=cosmic
export XDG_SESSION_TYPE=wayland

"$HELPER" "$stub_dir/child"

grep -Fxq 'systemctl --user import-environment XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE' "$log_file"
grep -Fxq 'child XDG_CURRENT_DESKTOP=Regolith-Wayland:COSMIC:sway' "$log_file"

import_line="$(grep -nF 'systemctl --user import-environment' "$log_file" | cut -d: -f1)"
child_line="$(grep -nF 'child XDG_CURRENT_DESKTOP=' "$log_file" | cut -d: -f1)"
[ "$import_line" -lt "$child_line" ]

echo "COSMIC user-bus environment bootstrap: PASS"

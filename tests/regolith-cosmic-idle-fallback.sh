#!/bin/bash
set -Eeu -o pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
FALLBACK="$ROOT_DIR/usr/lib/regolith/regolith-cosmic-idle-fallback"
RUNTIME="$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic-runtime"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"
PATH="$TMP_DIR/bin:$PATH"
export PATH

cat >"$TMP_DIR/bin/swaymsg" <<'EOF'
#!/bin/bash
printf 'swaymsg %s\n' "$*" >>"$SWAY_TEST_LOG"
[ "${SWAYSOCK:-}" = "$SWAY_TEST_SOCKET" ] && [ "${SWAY_TEST_STALE:-0}" -eq 0 ]
EOF
cat >"$TMP_DIR/bin/swayidle" <<'EOF'
#!/bin/bash
printf 'swayidle %s\n' "$*" >>"$SWAY_TEST_LOG"
EOF
cat >"$TMP_DIR/bin/gtklock" <<'EOF'
#!/bin/bash
printf 'gtklock %s\n' "$*" >>"$SWAY_TEST_LOG"
EOF
cat >"$TMP_DIR/bin/systemctl" <<'EOF'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$SWAY_TEST_LOG"
case "$*" in
    "--user import-environment SWAYSOCK")
        printf 'SWAYSOCK=%s\n' "$SWAYSOCK" >"$SWAY_MANAGER_ENV"
        ;;
    "--user is-enabled regolith-gnome.target"|"--user is-enabled regolith-wayland.target")
        printf 'disabled\n'
        ;;
    "--user is-active --quiet cosmic-session.target")
        exit 3
        ;;
    "--user start cosmic-session.target")
        [ -f "$SWAY_MANAGER_ENV" ] || exit 1
        . "$SWAY_MANAGER_ENV"
        "$SWAY_TEST_FALLBACK"
        ;;
    "--user mask --runtime regolith-gnome.target"|"--user mask --runtime regolith-wayland.target"|"--user stop regolith-gnome.target"|"--user stop regolith-wayland.target"|"--user unmask regolith-gnome.target"|"--user unmask regolith-wayland.target"|"--user stop cosmic-session.target")
        ;;
    "--user unset-environment SWAYSOCK")
        rm -f "$SWAY_MANAGER_ENV"
        ;;
esac
EOF
cat >"$TMP_DIR/compositor" <<'EOF'
#!/bin/bash
sleep 1
EOF
cat >"$TMP_DIR/helpers" <<'EOF'
#!/bin/bash
wait_for_regolith_cosmic_wayland_socket() { return 0; }
wait_for_regolith_cosmic_sway_socket() {
    SWAYSOCK="$SWAY_TEST_SOCKET"
    export SWAYSOCK
    return 0
}
start_regolith_cosmic_helpers() { :; }
EOF
chmod +x "$TMP_DIR/bin/"*
chmod +x "$TMP_DIR/compositor"
SWAY_TEST_LOG="$TMP_DIR/log"
SWAY_TEST_SOCKET="$TMP_DIR/sway.sock"
SWAY_MANAGER_ENV="$TMP_DIR/manager-environment"
SWAY_TEST_FALLBACK="$FALLBACK"
export SWAY_TEST_LOG SWAY_TEST_SOCKET SWAY_MANAGER_ENV SWAY_TEST_FALLBACK

if SWAYSOCK="$TMP_DIR/missing.sock" "$FALLBACK"; then
    echo "missing SWAYSOCK unexpectedly started fallback" >&2
    exit 1
fi
touch "$SWAY_TEST_SOCKET"
if SWAYSOCK="$SWAY_TEST_SOCKET" "$FALLBACK"; then
    echo "non-socket SWAYSOCK unexpectedly started fallback" >&2
    exit 1
fi
rm "$SWAY_TEST_SOCKET"
python3 - "$SWAY_TEST_SOCKET" <<'PY'
import socket
import sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.close()
PY
if SWAYSOCK="$SWAY_TEST_SOCKET" SWAY_TEST_STALE=1 "$FALLBACK"; then
    echo "stale SWAYSOCK unexpectedly started fallback" >&2
    exit 1
fi
REGOLITH_COSMIC_SESSION_HELPERS="$TMP_DIR/helpers" "$RUNTIME" "$TMP_DIR/compositor"
[ "$(grep -c '^swayidle ' "$SWAY_TEST_LOG")" -eq 1 ] || { echo "expected one swayidle owner" >&2; exit 1; }
grep -Fqx 'swaymsg -t get_version' "$SWAY_TEST_LOG"
grep -Fq -- 'gtklock' "$SWAY_TEST_LOG"
import_line="$(grep -n 'systemctl --user import-environment SWAYSOCK' "$SWAY_TEST_LOG" | cut -d: -f1)"
start_line="$(grep -n 'systemctl --user start cosmic-session.target' "$SWAY_TEST_LOG" | cut -d: -f1)"
[ -n "$import_line" ] && [ -n "$start_line" ] && [ "$import_line" -lt "$start_line" ] || { echo "manager import did not precede target activation" >&2; exit 1; }
grep -Fqx 'systemctl --user stop cosmic-session.target' "$SWAY_TEST_LOG"
grep -Fqx 'systemctl --user mask --runtime regolith-gnome.target' "$SWAY_TEST_LOG"
grep -Fqx 'systemctl --user mask --runtime regolith-wayland.target' "$SWAY_TEST_LOG"
grep -Fqx 'systemctl --user unmask regolith-gnome.target' "$SWAY_TEST_LOG"
grep -Fqx 'systemctl --user unmask regolith-wayland.target' "$SWAY_TEST_LOG"
grep -Fqx 'systemctl --user unset-environment SWAYSOCK' "$SWAY_TEST_LOG"
[ ! -e "$SWAY_MANAGER_ENV" ] || { echo "manager SWAYSOCK was not cleared" >&2; exit 1; }
if grep -Fq 'systemctl --user start regolith-cosmic.target' "$SWAY_TEST_LOG"; then
    echo "runtime bypassed cosmic-session.target activation" >&2
    exit 1
fi
if grep -Eq 'cosmic-idle|regolith-init-powerd' "$SWAY_TEST_LOG"; then
    echo "native idle or power daemon was invoked" >&2
    exit 1
fi
echo "COSMIC idle fallback: PASS"

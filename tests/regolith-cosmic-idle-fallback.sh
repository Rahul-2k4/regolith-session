#!/bin/bash
set -Eeu -o pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
FALLBACK="$ROOT_DIR/usr/lib/regolith/regolith-cosmic-idle-fallback"
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
chmod +x "$TMP_DIR/bin/"*
SWAY_TEST_LOG="$TMP_DIR/log"
SWAY_TEST_SOCKET="$TMP_DIR/sway.sock"
export SWAY_TEST_LOG SWAY_TEST_SOCKET

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
SWAYSOCK="$SWAY_TEST_SOCKET" "$FALLBACK"
[ "$(grep -c '^swayidle ' "$SWAY_TEST_LOG")" -eq 1 ] || { echo "expected one swayidle owner" >&2; exit 1; }
grep -Fqx 'swaymsg -t get_version' "$SWAY_TEST_LOG"
grep -Fq -- 'gtklock' "$SWAY_TEST_LOG"
if grep -Eq 'cosmic-idle|regolith-init-powerd' "$SWAY_TEST_LOG"; then
    echo "native idle or power daemon was invoked" >&2
    exit 1
fi
echo "COSMIC idle fallback: PASS"

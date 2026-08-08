#!/bin/bash
set -Eeu -o pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TARGET="$ROOT_DIR/usr/lib/systemd/user/regolith-cosmic.target"
SERVICE="$ROOT_DIR/usr/lib/systemd/user/regolith-init-cosmic-idle.service"
INSTALL="$ROOT_DIR/debian/regolith-session-cosmic.install"
FALLBACK="$ROOT_DIR/usr/lib/regolith/regolith-cosmic-idle-fallback"

fail() { echo "COSMIC idle fallback test: $*" >&2; exit 1; }
has_line() { grep -Fqx "$2" "$1"; }

has_line "$TARGET" "Wants=regolith-init-inputd.service regolith-init-displayd.service regolith-init-cosmic-idle.service" || fail "COSMIC target does not own the idle service"
has_line "$SERVICE" "ExecStart=/usr/lib/regolith/regolith-cosmic-idle-fallback" || fail "idle service does not execute the fallback"
if grep -Fq "ExecStart=/usr/bin/cosmic-idle" "$SERVICE"; then fail "default idle service starts native cosmic-idle"; fi
has_line "$SERVICE" "PartOf=regolith-cosmic.target" || fail "idle service is not stopped with the COSMIC target"
has_line "$INSTALL" "usr/lib/systemd/user/regolith-init-cosmic-idle.service" || fail "fallback service is not packaged"
has_line "$INSTALL" "usr/lib/regolith/regolith-cosmic-idle-fallback" || fail "fallback script is not packaged"
cosmic_control="$(sed -n '/^Package: regolith-session-cosmic$/,/^Package: /p' "$ROOT_DIR/debian/control")"
if printf "%s\n" "$cosmic_control" | grep -Eq '^[[:space:]]+cosmic-idle,$'; then fail "default COSMIC package metadata pulls native cosmic-idle"; fi
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
bin_dir="$workdir/bin"
mkdir -p "$bin_dir"
printf '#!/bin/bash
exit 0
' > "$bin_dir/swaymsg"
printf '#!/bin/bash
echo "$*" >> "${FALLBACK_TEST_LOG:?}"
exit 0
' > "$bin_dir/swayidle"
printf '#!/bin/bash
exit 0
' > "$bin_dir/gtklock"
chmod +x "$bin_dir"/*
if PATH="$bin_dir:$PATH" SWAYSOCK="$workdir/missing.sock" FALLBACK_TEST_LOG="$workdir/log" "$FALLBACK"; then fail "missing SWAYSOCK was accepted"; fi
printf x > "$workdir/stale.sock"
if PATH="$bin_dir:$PATH" SWAYSOCK="$workdir/stale.sock" FALLBACK_TEST_LOG="$workdir/log" "$FALLBACK"; then fail "stale SWAYSOCK was accepted"; fi
socket="$workdir/sway.sock"
python3 - "$socket" <<'PY' &
import socket, sys, time
server = socket.socket(socket.AF_UNIX)
server.bind(sys.argv[1])
server.listen(1)
time.sleep(5)
PY
socket_pid=$!
for _ in 1 2 3 4 5; do [ -S "$socket" ] && break; sleep 0.1; done
[ -S "$socket" ] || fail "test socket was not created"
trap 'kill "$socket_pid" 2>/dev/null || true; rm -rf "$workdir"' EXIT
PATH="$bin_dir:$PATH" SWAYSOCK="$socket" FALLBACK_TEST_LOG="$workdir/log" "$FALLBACK"
wait "$socket_pid" 2>/dev/null || true
[ "$(wc -l < "$workdir/log" | tr -d " ")" = 1 ] || fail "fallback did not start exactly once"
grep -Fq -- "timeout 300 gtklock" "$workdir/log" || fail "fallback did not invoke swayidle with gtklock"
echo "COSMIC idle fallback: PASS"

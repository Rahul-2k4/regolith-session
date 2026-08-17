#!/bin/bash
set -Eeu -o pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
FALLBACK="$ROOT_DIR/usr/lib/regolith/regolith-cosmic-idle-fallback"
SERVICE="$ROOT_DIR/usr/lib/systemd/user/regolith-init-cosmic-idle.service"
TARGET="$ROOT_DIR/usr/lib/systemd/user/regolith-cosmic.target"
GNOME_TARGET="$ROOT_DIR/usr/lib/systemd/user/regolith-gnome.target"

fail() { echo "COSMIC native idle gate test: $*" >&2; exit 1; }
grep -Fqx "ExecStart=/usr/lib/regolith/regolith-cosmic-idle-fallback" "$SERVICE" ||
    fail "COSMIC idle service does not use the wrapper"
grep -Fqx "Wants=regolith-init-inputd.service regolith-init-displayd.service regolith-init-cosmic-idle.service" "$TARGET" ||
    fail "COSMIC target does not own idle"
grep -Fq "regolith-init-cosmic-idle.service" "$GNOME_TARGET" &&
    fail "GNOME target owns COSMIC idle"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
bin_dir="$workdir/bin"
mkdir -p "$bin_dir"
printf '#!/bin/bash
exit 0
' > "$bin_dir/swaymsg"
printf '#!/bin/bash
exit 1
' > "$bin_dir/pgrep"
printf '#!/bin/bash
printf "fallback:timeout 300 gtklock\n" >> "${IDLE_TEST_LOG:?}"
' > "$bin_dir/swayidle"
printf '#!/bin/bash
exit 0
' > "$bin_dir/gtklock"
printf '#!/bin/bash
printf "native\n" >> "${IDLE_TEST_LOG:?}"
' > "$bin_dir/cosmic-idle"
printf '#!/bin/bash
exit 0
' > "$bin_dir/cosmic-comp"
chmod +x "$bin_dir"/*
export PATH="$bin_dir:$PATH"
export IDLE_TEST_LOG="$workdir/log"
gnome_sha_before=$(sha256sum "$GNOME_TARGET")

socket="$workdir/sway.sock"
python3 - "$socket" <<'PY' &
import socket, sys, time
server = socket.socket(socket.AF_UNIX)
server.bind(sys.argv[1])
server.listen(1)
time.sleep(5)
PY
socket_pid=$!
trap 'kill "$socket_pid" 2>/dev/null || true; rm -rf "$workdir"' EXIT
for _ in 1 2 3 4 5; do [ -S "$socket" ] && break; sleep 0.1; done
[ -S "$socket" ] || fail "test socket was not created"
SWAYSOCK="$socket" XDG_CURRENT_DESKTOP=Regolith-Wayland:sway "$FALLBACK"
grep -Fq -- "fallback:" "$workdir/log" && grep -Fq -- "timeout 300 gtklock" "$workdir/log" ||
    fail "non-native COSMIC path did not preserve swayidle fallback"

printf '#!/bin/bash
if [ "$1" = "-x" ] && [ "$2" = "cosmic-comp" ]; then exit 0; fi
exit 1
' > "$bin_dir/pgrep"
chmod +x "$bin_dir/pgrep"
: > "$workdir/log"
XDG_CURRENT_DESKTOP="Regolith-Wayland:COSMIC:sway" SWAYSOCK= "$FALLBACK"
grep -Fqx "native" "$workdir/log" ||
    fail "native COSMIC path did not start cosmic-idle"
gnome_sha_after=$(sha256sum "$GNOME_TARGET")
[ "$gnome_sha_before" = "$gnome_sha_after" ] || fail "GNOME target changed"

echo "COSMIC native idle gate: PASS"

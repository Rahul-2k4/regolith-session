#!/bin/bash
set -Eeu -o pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TARGET="$ROOT_DIR/usr/lib/systemd/user/regolith-cosmic.target"
SERVICE="$ROOT_DIR/usr/lib/systemd/user/regolith-init-cosmic-idle.service"
INSTALL="$ROOT_DIR/debian/regolith-session-cosmic.install"

fail() { echo "COSMIC native idle ownership test: $*" >&2; exit 1; }
has_line() { grep -Fqx "$2" "$1"; }

has_line "$TARGET" "Wants=regolith-init-inputd.service regolith-init-displayd.service regolith-init-cosmic-idle.service" || fail "COSMIC target does not own the idle service"
has_line "$SERVICE" "ExecStart=/usr/bin/cosmic-idle" || fail "idle service does not execute native cosmic-idle"
if grep -Fq 'swayidle' "$SERVICE"; then fail "idle service still invokes swayidle"; fi
if grep -Fq 'regolith-cosmic-idle-fallback' "$SERVICE"; then fail "idle service still invokes fallback script"; fi
if [ -e "$ROOT_DIR/usr/lib/regolith/regolith-cosmic-idle-fallback" ]; then fail "fallback script is still installed in source tree"; fi
if grep -Fq 'regolith-cosmic-idle-fallback' "$INSTALL"; then fail "fallback script is still packaged"; fi
if grep -Fq 'swayidle' "$INSTALL"; then fail "fallback executable is still package-owned"; fi
if grep -Fq 'gtklock' "$INSTALL"; then fail "fallback lock executable is still package-owned"; fi
has_line "$INSTALL" "usr/lib/systemd/user/regolith-init-cosmic-idle.service" || fail "native idle service is not packaged"
echo "COSMIC native idle ownership: PASS"

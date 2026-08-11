#!/bin/bash
set -Eeu -o pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CONTROL="$ROOT_DIR/debian/control"

fail() { echo "session package metadata test: $*" >&2; exit 1; }

[ -f "$CONTROL" ] || fail "missing debian/control"
common_control=$(sed -n '/^Package: regolith-session-common$/,/^Package: /p' "$CONTROL")
[ -n "$common_control" ] || fail "regolith-session-common stanza is missing"

if printf '%s\n' "$common_control" | grep -Eq '^[[:space:]]+regolith-resource-loader([,[:space:]]|$)'; then
    fail "regolith-session-common depends on nonexistent regolith-resource-loader"
fi
if ! printf '%s\n' "$common_control" | grep -Eq '^[[:space:]]+regolith-look-default-loader([,[:space:]]|$)'; then
    fail "regolith-session-common does not depend on regolith-look-default-loader"
fi

echo "session package metadata: PASS"

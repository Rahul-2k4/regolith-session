#!/bin/bash
set -Eeu -o pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CONTROL="$ROOT_DIR/debian/control"

fail() { echo "session package metadata test: $*" >&2; exit 1; }

[ -f "$CONTROL" ] || fail "missing debian/control"
common_control=$(sed -n '/^Package: regolith-session-common$/,/^Package: /p' "$CONTROL")
[ -n "$common_control" ] || fail "regolith-session-common stanza is missing"

gnome_targets_control=$(sed -n '/^Package: regolith-session-gnome-targets$/,/^Package: /p' "$CONTROL")
[ -n "$gnome_targets_control" ] || fail "regolith-session-gnome-targets stanza is missing"

sway_control=$(sed -n '/^Package: regolith-session-sway$/,/^Package: /p' "$CONTROL")
[ -n "$sway_control" ] || fail "regolith-session-sway stanza is missing"

flashback_control=$(sed -n '/^Package: regolith-session-flashback$/,/^Package: /p' "$CONTROL")
[ -n "$flashback_control" ] || fail "regolith-session-flashback stanza is missing"

cosmic_control=$(sed -n '/^Package: regolith-session-cosmic$/,/^Package: /p' "$CONTROL")
[ -n "$cosmic_control" ] || fail "regolith-session-cosmic stanza is missing"

if printf '%s\\n' "$flashback_control" | grep -Eq '^[[:space:]]+xorg([,[:space:]]|$)'; then
    fail "flashback package directly depends on the xorg metapackage"
fi
if printf '%s\\n' "$flashback_control" | grep -Eq '^[[:space:]]+xserver-xorg([,[:space:]]|$)'; then
    fail "flashback package replaced xorg with xserver-xorg"
fi

gnome_targets_install="$ROOT_DIR/debian/regolith-session-gnome-targets.install"
[ -f "$gnome_targets_install" ] || fail "GNOME target install manifest is missing"

for target_path in \
    usr/lib/systemd/user/regolith-gnome.target \
    usr/lib/systemd/user/gnome-session.target.d
do
    grep -Fxq "$target_path" "$gnome_targets_install" || \
        fail "GNOME target package does not own $target_path"
    if grep -Fxq "$target_path" "$ROOT_DIR/debian/regolith-session-common.install"; then
        fail "common package still owns $target_path"
    fi
done

if printf '%s\n' "$cosmic_control" | grep -Eq '^[[:space:]]+regolith-session-gnome-targets([,[:space:]]|$)'; then
    fail "COSMIC package depends on GNOME-only target package"
fi
for legacy_control in "$sway_control" "$flashback_control"
do
    printf '%s\n' "$legacy_control" | grep -Eq '^[[:space:]]+regolith-session-gnome-targets([,[:space:]]|$)' || \
        fail "legacy session package does not depend on GNOME target package"
done

printf '%s\n' "$gnome_targets_control" | grep -Eq '^Replaces:.*regolith-session-common' || \
    fail "GNOME target package does not replace the former common ownership"
printf '%s\n' "$gnome_targets_control" | grep -Eq '^Breaks:.*regolith-session-common' || \
    fail "GNOME target package does not break incompatible common ownership"
if printf '%s\n' "$common_control" | grep -Eq '^[[:space:]]+regolith-resource-loader([,[:space:]]|$)'; then
    fail "regolith-session-common depends on nonexistent regolith-resource-loader"
fi
if ! printf '%s\n' "$common_control" | grep -Eq '^[[:space:]]+regolith-look-default-loader([,[:space:]]|$)'; then
    fail "regolith-session-common does not depend on regolith-look-default-loader"
fi

echo "session package metadata: PASS"

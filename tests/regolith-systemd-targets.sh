#!/bin/bash
set -Eeu -o pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
GNOME_TARGET="$ROOT_DIR/usr/lib/systemd/user/regolith-gnome.target"
COSMIC_TARGET="$ROOT_DIR/usr/lib/systemd/user/regolith-cosmic.target"
GNOME_DROPIN="$ROOT_DIR/usr/lib/systemd/user/gnome-session.target.d/regolith-gnome.conf"
COSMIC_DROPIN="$ROOT_DIR/usr/lib/systemd/user/cosmic-session.target.d/regolith-cosmic.conf"

fail() { echo "systemd target test: $*" >&2; exit 1; }
has_line() { grep -Fqx "$2" "$1"; }

[ -f "$GNOME_TARGET" ] || fail "missing GNOME target"
[ -f "$COSMIC_TARGET" ] || fail "missing COSMIC target"
[ -f "$GNOME_DROPIN" ] || fail "missing GNOME parent drop-in"
[ -f "$COSMIC_DROPIN" ] || fail "missing COSMIC parent drop-in"
has_line "$GNOME_DROPIN" "[Unit]" || fail "GNOME parent drop-in section is missing"
has_line "$GNOME_DROPIN" "Wants=regolith-gnome.target" || fail "GNOME parent drop-in wiring is missing"
has_line "$COSMIC_DROPIN" "[Unit]" || fail "COSMIC parent drop-in section is missing"
has_line "$COSMIC_DROPIN" "Wants=regolith-cosmic.target" || fail "COSMIC parent drop-in wiring is missing"
has_line "$GNOME_TARGET" "After=gnome-session.target" || fail "GNOME ordering is missing"
has_line "$GNOME_TARGET" "PartOf=gnome-session.target" || fail "GNOME ownership is missing"
has_line "$GNOME_TARGET" "WantedBy=gnome-session.target" || fail "GNOME install wiring is missing"
has_line "$GNOME_TARGET" "Wants=regolith-init-inputd.service regolith-init-displayd.service regolith-init-kanshi.service" || fail "GNOME helper Wants are incomplete"
if grep -Fqx "Wants=gnome-session.target" "$GNOME_TARGET"; then fail "GNOME parent dependency cycle"; fi
has_line "$COSMIC_TARGET" "After=cosmic-session.target" || fail "COSMIC ordering is missing"
has_line "$COSMIC_TARGET" "PartOf=cosmic-session.target" || fail "COSMIC ownership is missing"
has_line "$COSMIC_TARGET" "WantedBy=cosmic-session.target" || fail "COSMIC install wiring is missing"
has_line "$COSMIC_TARGET" "Wants=regolith-init-inputd.service regolith-init-displayd.service" || fail "COSMIC helper Wants are incomplete"
if grep -Fqx "Wants=cosmic-session.target" "$COSMIC_TARGET"; then fail "COSMIC parent dependency cycle"; fi
if grep -Fq "kanshi" "$COSMIC_TARGET"; then fail "COSMIC target pulls kanshi"; fi
has_line "$ROOT_DIR/debian/regolith-session-sway.install" "usr/lib/systemd/user/regolith-gnome.target" || fail "GNOME target is not packaged"
has_line "$ROOT_DIR/debian/regolith-session-sway.install" "usr/lib/systemd/user/gnome-session.target.d" || fail "GNOME parent drop-in is not packaged"
has_line "$ROOT_DIR/debian/regolith-session-cosmic.install" "usr/lib/systemd/user/regolith-cosmic.target" || fail "COSMIC target is not packaged"
has_line "$ROOT_DIR/debian/regolith-session-cosmic.install" "usr/lib/systemd/user/cosmic-session.target.d" || fail "COSMIC parent drop-in is not packaged"
for source in "$ROOT_DIR/usr/bin/regolith-session-cosmic-launch" "$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic.sh"; do
    [ -f "$source" ] || fail "missing COSMIC launcher source: $source"
    if grep -Fq "regolith-init-inputd.service" "$source"; then fail "COSMIC launcher still masks inputd"; fi
    if grep -Fq "regolith-init-displayd.service" "$source"; then fail "COSMIC launcher still masks displayd"; fi
    if grep -Fq "regolith-init-kanshi.service" "$source"; then fail "COSMIC launcher still masks kanshi"; fi
    if grep -Fq "regolith_cosmic_start_existing_daemon" "$source"; then fail "COSMIC launcher still direct-starts a legacy daemon"; fi
done
echo "systemd target metadata: PASS"

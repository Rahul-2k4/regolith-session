#!/bin/bash
set -Eeu -o pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
GNOME_TARGET="$ROOT_DIR/usr/lib/systemd/user/regolith-gnome.target"
COSMIC_TARGET="$ROOT_DIR/usr/lib/systemd/user/regolith-cosmic.target"
COSMIC_INPUTD_DROPIN="$ROOT_DIR/usr/lib/systemd/user/regolith-init-inputd.service.d/20-regolith-cosmic-session.conf"
COSMIC_DISPLAYD_DROPIN="$ROOT_DIR/usr/lib/systemd/user/regolith-init-displayd.service.d/20-regolith-cosmic-session.conf"
COSMIC_IDLE_SERVICE="$ROOT_DIR/usr/lib/systemd/user/regolith-init-cosmic-idle.service"

fail() { echo "systemd target test: $*" >&2; exit 1; }
has_line() { grep -Fqx "$2" "$1"; }

[ -f "$GNOME_TARGET" ] || fail "missing GNOME target"
[ -f "$COSMIC_TARGET" ] || fail "missing COSMIC target"
has_line "$GNOME_TARGET" "After=gnome-session.target" || fail "GNOME ordering is missing"
has_line "$GNOME_TARGET" "PartOf=gnome-session.target" || fail "GNOME ownership is missing"
has_line "$GNOME_TARGET" "WantedBy=gnome-session.target" || fail "GNOME install wiring is missing"
has_line "$GNOME_TARGET" "Wants=regolith-init-inputd.service regolith-init-displayd.service regolith-init-kanshi.service" || fail "GNOME helper Wants are incomplete"
if grep -Fqx "Wants=gnome-session.target" "$GNOME_TARGET"; then fail "GNOME parent dependency cycle"; fi
has_line "$COSMIC_TARGET" "After=cosmic-session.target" || fail "COSMIC ordering is missing"
has_line "$COSMIC_TARGET" "PartOf=cosmic-session.target" || fail "COSMIC ownership is missing"
has_line "$COSMIC_TARGET" "WantedBy=cosmic-session.target" || fail "COSMIC install wiring is missing"
has_line "$COSMIC_TARGET" "Wants=regolith-init-inputd.service regolith-init-displayd.service regolith-init-cosmic-idle.service" || fail "COSMIC idle owner is not wanted"
if grep -Fqx "Wants=cosmic-session.target" "$COSMIC_TARGET"; then fail "COSMIC parent dependency cycle"; fi
if grep -Fq "kanshi" "$COSMIC_TARGET"; then fail "COSMIC target pulls kanshi"; fi
[ -f "$COSMIC_IDLE_SERVICE" ] || fail "COSMIC idle service is missing"
has_line "$COSMIC_IDLE_SERVICE" "After=cosmic-session.target regolith-cosmic.target" || fail "COSMIC idle ordering is missing"
has_line "$COSMIC_IDLE_SERVICE" "PartOf=regolith-cosmic.target" || fail "COSMIC idle ownership is missing"
has_line "$COSMIC_IDLE_SERVICE" "ExecStart=/usr/lib/regolith/regolith-cosmic-idle-fallback" || fail "COSMIC idle fallback is not the service command"
if grep -Fq "ExecStart=cosmic-idle" "$COSMIC_IDLE_SERVICE"; then fail "COSMIC idle service invokes native cosmic-idle"; fi
if grep -Fq "regolith-init-powerd" "$COSMIC_TARGET" "$COSMIC_IDLE_SERVICE"; then fail "COSMIC idle path pulls powerd"; fi
[ -f "$COSMIC_INPUTD_DROPIN" ] || fail "COSMIC inputd ordering drop-in is missing"
[ -f "$COSMIC_DISPLAYD_DROPIN" ] || fail "COSMIC displayd ordering drop-in is missing"
has_line "$COSMIC_INPUTD_DROPIN" "After=cosmic-session.target" || fail "COSMIC inputd ordering is missing"
has_line "$COSMIC_DISPLAYD_DROPIN" "After=cosmic-session.target" || fail "COSMIC displayd ordering is missing"
has_line "$ROOT_DIR/debian/regolith-session-cosmic.install" "usr/lib/systemd/user/regolith-init-inputd.service.d/20-regolith-cosmic-session.conf" || fail "COSMIC inputd ordering drop-in is not packaged"
has_line "$ROOT_DIR/debian/regolith-session-cosmic.install" "usr/lib/systemd/user/regolith-init-displayd.service.d/20-regolith-cosmic-session.conf" || fail "COSMIC displayd ordering drop-in is not packaged"
has_line "$ROOT_DIR/debian/regolith-session-cosmic.install" "usr/lib/systemd/user/regolith-init-cosmic-idle.service" || fail "COSMIC idle service is not packaged"
has_line "$ROOT_DIR/debian/regolith-session-cosmic.install" "usr/lib/regolith/regolith-cosmic-idle-fallback" || fail "COSMIC idle fallback is not packaged"
if grep -Fq "regolith-init-inputd.service.d" "$ROOT_DIR/debian/regolith-session-sway.install"; then fail "GNOME package gained COSMIC inputd ordering"; fi
if grep -Fq "regolith-init-displayd.service.d" "$ROOT_DIR/debian/regolith-session-sway.install"; then fail "GNOME package gained COSMIC displayd ordering"; fi
has_line "$ROOT_DIR/debian/regolith-session-sway.install" "usr/lib/systemd/user/regolith-gnome.target" || fail "GNOME target is not packaged"
has_line "$ROOT_DIR/debian/regolith-session-cosmic.install" "usr/lib/systemd/user/regolith-cosmic.target" || fail "COSMIC target is not packaged"
for source in "$ROOT_DIR/usr/bin/regolith-session-cosmic-launch" "$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic.sh"; do
    [ -f "$source" ] || fail "missing COSMIC launcher source: $source"
    if grep -Fq "regolith-init-inputd.service" "$source"; then fail "COSMIC launcher still masks inputd"; fi
    if grep -Fq "regolith-init-displayd.service" "$source"; then fail "COSMIC launcher still masks displayd"; fi
    if grep -Fq "regolith-init-kanshi.service" "$source"; then fail "COSMIC launcher still masks kanshi"; fi
    if grep -Fq "regolith_cosmic_start_existing_daemon" "$source"; then fail "COSMIC launcher still direct-starts a legacy daemon"; fi
done
echo "systemd target metadata: PASS"

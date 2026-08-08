#!/bin/bash
set -Eeu -o pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
GNOME_TARGET="$ROOT_DIR/usr/lib/systemd/user/regolith-gnome.target"
COSMIC_TARGET="$ROOT_DIR/usr/lib/systemd/user/regolith-cosmic.target"
GNOME_DROPIN="$ROOT_DIR/usr/lib/systemd/user/gnome-session.target.d/regolith-gnome.conf"
COSMIC_DROPIN="$ROOT_DIR/usr/lib/systemd/user/cosmic-session.target.d/regolith-cosmic.conf"
COSMIC_IDLE_SERVICE="$ROOT_DIR/usr/lib/systemd/user/regolith-init-cosmic-idle.service"
COSMIC_IDLE_FALLBACK="$ROOT_DIR/usr/lib/regolith/regolith-cosmic-idle-fallback"
COSMIC_RUNTIME="$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic-runtime"

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
has_line "$COSMIC_TARGET" "Wants=regolith-init-inputd.service regolith-init-displayd.service regolith-init-cosmic-idle.service" || fail "COSMIC idle owner is not target-owned"
if grep -Fqx "Wants=cosmic-session.target" "$COSMIC_TARGET"; then fail "COSMIC parent dependency cycle"; fi
if grep -Fq "kanshi" "$COSMIC_TARGET"; then fail "COSMIC target pulls kanshi"; fi
[ -f "$COSMIC_IDLE_SERVICE" ] || fail "missing COSMIC idle service"
[ -f "$COSMIC_IDLE_FALLBACK" ] || fail "missing COSMIC idle fallback"
[ -f "$COSMIC_RUNTIME" ] || fail "missing COSMIC runtime wrapper"
has_line "$COSMIC_IDLE_SERVICE" "After=cosmic-session.target" || fail "COSMIC idle service ordering is missing"
has_line "$COSMIC_IDLE_SERVICE" "PartOf=regolith-cosmic.target" || fail "COSMIC idle service ownership is missing"
has_line "$COSMIC_IDLE_SERVICE" "ExecStart=/usr/lib/regolith/regolith-cosmic-idle-fallback" || fail "COSMIC idle fallback is not selected"
grep -Fq 'SWAYSOCK' "$COSMIC_RUNTIME" || fail "COSMIC runtime does not handle SWAYSOCK"
grep -Fq 'import-environment SWAYSOCK' "$COSMIC_RUNTIME" || fail "COSMIC runtime does not import SWAYSOCK"
grep -Fq 'unset-environment SWAYSOCK' "$COSMIC_RUNTIME" || fail "COSMIC runtime does not clean up SWAYSOCK"
grep -Fq 'swayidle' "$COSMIC_IDLE_FALLBACK" || fail "COSMIC idle fallback does not use swayidle"
grep -Fq 'gtklock' "$COSMIC_IDLE_FALLBACK" || fail "COSMIC idle fallback does not use gtklock"
if grep -Fq 'systemctl suspend' "$COSMIC_IDLE_FALLBACK"; then fail "COSMIC idle fallback owns suspend policy"; fi
has_line "$ROOT_DIR/debian/regolith-session-sway.install" "usr/lib/systemd/user/regolith-gnome.target" || fail "GNOME target is not packaged"
has_line "$ROOT_DIR/debian/regolith-session-sway.install" "usr/lib/systemd/user/gnome-session.target.d" || fail "GNOME parent drop-in is not packaged"
has_line "$ROOT_DIR/debian/regolith-session-cosmic.install" "usr/lib/systemd/user/regolith-cosmic.target" || fail "COSMIC target is not packaged"
has_line "$ROOT_DIR/debian/regolith-session-cosmic.install" "usr/lib/systemd/user/cosmic-session.target.d" || fail "COSMIC parent drop-in is not packaged"
has_line "$ROOT_DIR/debian/regolith-session-cosmic.install" "usr/lib/systemd/user/regolith-init-cosmic-idle.service" || fail "COSMIC idle service is not packaged"
has_line "$ROOT_DIR/debian/regolith-session-cosmic.install" "usr/lib/regolith/regolith-cosmic-idle-fallback" || fail "COSMIC idle fallback is not packaged"
has_line "$ROOT_DIR/debian/regolith-session-cosmic.install" "usr/lib/regolith/regolith-session-cosmic-runtime" || fail "COSMIC runtime is not packaged"
cosmic_control="$(sed -n '/^Package: regolith-session-cosmic$/,/^Package: /p' "$ROOT_DIR/debian/control")"
printf '%s\n' "$cosmic_control" | grep -Eq '^[[:space:]]+swayidle,$' || fail "COSMIC package does not depend on swayidle"
printf '%s\n' "$cosmic_control" | grep -Eq '^[[:space:]]+gtklock,$' || fail "COSMIC package does not depend on gtklock"
has_line "$ROOT_DIR/debian/regolith-session-sway.install" "usr/share/wayland-sessions/regolith-wayland.desktop" || fail "Sway Wayland desktop entry is not packaged explicitly"
if grep -Fqx "usr/share/wayland-sessions" "$ROOT_DIR/debian/regolith-session-sway.install"; then fail "Sway package uses a broad Wayland desktop entry wildcard"; fi
if comm -12 <(sed -n "s#^usr/share/wayland-sessions/##p" "$ROOT_DIR/debian/regolith-session-sway.install" | sort) <(sed -n "s#^usr/share/wayland-sessions/##p" "$ROOT_DIR/debian/regolith-session-cosmic.install" | sort) | grep -q .; then fail "Sway and COSMIC packages own the same Wayland desktop entry"; fi
for source in "$ROOT_DIR/usr/bin/regolith-session-cosmic-launch" "$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic.sh"; do
    [ -f "$source" ] || fail "missing COSMIC launcher source: $source"
    if grep -Fq "regolith-init-inputd.service" "$source"; then fail "COSMIC launcher still masks inputd"; fi
    if grep -Fq "regolith-init-displayd.service" "$source"; then fail "COSMIC launcher still masks displayd"; fi
    if grep -Fq "regolith-init-kanshi.service" "$source"; then fail "COSMIC launcher still masks kanshi"; fi
    if grep -Fq "regolith_cosmic_start_existing_daemon" "$source"; then fail "COSMIC launcher still direct-starts a legacy daemon"; fi
done
echo "systemd target metadata: PASS"

#!/bin/bash
set -Eeu -o pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
RUNTIME="$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic-runtime"
LOG_FILE=$(mktemp)
trap 'rm -f "$LOG_FILE"' EXIT

fail() { echo "COSMIC powerd ownership test: $*" >&2; exit 1; }

gnome_state=enabled
wayland_state=enabled
powerd_state=enabled
fail_mask_target=
fail_stop_target=

fake_systemctl() {
    local action="${2-}"
    local target="${3-}"

    printf '%s\n' "$*" >>"$LOG_FILE"

    case "$action" in
        is-enabled)
            case "$target" in
                regolith-gnome.target) printf '%s\n' "$gnome_state" ;;
                regolith-wayland.target) printf '%s\n' "$wayland_state" ;;
                regolith-init-powerd.service) printf '%s\n' "$powerd_state" ;;
                *) return 1 ;;
            esac
            ;;
        mask)
            target="${4-}"
            [ "$target" != "$fail_mask_target" ] || return 1
            case "$target" in
                regolith-gnome.target) gnome_state=masked-runtime ;;
                regolith-wayland.target) wayland_state=masked-runtime ;;
                regolith-init-powerd.service) powerd_state=masked-runtime ;;
            esac
            ;;
        stop)
            [ "$target" != "$fail_stop_target" ] || return 1
            ;;
        unmask)
            case "$target" in
                regolith-gnome.target) gnome_state=enabled ;;
                regolith-wayland.target) wayland_state=enabled ;;
                regolith-init-powerd.service) powerd_state=enabled ;;
            esac
            ;;
        *) return 0 ;;
    esac
}

systemctl() { fake_systemctl "$@"; }
export -f systemctl fake_systemctl

# shellcheck disable=SC1090
REGOLITH_COSMIC_SESSION_HELPERS="$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic.sh"
export REGOLITH_COSMIC_SESSION_HELPERS
source "$RUNTIME"

target_started=true
mask_regolith_legacy_targets_for_cosmic || fail "enabled powerd isolation failed"
grep -Fqx -- "--user mask --runtime regolith-init-powerd.service" "$LOG_FILE" || fail "powerd was not masked"
grep -Fqx -- "--user stop regolith-init-powerd.service" "$LOG_FILE" || fail "powerd was not stopped"
[ "$powerd_state" = masked-runtime ] || fail "powerd was not left masked during COSMIC"

regolith_cosmic_runtime_cleanup
[ "$powerd_state" = enabled ] || fail "owned powerd mask was not removed"

: >"$LOG_FILE"
gnome_state=masked
wayland_state=masked-runtime
powerd_state=masked-runtime
mask_regolith_legacy_targets_for_cosmic || fail "pre-masked powerd isolation failed"
regolith_cosmic_runtime_cleanup
if grep -Fq -- "--user unmask regolith-init-powerd.service" "$LOG_FILE"; then
    fail "pre-existing powerd mask was removed"
fi

echo "COSMIC powerd ownership: PASS"

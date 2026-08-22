#!/bin/bash

set -Eeu -o pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
LOG_FILE=$(mktemp)
trap 'rm -f "$LOG_FILE"' EXIT

fail() { echo "COSMIC optional legacy target test: $*" >&2; exit 1; }

fake_systemctl() {
    local action="${2-}"
    local target="${3-}"

    printf '%s\n' "$*" >>"$LOG_FILE"

    case "$action" in
        is-enabled)
            printf '%s\n' not-found
            return 1
            ;;
        mask)
            target="${4-}"
            ;;
        stop)
            ;;
        *)
            return 0
            ;;
    esac
}

systemctl() { fake_systemctl "$@"; }
export -f systemctl fake_systemctl

# shellcheck disable=SC1090
REGOLITH_COSMIC_SESSION_HELPERS="$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic.sh"
export REGOLITH_COSMIC_SESSION_HELPERS
source "$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic-runtime"

if regolith_legacy_target_is_pre_masked regolith-gnome.target; then
    fail "not-found optional target was treated as pre-masked"
else
    state_status=$?
    [ "$state_status" -eq 1 ] || fail "not-found optional target was rejected with status $state_status"
fi

mask_regolith_legacy_targets_for_cosmic || fail "not-found optional targets prevented masking"

for target in regolith-gnome.target regolith-wayland.target regolith-init-powerd.service; do
    grep -Fqx -- "--user mask --runtime $target" "$LOG_FILE" || fail "optional target was not masked: $target"
    grep -Fqx -- "--user stop $target" "$LOG_FILE" || fail "optional target was not stopped: $target"
done

echo "COSMIC optional legacy targets: PASS"

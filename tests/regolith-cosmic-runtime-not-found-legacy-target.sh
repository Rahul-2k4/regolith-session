#!/bin/bash
# Regression test: a legacy Regolith unit that was never installed (systemctl
# reports "not-found", exit 4) must not abort the COSMIC session.
#
# regolith_legacy_target_is_pre_masked()'s case statement had no arm for
# "not-found". On a genuinely COSMIC-only install, where the GNOME-target
# package was never installed, `systemctl --user is-enabled
# regolith-gnome.target` returns exactly that: state "not-found", exit 4. The
# function fell through both case arms, returned 2, and the caller aborted the
# whole COSMIC session on the very first cold login of a correct install.

set -Eeu -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="$(mktemp -d)"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

stub_dir="$workdir/bin"
mkdir -p "$stub_dir"

# Everything the function under test can see is the legacy target/service
# genuinely not existing on disk, exactly like a COSMIC-only install.
cat >"$stub_dir/systemctl" <<'STUB'
#!/bin/bash
if [ "$2" = "is-enabled" ]; then
    printf 'not-found\n'
    exit 4
fi
if [ "$2" = "mask" ]; then
    exit 0
fi
if [ "$2" = "unmask" ]; then
    exit 0
fi
exit 0
STUB
chmod +x "$stub_dir/systemctl"

# Pull only the function under test out of the real script, so this test
# tracks the shipped code rather than a reimplementation of it.
source_lines="$(sed -n '/^regolith_legacy_target_is_pre_masked()/,/^}/p;/^mask_regolith_legacy_targets_for_cosmic()/,/^}/p' \
    "$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic-runtime")"
[ -n "$source_lines" ] || { echo "FAIL: could not extract the functions under test"; exit 1; }

legacy_gnome_target_mask_owned=false
legacy_wayland_target_mask_owned=false
legacy_powerd_mask_owned=false
eval "$source_lines"

PATH="$stub_dir:$PATH"
if mask_regolith_legacy_targets_for_cosmic; then
    echo "PASS: COSMIC session proceeds when legacy units are genuinely absent"
else
    echo "FAIL: mask_regolith_legacy_targets_for_cosmic aborted on a not-found legacy unit"
    exit 1
fi

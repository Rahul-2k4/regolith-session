#!/bin/bash

set -Eeu -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER_SCRIPT="$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic.sh"

if [ ! -f "$HELPER_SCRIPT" ]; then
    echo "missing helper script: $HELPER_SCRIPT" >&2
    exit 1
fi

workdir="$(mktemp -d)"
cleanup() {
    rm -rf "$workdir"
}
trap cleanup EXIT

stub_dir="$workdir/bin"
mkdir -p "$stub_dir"

cat >"$stub_dir/cosmic-settings" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$stub_dir/cosmic-settings"

trawldb_log="$workdir/trawldb.log"
cat >"$stub_dir/trawldb" <<'EOF'
#!/bin/bash
set -Eeu -o pipefail

if [ "$1" = "--merge" ]; then
    cat "$2" >"$REGOLITH_COSMIC_TRAWLDB_LOG"
    exit 0
fi

exit 0
EOF
chmod +x "$stub_dir/trawldb"

source_config="$workdir/source-config.toml"
cat >"$source_config" <<'EOF'
[[block]]
block = "sound"
driver = "pulseaudio"

[[block.click]]
button = "left"
cmd = "regolith-control-center sound"
EOF

export PATH="$stub_dir:$PATH"
export XDG_RUNTIME_DIR="$workdir/runtime"
export REGOLITH_COSMIC_TRAWLDB_LOG="$trawldb_log"
mkdir -p "$XDG_RUNTIME_DIR"

# shellcheck disable=SC1090
source "$HELPER_SCRIPT"

regolith_cosmic_configure_status_bar "$source_config"

target_config="$XDG_RUNTIME_DIR/regolith-cosmic/i3status-rust/config.toml"
if [ ! -f "$target_config" ]; then
    echo "expected runtime status config to be created" >&2
    exit 1
fi

if grep -Fq 'regolith-control-center sound' "$target_config"; then
    echo "expected runtime status config to remove regolith-control-center sound" >&2
    exit 1
fi

if ! grep -Fqx 'cmd = "cosmic-settings sound"' "$target_config"; then
    echo "expected runtime status config to use cosmic-settings sound" >&2
    exit 1
fi

if ! grep -Eq "^wm\\.bar\\.status_config :[[:space:]]+$target_config$" "$trawldb_log"; then
    echo "expected trawldb override for wm.bar.status_config" >&2
    exit 1
fi

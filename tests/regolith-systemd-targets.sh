#!/bin/bash
set -Eeu -o pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
GNOME_TARGET="$ROOT_DIR/usr/lib/systemd/user/regolith-gnome.target"
COSMIC_TARGET="$ROOT_DIR/usr/lib/systemd/user/regolith-cosmic.target"
GNOME_DROPIN="$ROOT_DIR/usr/lib/systemd/user/gnome-session.target.d/regolith-gnome.conf"
COSMIC_DROPIN="$ROOT_DIR/usr/lib/systemd/user/cosmic-session.target.d/regolith-cosmic.conf"
COSMIC_IDLE_SERVICE="$ROOT_DIR/usr/lib/systemd/user/regolith-init-cosmic-idle.service"
COSMIC_RUNTIME="$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic-runtime"

fail() { echo "systemd target test: $*" >&2; exit 1; }
has_line() { grep -Fqx "$2" "$1"; }
exactly_once() { [ "$(grep -Fxc "$2" "$1")" -eq 1 ]; }
package_stanza() {
  local package=$1 control_file=$2
  awk -v package="$package" '
    /^Package: / {
      if (found) exit
      found = ($2 == package)
    }
    found { print }
  ' "$control_file"
}
trim_install_path() {
  local path=$1
  path="${path#"${path%%[![:space:]]*}"}"
  path="${path%"${path##*[![:space:]]}"}"
  while [[ "$path" == */ ]]; do path=${path%/}; done
  printf '%s\n' "$path"
}
paths_overlap() {
  local first=$1 second=$2
  [[ "$first" == "$second" || "$first" == "$second"/* || "$second" == "$first"/* ]]
}
validate_install_manifest() {
  local install_file=$1 line_number=0 raw_line entry
  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    line_number=$((line_number + 1))
    entry=$(trim_install_path "$raw_line")
    case "$entry" in
      ""|\#*) continue ;;
    esac
    if [[ "$entry" == *'*'* || "$entry" == *'?'* || "$entry" == *'['* || "$entry" == *']'* ]]; then
      fail "unsupported wildcard syntax in $(basename "$install_file"):$line_number"
    fi
    case "$entry" in
      -*|*\\*) fail "unsupported dh_install syntax in $(basename "$install_file"):$line_number" ;;
      *[[:space:]]*) fail "source/destination syntax is not supported in $(basename "$install_file"):$line_number" ;;
    esac
  done < "$install_file"
}

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
if grep -Fq "regolith-init-cosmic-idle.service" "$GNOME_TARGET"; then fail "GNOME target activates COSMIC idle"; fi
[ -f "$COSMIC_IDLE_SERVICE" ] || fail "missing COSMIC idle service"
[ -f "$COSMIC_RUNTIME" ] || fail "missing COSMIC runtime wrapper"
has_line "$COSMIC_IDLE_SERVICE" "After=cosmic-session.target" || fail "COSMIC idle service ordering is missing"
has_line "$COSMIC_IDLE_SERVICE" "PartOf=regolith-cosmic.target" || fail "COSMIC idle service ownership is missing"
has_line "$COSMIC_IDLE_SERVICE" "ExecStart=/usr/lib/regolith/regolith-cosmic-idle-fallback" || fail "COSMIC fallback is not selected"
grep -Fq 'SWAYSOCK' "$COSMIC_RUNTIME" || fail "COSMIC runtime does not handle SWAYSOCK"
grep -Fq 'import-environment XDG_CURRENT_DESKTOP WAYLAND_DISPLAY SWAYSOCK' "$COSMIC_RUNTIME" || fail "COSMIC runtime does not import session compositor environment"
grep -Fq 'unset-environment XDG_CURRENT_DESKTOP WAYLAND_DISPLAY SWAYSOCK' "$COSMIC_RUNTIME" || fail "COSMIC runtime does not clean up session compositor environment"
has_line "$ROOT_DIR/debian/regolith-session-gnome-targets.install" "usr/lib/systemd/user/regolith-gnome.target" || fail "GNOME target is not packaged in session-gnome-targets"
has_line "$ROOT_DIR/debian/regolith-session-gnome-targets.install" "usr/lib/systemd/user/gnome-session.target.d" || fail "GNOME parent drop-in is not packaged in session-gnome-targets"
has_line "$ROOT_DIR/debian/regolith-session-cosmic.install" "usr/lib/systemd/user/regolith-cosmic.target" || fail "COSMIC target is not packaged"
has_line "$ROOT_DIR/debian/regolith-session-cosmic.install" "usr/lib/systemd/user/cosmic-session.target.d" || fail "COSMIC parent drop-in is not packaged"
has_line "$ROOT_DIR/debian/regolith-session-cosmic.install" "usr/lib/systemd/user/regolith-init-cosmic-idle.service" || fail "COSMIC idle service is not packaged"
has_line "$ROOT_DIR/debian/regolith-session-cosmic.install" "usr/lib/regolith/regolith-session-cosmic-runtime" || fail "COSMIC runtime is not packaged"
for install_file in "$ROOT_DIR"/debian/regolith-session-*.install; do
  [ -f "$install_file" ] || continue
  validate_install_manifest "$install_file"
done
cosmic_only_paths=()
while IFS= read -r raw_line || [ -n "$raw_line" ]; do
  cosmic_path=$(trim_install_path "$raw_line")
  case "$cosmic_path" in
    ""|\#*) continue ;;
  esac
  cosmic_only_paths+=("$cosmic_path")
done < "$ROOT_DIR/debian/regolith-session-cosmic.install"
for cosmic_path in "${cosmic_only_paths[@]}"; do
  exactly_once "$ROOT_DIR/debian/regolith-session-cosmic.install" "$cosmic_path" \
    || fail "COSMIC artifact is not owned exactly once by session-cosmic: $cosmic_path"
  for install_file in "$ROOT_DIR"/debian/regolith-session-*.install; do
    [ -f "$install_file" ] || continue
    case "$install_file" in
      *regolith-session-cosmic.install) continue ;;
    esac
    while IFS= read -r sibling_path || [ -n "$sibling_path" ]; do
      sibling_path=$(trim_install_path "$sibling_path")
      case "$sibling_path" in
        ""|\#*) continue ;;
      esac
      if paths_overlap "$cosmic_path" "$sibling_path"; then
        fail "COSMIC-only artifact overlaps $(basename "$install_file"): $cosmic_path / $sibling_path"
      fi
    done < "$install_file"
  done
done
common_control="$(package_stanza regolith-session-common "$ROOT_DIR/debian/control")"
printf '%s\n' "$common_control" | grep -Fqx "Replaces: regolith-session-sway" \
  || fail "session-common does not declare the regolith-session-sway ownership transition"
gnome_targets_control="$(package_stanza regolith-session-gnome-targets "$ROOT_DIR/debian/control")"
printf '%s\n' "$gnome_targets_control" | grep -Eq '^Replaces:.*(^|, *)regolith-session-sway([, ]|$)' \
  || fail "session-gnome-targets does not declare the regolith-session-sway ownership transition"
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
# regolith-gnome.target is activated only by the gnome-session.target.d drop-in,
# which Wants= it. Both ship from regolith-session-gnome-targets because flashback and
# sway are co-installable without duplicate dpkg ownership, so
# duplicate paths would collide in dpkg, and shipping the target without its
# drop-in would leave it inert on the flashback path.
for gnome_path in usr/lib/systemd/user/regolith-gnome.target usr/lib/systemd/user/gnome-session.target.d; do
  for install_file in "$ROOT_DIR"/debian/regolith-session-*.install; do
    case "$install_file" in *regolith-session-gnome-targets.install) continue ;; esac
    has_line "$install_file" "$gnome_path" \
      && fail "duplicate owner of $gnome_path in $(basename "$install_file")"
  done
done
echo "systemd target metadata: PASS"

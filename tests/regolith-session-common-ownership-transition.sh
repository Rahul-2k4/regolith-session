#!/bin/bash
set -Eeu -o pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CONTROL="$ROOT_DIR/debian/control"

fail() { echo "session-common ownership transition: $*" >&2; exit 1; }

common_stanza=$(awk '
  /^Package: regolith-session-common$/ { in_stanza = 1 }
  in_stanza && /^Package: / && $0 != "Package: regolith-session-common" { exit }
  in_stanza { print }
' "$CONTROL")
[ -n "$common_stanza" ] || fail "missing regolith-session-common stanza"

field_values() {
  awk -v field="$1" '
    $0 ~ "^" field ":" {
      in_field = 1
      sub("^[^:]*:[[:space:]]*", "")
      print
      next
    }
    in_field && /^[[:space:]]/ {
      sub("^[[:space:]]*", "")
      print
      next
    }
    in_field { exit }
  '
}

has_package() {
  local field="$1"
  local package="$2"
  local values

  values=$(printf '%s\n' "$common_stanza" | field_values "$field" | tr '\n' ' ')
  printf '%s\n' "$values" | grep -Eq "(^|[[:space:],])${package}([[:space:]]*\\([^)]*\\))?([[:space:],]|$)"
}

has_unversioned_package() {
  local field="$1"
  local package="$2"
  local values

  values=$(printf '%s\n' "$common_stanza" | field_values "$field" | tr '\n' ' ')
  printf '%s\n' "$values" | grep -Eq "(^|[[:space:],])${package}[[:space:]]*([,]|$)"
}

for legacy_owner in \
  regolith-session-sway \
  regolith-session-flashback \
  regolith-session-gnome-targets; do
  has_package Replaces "$legacy_owner" \
    || fail "regolith-session-common must replace $legacy_owner for moved systemd files"

  for removal_field in Breaks Conflicts; do
    if has_unversioned_package "$removal_field" "$legacy_owner"; then
      fail "regolith-session-common must not unversionedly $removal_field $legacy_owner"
    fi
  done
done

package_test_override=$(sed -n '/^override_dh_auto_test:/,/^endif$/p' "$ROOT_DIR/debian/rules")
printf '%s\n' "$package_test_override" \
  | grep -Eq '^[[:space:]]+bash tests/regolith-session-common-ownership-transition\.sh$' \
  || fail "ownership transition test is not wired into override_dh_auto_test"

echo "session-common ownership transition: PASS"

#!/bin/bash
set -Eeu -o pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CHANGELOG="$ROOT_DIR/debian/changelog"
CONTROL="$ROOT_DIR/debian/control"

fail() { echo "package ownership test: $*" >&2; exit 1; }

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

has_entry() {
  local field="$1"
  local entry="$2"
  local values

  values=$(printf '%s\n' "$common_stanza" | field_values "$field" | tr '\n' ' ')
  printf '%s\n' "$values" | grep -Fq "$entry"
}

has_unversioned_entry() {
  local field="$1"
  local package="$2"
  local values

  values=$(printf '%s\n' "$common_stanza" | field_values "$field" | tr '\n' ' ')
  printf '%s\n' "$values" | grep -Eq "(^|[[:space:],])${package}[[:space:]]*([,]|$)"
}

source_version=$(sed -n '1s/^regolith-session (\([^)]*\)).*/\1/p' "$CHANGELOG")
[ "$source_version" = "1.2.0-1ubuntu2" ] \
  || fail "source version must be 1.2.0-1ubuntu2"
source_revision=${source_version#1.2.0-1ubuntu}
[[ "$source_revision" =~ ^[0-9]+$ ]] \
  || fail "source version must retain the 1.2.0-1ubuntu revision shape"
(( 10#$source_revision > 1 )) \
  || fail "source version must be newer than 1.2.0-1ubuntu1"

has_entry Breaks "regolith-session (<= 1.1.2)" \
  || fail "existing regolith-session Breaks must remain"
has_entry Conflicts "session-shortcuts" \
  || fail "existing session-shortcuts conflict must remain"
has_entry Conflicts "regolith-session-flashback (<= 0.6.4)" \
  || fail "existing versioned flashback conflict must remain"

for legacy_owner in \
  regolith-session-sway \
  regolith-session-flashback \
  regolith-session-gnome-targets; do
  for transition_field in Breaks Replaces; do
    has_entry "$transition_field" "$legacy_owner (<< \${binary:Version})" \
      || fail "missing versioned $transition_field for $legacy_owner"
    if has_unversioned_entry "$transition_field" "$legacy_owner"; then
      fail "unversioned $transition_field for $legacy_owner is not allowed"
    fi
  done
done

echo "package ownership test: PASS"

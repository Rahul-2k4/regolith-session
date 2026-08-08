#!/bin/bash
# Shared helpers for the experimental Regolith / COSMIC session path.

regolith_cosmic_bool_is_true() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
    esac

    return 1
}

regolith_cosmic_current_user() {
    if [ -n "${USER:-}" ]; then
        printf '%s\n' "$USER"
        return 0
    fi

    id -un
}

regolith_cosmic_process_is_running() {
    if regolith_cosmic_bool_is_true "${REGOLITH_COSMIC_DISABLE_PROCESS_CHECK:-false}"; then
        return 1
    fi

    local program="$1"
    local user=
    local escaped_program=

    user="$(regolith_cosmic_current_user)"
    escaped_program="$(printf '%s\n' "$program" | sed 's/[][(){}.^$+*?|\\/]/\\&/g')"

    pgrep -u "$user" -f "(^|/)$escaped_program( |$)" >/dev/null 2>&1
}


regolith_cosmic_configure_status_bar() {
    local source_config="${1:-/etc/regolith/i3status-rust/config.toml}"
    local runtime_dir="${XDG_RUNTIME_DIR:-}"
    local target_dir=
    local target_config=
    local override_file=

    if [ -z "$runtime_dir" ] || [ ! -f "$source_config" ]; then
        return 0
    fi

    if ! command -v cosmic-settings >/dev/null 2>&1; then
        return 0
    fi

    if ! grep -Fq 'cmd = "regolith-control-center sound"' "$source_config"; then
        return 0
    fi

    target_dir="$runtime_dir/regolith-cosmic/i3status-rust"
    target_config="$target_dir/config.toml"
    override_file="$runtime_dir/regolith-cosmic/wm.bar.status_config"

    mkdir -p "$target_dir"
    sed 's|cmd = "regolith-control-center sound"|cmd = "cosmic-settings sound"|' "$source_config" >"$target_config"

    printf 'wm.bar.status_config :\t%s\n' "$target_config" >"$override_file"
    trawldb --merge "$override_file"
}

regolith_cosmic_start_optional_process() {
    local program="$1"
    shift || true

    if ! command -v "$program" >/dev/null 2>&1; then
        return 0
    fi

    if regolith_cosmic_process_is_running "$program"; then
        return 0
    fi

    nohup "$program" "$@" >/dev/null 2>&1 &
}

regolith_cosmic_start_optional_process_after() {
    local delay_seconds="$1"
    local program="$2"
    shift 2 || true

    if ! command -v "$program" >/dev/null 2>&1; then
        return 0
    fi

    if regolith_cosmic_process_is_running "$program"; then
        return 0
    fi

    nohup bash -c 'sleep "$1"; shift; exec "$@"' bash "$delay_seconds" "$program" "$@" >/dev/null 2>&1 &
}


regolith_cosmic_wayland_socket_path() {
    local runtime_dir="${XDG_RUNTIME_DIR-}"
    local display_name="${WAYLAND_DISPLAY-}"
    local candidate=

    if [ -z "$runtime_dir" ]; then
        return 1
    fi

    if [ -n "$display_name" ] && [ -S "$runtime_dir/$display_name" ]; then
        printf '%s\n' "$runtime_dir/$display_name"
        return 0
    fi

    for candidate in "$runtime_dir"/wayland-*; do
        if [ -S "$candidate" ]; then
            WAYLAND_DISPLAY="$(basename "$candidate")"
            export WAYLAND_DISPLAY
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

wait_for_regolith_cosmic_wayland_socket() {
    local attempt=

    for attempt in $(seq 1 50); do
        if regolith_cosmic_wayland_socket_path >/dev/null 2>&1; then
            return 0
        fi

        sleep 0.1
    done

    return 1
}

regolith_cosmic_sway_socket_path() {
    local runtime_dir="${XDG_RUNTIME_DIR-}"
    local candidate=

    if [ -n "${SWAYSOCK-}" ] && [ -S "$SWAYSOCK" ]; then
        printf '%s\n' "$SWAYSOCK"
        return 0
    fi

    if [ -z "$runtime_dir" ]; then
        return 1
    fi

    for candidate in "$runtime_dir"/sway-ipc.*.sock; do
        if [ -S "$candidate" ]; then
            SWAYSOCK="$candidate"
            export SWAYSOCK
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

wait_for_regolith_cosmic_sway_socket() {
    local attempt=

    for attempt in $(seq 1 50); do
        if regolith_cosmic_sway_socket_path >/dev/null 2>&1; then
            return 0
        fi

        sleep 0.1
    done

    return 1
}

start_regolith_cosmic_helpers() {

    if regolith_cosmic_bool_is_true "${REGOLITH_COSMIC_ENABLE_COSMOLITH:-true}"; then
        if wait_for_regolith_cosmic_sway_socket; then
            regolith_cosmic_start_optional_process cosmolith
        fi
    fi

    regolith_cosmic_start_optional_process cosmic-settings-daemon

    if regolith_cosmic_bool_is_true "${REGOLITH_COSMIC_ENABLE_OSD:-true}"; then
        regolith_cosmic_start_optional_process_after "${REGOLITH_COSMIC_OSD_DELAY_SECONDS:-2}" cosmic-osd
    fi

}

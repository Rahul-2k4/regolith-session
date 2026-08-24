#!/bin/bash

# The COSMIC session deliberately starts each compositor/helper in its own
# process group.  util-linux provides `setsid` on the Linux systems where the
# session runs, but macOS hosts used for local shell-test development do not
# ship that command.  Install a small test-only equivalent there so the tests
# retain the process-group assertions instead of silently bypassing them.
install_portable_setsid_stub() {
    local stub_dir="$1"

    if command -v setsid >/dev/null 2>&1; then
        return 0
    fi

    cat >"$stub_dir/setsid" <<'PY'
#!/usr/bin/env python3
import os
import sys

arguments = sys.argv[1:]
if arguments[:1] == ["--"]:
    arguments = arguments[1:]

if not arguments:
    raise SystemExit("setsid test stub: missing command")

if os.getpgrp() == os.getpid():
    child_pid = os.fork()
    if child_pid > 0:
        _, status = os.waitpid(child_pid, 0)
        if os.WIFEXITED(status):
            raise SystemExit(os.WEXITSTATUS(status))
        if os.WIFSIGNALED(status):
            raise SystemExit(128 + os.WTERMSIG(status))
        raise SystemExit(1)

os.setsid()
os.execvp(arguments[0], arguments)
PY
    chmod +x "$stub_dir/setsid"
}

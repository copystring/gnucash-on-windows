#!/usr/bin/env bash
set -euo pipefail

readonly TEST_REGEX='^(test-budget-view-column-ownership|test-plugin-page-budget-window-lifetime|test-dialog-sx-since-last-run-ownership|test-tree-view-row-ownership|test-import-account-matcher)$'

if [[ "${1:-}" == '--session' ]]; then
    readonly build="$2" gtk_path="$3" gtk_dso="$4" results="$5"
    export XDG_RUNTIME_DIR="${RUNNER_TEMP:?}/gnucash-wayland-runtime"
    export WAYLAND_DISPLAY='gnucash-ci-wayland' GDK_BACKEND='wayland'
    unset DISPLAY
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
    printf 'GDK_BACKEND=%s\nWAYLAND_DISPLAY=%s\nDISPLAY=%s\n' \
        "$GDK_BACKEND" "$WAYLAND_DISPLAY" "${DISPLAY-unset}" >"$results/session-env.txt"
    weston -B headless --renderer=pixman --no-config --socket="$WAYLAND_DISPLAY" \
        --idle-time=0 --log="$results/weston.log" &
    weston_pid=$!
    trap 'kill "$weston_pid" 2>/dev/null || true; wait "$weston_pid" 2>/dev/null || true' EXIT
    ready=0
    for _ in {1..50}; do
        if [[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] &&
            wayland-info >"$results/wayland-info.txt" 2>&1; then
            ready=1; break
        fi
        kill -0 "$weston_pid" 2>/dev/null || break
        sleep 0.2
    done
    [[ "$ready" -eq 1 ]]
    gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
        --method org.a11y.Bus.GetAddress | tee "$results/at-spi-bus.txt"

    set +e
    env LD_LIBRARY_PATH="$gtk_path${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
        WAYLAND_DEBUG=1 LD_DEBUG=libs LD_DEBUG_OUTPUT="$results/loader" \
        CTEST_OUTPUT_ON_FAILURE=1 LIBGL_ALWAYS_SOFTWARE=1 \
        timeout --foreground 15m ctest --test-dir "$build" --verbose \
            --output-on-failure --no-tests=error --timeout 120 \
            --output-junit "$results/ctest.xml" --tests-regex "$TEST_REGEX" \
        2>&1 | tee "$results/ctest.txt"
    ctest_status=${PIPESTATUS[0]}
    set -e
    cp -a "$build/Testing" "$results/Testing"
    grep -E 'wl_display[@#][0-9]+\.get_registry' "$results/ctest.txt" \
        >"$results/wayland-client-connections.txt"
    grep -l -F "calling init: $gtk_dso" "$results"/loader.* \
        >"$results/gtk-loader-processes.txt"
    [[ "$(wc -l <"$results/gtk-loader-processes.txt")" -eq 5 ]]
    [[ "$ctest_status" -eq 0 ]]
    exit
fi

if [[ $# -ne 3 ]]; then
    echo "usage: $0 CORE_BUILD GTK_BUILD RESULTS" >&2
    exit 2
fi
readonly build="$1" gtk_build="$2" results="$3"
readonly gtk_dso="$gtk_build/gtk/libgtk-4.so.1"
readonly gtk_path="$gtk_build/gtk:$gtk_build/gdk:$gtk_build/gsk"
for command in awk ctest dbus-run-session gdbus ldd meson python3 sha256sum \
    timeout wayland-info weston; do
    command -v "$command" >/dev/null
done
test -r "$gtk_dso"
mkdir -p "$results"
{
    meson introspect --projectinfo "$gtk_build"
    printf 'gtk_dso=%s\ngtk_sha256=%s\nweston=%s\n' "$gtk_dso" \
        "$(sha256sum "$gtk_dso" | awk '{print $1}')" "$(weston --version)"
} | tee "$results/runtime-versions.txt"

ctest --test-dir "$build" --show-only=json-v1 --tests-regex "$TEST_REGEX" \
    >"$results/registered-tests.json"
python3 - "$results/registered-tests.json" "$results/test-programs.txt" <<'PY'
import json, sys
tests = json.load(open(sys.argv[1], encoding="utf-8"))["tests"]
assert len(tests) == 5, f"expected five registered tests, got {len(tests)}"
assert all(len(test["command"]) == 1 for test in tests)
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(t["command"][0] for t in tests) + "\n")
PY
while IFS= read -r executable; do
    LD_LIBRARY_PATH="$gtk_path" ldd "$executable"
done <"$results/test-programs.txt" | tee "$results/gtk-linkage.txt"
[[ "$(grep -c -F "$gtk_dso" "$results/gtk-linkage.txt")" -eq 5 ]]
dbus-run-session -- bash "$0" --session "$build" "$gtk_path" "$gtk_dso" "$results"

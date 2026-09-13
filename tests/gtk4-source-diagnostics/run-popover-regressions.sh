#!/usr/bin/env bash
# Run the unchanged Popover lifecycle probes against the patched GTK library.
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "usage: $0 GTK_BUILD DIAGNOSTICS [baseline|patched]" >&2
    exit 2
fi
readonly gtk_build="$1"
readonly diagnostics="$2"
readonly variant="${3:-patched}"
[[ "$variant" == baseline || "$variant" == patched ]]
readonly runtime_path="${gtk_build}/gtk:${gtk_build}/gdk:${gtk_build}/gsk"
readonly probe_build="${RUNNER_TEMP:?}/gtk-popover-patched-regression"
mkdir -p "$diagnostics"

cmake -S "${GITHUB_WORKSPACE:?}/tests/gtk4-popover-ownership-probe" \
    -B "$probe_build" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build "$probe_build" --parallel 3
readonly executable="$probe_build/gtk-popover-ownership-probe"
LD_LIBRARY_PATH="$runtime_path${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    ldd "$executable" | tee "$diagnostics/popover-$variant-ldd.txt"
grep -F "$gtk_build/gtk/libgtk-4.so.1" "$diagnostics/popover-$variant-ldd.txt"

for mode in retained-normal-close replacement owner-release; do
    args=()
    case "$mode" in
        replacement) args=(--replacement) ;;
        owner-release) args=(--owner-release) ;;
    esac
    set +e
    timeout --signal=KILL --kill-after=2s 15s \
        env LD_LIBRARY_PATH="$runtime_path${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
        GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 \
        xvfb-run --auto-servernum --server-args='-screen 0 1024x768x24' \
        "$executable" "${args[@]}" \
        >"$diagnostics/popover-$variant-$mode.stdout.txt" \
        2>"$diagnostics/popover-$variant-$mode.stderr.txt"
    native_exit=$?
    set -e
    cat "$diagnostics/popover-$variant-$mode.stdout.txt" \
        "$diagnostics/popover-$variant-$mode.stderr.txt"
    printf 'variant=%s mode=%s native_exit=%s\n' "$variant" "$mode" "$native_exit" \
        | tee "$diagnostics/popover-$variant-$mode.result.txt"
    if [[ "$variant" == baseline && "$mode" != owner-release ]]; then
        [[ "$native_exit" -eq 1 ]]
        grep -q 'popover still alive after test-ref release' \
            "$diagnostics/popover-$variant-$mode.stderr.txt"
    else
        [[ "$native_exit" -eq 0 ]]
    fi
done

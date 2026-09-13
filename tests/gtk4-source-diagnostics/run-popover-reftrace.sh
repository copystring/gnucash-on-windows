#!/usr/bin/env bash
#
# Trace the retained Popover reference against the uninstalled GTK source
# library made by the focused ColumnView baseline job. No GTK build occurs here.

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 GTK_BUILD DIAGNOSTICS" >&2
    exit 2
fi

readonly gtk_build="$1"
readonly diagnostics="$2"
readonly source_dir="${GITHUB_WORKSPACE:?}/tests/gtk4-popover-ownership-probe"
readonly probe_build="${RUNNER_TEMP:?}/gtk-column-focus-source-baseline/popover-reftrace-build"
readonly gtk_dso="${gtk_build}/gtk/libgtk-4.so.1"
readonly runtime_path="${gtk_build}/gtk:${gtk_build}/gdk:${gtk_build}/gsk"
readonly gdb_commands="${diagnostics}/popover-retained-refcount.gdb"
readonly gdb_stdout="${diagnostics}/popover-retained-refcount-gdb.stdout.txt"
readonly gdb_stderr="${diagnostics}/popover-retained-refcount-gdb.stderr.txt"
readonly gdb_exit="${diagnostics}/popover-retained-refcount-gdb.exit.txt"

mkdir -p "$diagnostics"
test -d "$gtk_build"
test -r "$gtk_dso"
command -v gdb

printf 'fresh_gtk_dso=%s\n' "$gtk_dso"
readelf --sections "$gtk_dso" >"$diagnostics/popover-reftrace-fresh-gtk-sections.txt"
grep -F '.symtab' "$diagnostics/popover-reftrace-fresh-gtk-sections.txt"
readelf --symbols --wide "$gtk_dso" >"$diagnostics/popover-reftrace-fresh-gtk-symbols.txt"
awk '$4 == "FUNC" && $5 == "LOCAL" && $8 ~ /^gtk_popover_/ { found = 1 }
     END { exit !found }' \
    "$diagnostics/popover-reftrace-fresh-gtk-symbols.txt"

cmake -S "$source_dir" -B "$probe_build" -G Ninja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    2>&1 | tee "$diagnostics/popover-reftrace-cmake.txt"
cmake --build "$probe_build" --parallel "${NINJA_JOBS:-3}" --verbose \
    2>&1 | tee "$diagnostics/popover-reftrace-build.txt"

readonly executable="${probe_build}/gtk-popover-ownership-probe"
test -x "$executable"
LD_LIBRARY_PATH="$runtime_path${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    ldd "$executable" | tee "$diagnostics/popover-reftrace-ldd.txt"
grep -F "$gtk_dso" "$diagnostics/popover-reftrace-ldd.txt"

cat >"$gdb_commands" <<'GDB'
set pagination off
set confirm off
set debuginfod enabled off
set breakpoint pending off
set can-use-hw-watchpoints 1
start
printf "POPOVER_SOURCE_TRACE_PRELOAD_BEGIN\n"
info sharedlibrary
info proc mappings
sharedlibrary libgtk-4\.so\.1
sharedlibrary libgobject-2\.0\.so\.0
printf "POPOVER_SOURCE_TRACE_PRELOAD_END\n"
info sharedlibrary
break gtk_popover_probe_refcount_marker
continue
set $watched_popover = object
printf "POPOVER_GDB_MARKER object=%p ref_count=%u\n", $watched_popover, ((GObject *) $watched_popover)->ref_count
watch -location ((GObject *) $watched_popover)->ref_count
commands
  printf "POPOVER_REFCOUNT_TRANSITION object=%p ref_count=%u\n", $watched_popover, ((GObject *) $watched_popover)->ref_count
  bt 12
  continue
end
continue
GDB

set +e
timeout --signal=KILL --kill-after=2s 120s \
    env LD_LIBRARY_PATH="$runtime_path${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    DEBUGINFOD_URLS= GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 \
    xvfb-run --auto-servernum --server-args='-screen 0 1024x768x24' \
    gdb --batch --return-child-result --command="$gdb_commands" \
        --args "$executable" >"$gdb_stdout" 2>"$gdb_stderr"
gdb_status=$?
set -e

{
    printf 'mode=retained-normal-close\n'
    printf 'gdb_exit_code=%s\n' "$gdb_status"
} | tee "$gdb_exit"
cat "$gdb_stdout"
cat "$gdb_stderr"

if [[ "$gdb_status" -eq 124 || "$gdb_status" -eq 137 ]]; then
    printf 'GDB retained-normal-close trace timed out.\n' >&2
    exit 1
fi
if [[ "$gdb_status" -ne 1 ]]; then
    printf 'GDB trace did not preserve the retained-normal-close failure: exit=%s\n' \
        "$gdb_status" >&2
    exit 1
fi
grep -q 'Hardware watchpoint' "$gdb_stdout"
grep -q 'POPOVER_SOURCE_TRACE_PRELOAD_BEGIN' "$gdb_stdout"
grep -q 'POPOVER_SOURCE_TRACE_PRELOAD_END' "$gdb_stdout"
grep -F "$gtk_dso" "$gdb_stdout"
grep -q 'POPOVER_GDB_MARKER object=' "$gdb_stdout"
grep -q 'POPOVER_REFCOUNT_TRANSITION object=' "$gdb_stdout"
grep -q 'popover still alive after test-ref release' "$gdb_stderr"
if grep -q 'No required after-paint boundary' "$gdb_stderr"; then
    printf 'Probe watchdog expired under GDB; no ownership diagnosis.\n' >&2
    exit 1
fi

if grep -q '??' "$gdb_stdout"; then
    printf 'local_symbol_resolution=incomplete\n' |
        tee "$diagnostics/popover-reftrace-symbol-status.txt"
else
    printf 'local_symbol_resolution=complete\n' |
        tee "$diagnostics/popover-reftrace-symbol-status.txt"
fi

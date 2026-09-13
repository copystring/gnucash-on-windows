#!/usr/bin/env bash
#
# Configure the pinned GnuCash core checkout against a freshly built GTK and
# execute only the ownership regressions that exercise the affected widgets.

set -euo pipefail

readonly CORE_COMMIT='8d86cf048bbf2094d481da87f44aad36693f3302'

if [[ $# -ne 3 ]]; then
    echo "usage: $0 CORE_SOURCE GTK_BUILD DIAGNOSTICS" >&2
    exit 2
fi

readonly core_source="$1"
readonly gtk_build="$2"
readonly diagnostics="$3"
readonly gtk_dso="${gtk_build}/gtk/libgtk-4.so.1"
readonly gtk_runtime_path="${gtk_build}/gtk:${gtk_build}/gdk:${gtk_build}/gsk"
readonly ninja_jobs="${NINJA_JOBS:-3}"
readonly test_regex='^(test-budget-view-column-ownership|test-plugin-page-budget-window-lifetime|test-dialog-sx-since-last-run-ownership|test-tree-view-row-ownership)$'

case "$ninja_jobs" in
    1|2|3) ;;
    *)
        echo "NINJA_JOBS must be between 1 and 3" >&2
        exit 2
        ;;
esac

mkdir -p "$diagnostics"

for command in cmake ctest git ldd ninja xvfb-run; do
    command -v "$command" >/dev/null
done
test -d "$core_source"
test -r "$gtk_dso"

core_commit="$(git -C "$core_source" rev-parse HEAD)"
readonly core_commit
if [[ "$core_commit" != "$CORE_COMMIT" ]]; then
    printf 'Expected GnuCash core %s, got %s.\n' "$CORE_COMMIT" "$core_commit" >&2
    exit 1
fi

{
    printf 'core_source=%s\n' "$core_source"
    printf 'core_commit=%s\n' "$core_commit"
    printf 'fresh_gtk_dso=%s\n' "$gtk_dso"
    printf 'fresh_gtk_sha256=%s\n' "$(sha256sum "$gtk_dso" | awk '{print $1}')"
    printf 'gtk_runtime_path=%s\n' "$gtk_runtime_path"
    printf 'ninja_jobs=%s\n' "$ninja_jobs"
    printf 'ctest_regex=%s\n' "$test_regex"
    git -C "$core_source" status --porcelain=v1
} | tee "$diagnostics/focused-core-inputs.txt"

build_dir="$(mktemp -d "${RUNNER_TEMP:?}/gnucash-gtk4-focused-core.XXXXXX")"
readonly build_dir
readonly install_prefix="${build_dir}/inst"

# GncAddTest.cmake snapshots LD_LIBRARY_PATH for Guile-backed tests at
# configure time. Configure with the fresh GTK path so its registered test
# environment cannot replace it with the distribution GTK at ctest time.
env LD_LIBRARY_PATH="$gtk_runtime_path${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    cmake -S "$core_source" -B "$build_dir" -G Ninja \
    -DWITH_PYTHON=ON \
    -DWITH_AQBANKING=OFF \
    -DCMAKE_BUILD_TYPE=Asan \
    -DCMAKE_INSTALL_PREFIX="$install_prefix" \
    2>&1 | tee "$diagnostics/focused-core-cmake.txt"

readonly gnome_ctest_file="${build_dir}/gnucash/gnome/test/CTestTestfile.cmake"
readonly gnome_utils_ctest_file="${build_dir}/gnucash/gnome-utils/test/CTestTestfile.cmake"
test -r "$gnome_ctest_file"
test -r "$gnome_utils_ctest_file"
grep -F "$gtk_runtime_path" "$gnome_ctest_file" |
    tee "$diagnostics/focused-core-registered-guile-runtime.txt"

# compiled-schemas provides the explicit GSettings dependency of all four
# tests. scm-gnome is the product Guile target required by the dialog test;
# its declared dependencies build the corresponding engine/application Scheme
# modules. The remaining targets are the four registered test executables.
cmake --build "$build_dir" --parallel "$ninja_jobs" --verbose --target \
    compiled-schemas \
    scm-gnome \
    test-budget-view-column-ownership \
    test-plugin-page-budget-window-lifetime \
    test-dialog-sx-since-last-run-ownership \
    test-tree-view-row-ownership \
    2>&1 | tee "$diagnostics/focused-core-build.txt"

readonly -a test_executables=(
    "${build_dir}/gnucash/gnome/test/test-budget-view-column-ownership"
    "${build_dir}/gnucash/gnome/test/test-plugin-page-budget-window-lifetime"
    "${build_dir}/gnucash/gnome/test/test-dialog-sx-since-last-run-ownership"
    "${build_dir}/gnucash/gnome-utils/test/test-tree-view-row-ownership"
)

: >"$diagnostics/focused-core-ldd.txt"
for executable in "${test_executables[@]}"; do
    test -x "$executable"
    loader_result="$(LD_LIBRARY_PATH="$gtk_runtime_path${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
        ldd "$executable")"
    {
        printf 'executable=%s\n' "$executable"
        printf '%s\n' "$loader_result"
    } | tee -a "$diagnostics/focused-core-ldd.txt"
    grep -F "$gtk_dso" <<<"$loader_result"
done

# The anchored selection keeps CTest's registered per-test environment and all
# assertions intact while refusing an empty selection. LD_DEBUG makes the
# dynamic loader's GTK choice part of the diagnostic artifact.
readonly ctest_log="$diagnostics/focused-core-ctest.txt"
set +e
env LD_LIBRARY_PATH="$gtk_runtime_path${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    LD_DEBUG=libs \
    LD_DEBUG_OUTPUT="$diagnostics/focused-core-loader" \
    GDK_BACKEND=x11 \
    LIBGL_ALWAYS_SOFTWARE=1 \
    CTEST_OUTPUT_ON_FAILURE=1 \
    xvfb-run --auto-servernum --server-args='-screen 0 1024x768x24' \
    ctest --test-dir "$build_dir" \
        --verbose \
        --output-on-failure \
        --no-tests=error \
        --tests-regex "$test_regex" \
    2>&1 | tee "$ctest_log"
ctest_status=${PIPESTATUS[0]}
set -e

cp "$build_dir/Testing/Temporary/LastTest.log" "$diagnostics/focused-core-LastTest.log"
grep -l -F "calling init: $gtk_dso" "$diagnostics"/focused-core-loader.* \
    >"$diagnostics/focused-core-gtk-loader-processes.txt"
[[ "$(wc -l <"$diagnostics/focused-core-gtk-loader-processes.txt")" -eq 4 ]]

{
    printf 'focused_core_build_dir=%s\n' "$build_dir"
    printf 'ctest_exit=%s\n' "$ctest_status"
    printf 'fresh_gtk_test_processes=4\n'
} | tee "$diagnostics/focused-core-result.txt"
[[ "$ctest_status" -eq 0 ]]
grep -F '100% tests passed, 0 tests failed out of 4' "$ctest_log"

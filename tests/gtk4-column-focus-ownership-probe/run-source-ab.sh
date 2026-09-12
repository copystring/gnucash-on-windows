#!/usr/bin/env bash
#
# Build an isolated GTK source tree and run the focused-column probe against it.
# No files are installed and no distribution package is modified.

set -euo pipefail

readonly GTK_COMMIT='7f99ab1a26408b6499a18f353f081e3c0598ea5c'
readonly GTK_TAG='4.22.4'
readonly GTK_SOURCE_URL='https://gitlab.gnome.org/GNOME/gtk.git'
readonly PATCH_SHA256='23046AF144974F7A91D6A2CDAD14F9DE6764A667077BBB9DC6FD1A0611B3D5F9'
readonly EXPECTED_BASELINE_EXIT=134
readonly PROBE_ASSERTION_LINE=233

if [[ $# -ne 1 || ( "$1" != baseline && "$1" != patched ) ]]; then
    echo "usage: $0 baseline|patched" >&2
    exit 2
fi

readonly variant="$1"
readonly source_dir="${GITHUB_WORKSPACE:?}/tests/gtk4-column-focus-ownership-probe"
readonly run_root="${RUNNER_TEMP:?}/gtk-column-focus-source-${variant}"
readonly gtk_source="${run_root}/gtk-source"
readonly gtk_build="${run_root}/gtk-build"
readonly probe_build="${run_root}/probe-build"
readonly diagnostics="${RUNNER_TEMP:?}/gtk-column-focus-source-${variant}-diagnostics"
readonly patch_path="${source_dir}/gtkcolumnview-focus-column-ref.patch"
readonly ninja_jobs="${NINJA_JOBS:-3}"

case "$ninja_jobs" in
    2|3|4) ;;
    *)
        echo "NINJA_JOBS must be between 2 and 4" >&2
        exit 2
        ;;
esac

mkdir -p "$diagnostics"

record_environment()
{
    . /etc/os-release
    {
        printf 'variant=%s\n' "$variant"
        printf 'RUNNER_OS=%s\n' "${RUNNER_OS:-unknown}"
        printf 'RUNNER_ARCH=%s\n' "${RUNNER_ARCH:-unknown}"
        printf 'ImageOS=%s\n' "${ImageOS:-unknown}"
        printf 'ImageVersion=%s\n' "${ImageVersion:-unknown}"
        printf 'GITHUB_SHA=%s\n' "${GITHUB_SHA:-unknown}"
        printf 'distribution=%s\n' "$ID"
        printf 'distribution_version=%s\n' "$VERSION_ID"
        printf 'uname_machine=%s\n' "$(uname -m)"
        printf 'cc=%s\n' "$(cc --version | head -n 1)"
        printf 'cmake=%s\n' "$(cmake --version | head -n 1)"
        printf 'meson=%s\n' "$(meson --version)"
        printf 'ninja=%s\n' "$(ninja --version)"
        printf 'gtk4_distro_pkg_config=%s\n' "$(pkg-config --modversion gtk4)"
        printf 'glib2_distro_pkg_config=%s\n' "$(pkg-config --modversion glib-2.0)"
        dpkg-query -W -f='${Package}=${Version}\n' \
            build-essential cmake file git libglib2.0-dev libgtk-4-dev \
            libcairo2-dev libdrm-dev libepoxy-dev libfontconfig-dev \
            libfribidi-dev libgdk-pixbuf-2.0-dev libgraphene-1.0-dev \
            libharfbuzz-dev libjpeg-dev libpango1.0-dev libpng-dev \
            libtiff-dev libx11-dev libxcursor-dev libxdamage-dev \
            libxext-dev libxfixes-dev libxi-dev libxinerama-dev \
            libxrandr-dev libxrender-dev meson ninja-build pkg-config sassc \
            xauth xvfb
    } | tee "$diagnostics/environment.txt"

    [[ "${RUNNER_OS:-}" == Linux ]]
    [[ "${RUNNER_ARCH:-}" == X64 ]]
    [[ "$ID" == ubuntu ]]
    [[ "$VERSION_ID" == 26.04 ]]
    [[ "$(uname -m)" == x86_64 ]]
}

checkout_gtk()
{
    git clone --depth 1 --branch "$GTK_TAG" "$GTK_SOURCE_URL" "$gtk_source" \
        2>&1 | tee "$diagnostics/gtk-clone.txt"
    [[ "$(git -C "$gtk_source" rev-parse HEAD)" == "$GTK_COMMIT" ]]
    [[ "$(git -C "$gtk_source" describe --exact-match HEAD)" == "$GTK_TAG" ]]
    {
        printf 'gtk_source_url=%s\n' "$(git -C "$gtk_source" remote get-url origin)"
        printf 'gtk_tag=%s\n' "$GTK_TAG"
        printf 'gtk_commit=%s\n' "$(git -C "$gtk_source" rev-parse HEAD)"
        printf 'gtk_source_status=%s\n' "$(git -C "$gtk_source" status --porcelain=v1)"
        sha256sum "$gtk_source/gtk/gtkcolumnview.c"
        sha256sum "$patch_path"
    } | tee "$diagnostics/source-inputs.txt"
    [[ "$(sha256sum "$patch_path" | awk '{ print toupper($1) }')" == "$PATCH_SHA256" ]]
}

apply_variant()
{
    if [[ "$variant" == patched ]]; then
        git -C "$gtk_source" apply --check "$patch_path"
        git -C "$gtk_source" apply "$patch_path"
        git -C "$gtk_source" diff --check
    else
        git -C "$gtk_source" diff --exit-code
    fi

    {
        printf 'variant=%s\n' "$variant"
        git -C "$gtk_source" status --porcelain=v1
        sha256sum "$gtk_source/gtk/gtkcolumnview.c"
    } | tee "$diagnostics/variant-source-state.txt"
}

build_gtk_library()
{
    meson setup "$gtk_build" "$gtk_source" --buildtype=release --wrap-mode=nodownload \
        -Dbuild-demos=false -Dbuild-examples=false -Dbuild-tests=false \
        -Dbuild-testsuite=false -Ddocumentation=false -Dintrospection=disabled \
        -Dx11-backend=true -Dwayland-backend=false -Dbroadway-backend=false \
        -Dvulkan=disabled -Dmedia-gstreamer=disabled -Dprint-cpdb=disabled \
        -Dprint-cups=disabled -Dcloudproviders=disabled -Dsysprof=disabled \
        -Dtracker=disabled -Dcolord=disabled -Daccesskit=disabled \
        2>&1 | tee "$diagnostics/gtk-meson-setup.txt"
    meson configure "$gtk_build" 2>&1 | tee "$diagnostics/gtk-meson-configure.txt"
    meson compile -C "$gtk_build" -j "$ninja_jobs" gtk-4 \
        2>&1 | tee "$diagnostics/gtk-library-build.txt"
    test -f "$gtk_build/gtk/libgtk-4.so.1"
    sha256sum "$gtk_build/gtk/libgtk-4.so.1" | tee "$diagnostics/gtk-library-sha256.txt"
}

build_probe()
{
    cmake -S "$source_dir" -B "$probe_build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        2>&1 | tee "$diagnostics/probe-cmake.txt"
    cmake --build "$probe_build" --parallel "$ninja_jobs" --verbose \
        2>&1 | tee "$diagnostics/probe-build.txt"
    test -x "$probe_build/gtk-column-focus-ownership-probe"
}

run_probe()
{
    local runtime_path="${gtk_build}/gtk:${gtk_build}/gdk:${gtk_build}/gsk"
    local stdout="$diagnostics/probe.stdout.txt"
    local stderr="$diagnostics/probe.stderr.txt"
    local combined="$diagnostics/probe.combined.txt"
    local native_exit
    local timed_out=false

    LD_LIBRARY_PATH="$runtime_path${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
        ldd "$probe_build/gtk-column-focus-ownership-probe" \
        | tee "$diagnostics/probe-ldd.txt"
    grep -F "$gtk_build/gtk/libgtk-4.so.1" "$diagnostics/probe-ldd.txt"

    set +e
    timeout --signal=KILL --kill-after=2s 15s \
        env LD_LIBRARY_PATH="$runtime_path${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
        GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 \
        xvfb-run --auto-servernum --server-args='-screen 0 1024x768x24' \
        "$probe_build/gtk-column-focus-ownership-probe" >"$stdout" 2>"$stderr"
    native_exit=$?
    set -e
    if [[ "$native_exit" -eq 124 || "$native_exit" -eq 137 ]]; then
        timed_out=true
    fi
    cat "$stdout" "$stderr" | tee "$combined"
    {
        printf 'variant=%s\n' "$variant"
        printf 'native_exit=%s\n' "$native_exit"
        printf 'timed_out=%s\n' "$timed_out"
    } | tee "$diagnostics/probe-result.txt"

    [[ "$timed_out" == false ]]
    if [[ "$variant" == baseline ]]; then
        [[ "$native_exit" -eq "$EXPECTED_BASELINE_EXIT" ]]
        grep -Eq "main\.c:${PROBE_ASSERTION_LINE}" "$combined"
        grep -Eq 'wait_until_finalized[[:space:]]*\(&successor_ref\)' "$combined"
    else
        [[ "$native_exit" -eq 0 ]]
    fi
}

record_environment
checkout_gtk
apply_variant
build_gtk_library
build_probe
run_probe

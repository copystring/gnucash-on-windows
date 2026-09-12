# GTK4 ColumnView source A/B proof

`run-source-ab.sh` provides an isolated Linux source comparison for the
focused-column ownership candidate. It does not install GTK, change a system
package, publish a package, or build GnuCash.

Each job clones the official GTK `4.22.4` tag and verifies commit
`7f99ab1a26408b6499a18f353f081e3c0598ea5c`. Both configure fresh Meson build
trees with the same recorded Ubuntu 26.04 dependencies and options, then build
only the Meson `gtk-4` target, which produces `gtk/libgtk-4.so.1`. The
`patched` variant applies exactly
`gtkcolumnview-focus-column-ref.patch`, whose SHA-256 is verified before use;
the baseline remains source-clean.

The dependency list is derived from GTK 4.22.4's `meson.build`: direct GLib,
Pango, Cairo, image, Graphene, epoxy, DRM, Fontconfig, and X11 dependencies
are installed explicitly. The cloned source has no pre-generated default CSS,
so GTK's own `gtk/meson.build` requires `sassc`. Cairo's script interpreter is
not installed because GTK requires it only when `build-tests=true`, which this
library-only build sets to `false`; XComposite is not a GTK 4.22.4 Meson
dependency.

The probe itself is built against distro headers. At runtime `LD_LIBRARY_PATH`
prefers the fresh GTK, GDK, and GSK build directories. `ldd` must identify the
fresh `gtk/libgtk-4.so.1` before the probe is allowed to run.

The baseline is accepted only when it exits exactly 134 and its raw combined
output identifies `main.c:233` and the `wait_until_finalized(&successor_ref)`
assertion. The patched variant is accepted only with exit 0. Timeouts and every
other exit code are errors. The raw combined output is also written to the job
log. Raw source, build, environment, loader, stdout, stderr, and result files
are retained as artifacts.

This is a narrow GTK source/patch proof. A successful A/B result does not prove
a GnuCash product path, a distribution package, or an upstream release.

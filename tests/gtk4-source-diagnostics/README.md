# Focused GTK/GnuCash integration diagnostics

The fork-only `gtk4-column-focus-source-ab.yml` workflow reuses each freshly
built, uninstalled GTK 4.22.4 library for a second check:

- Baseline: trace the retained Popover reference with local GTK function
  symbols. The unchanged public-API probe must reproduce its original failure;
  a successful diagnostic does **not** mean the Popover bug is fixed.
- Patched: run five affected GnuCash regression executables from the explicitly
  pinned Core revision, including Budget with the GTK column fix and the full
  import matcher suite with the deferred-focus fix.

The source trace in run `34730055220`, job `103651068105`, identifies the
Popover reference precisely: hide and reentrant unparent each assign a new
reference to the single `GtkWindowPrivate::move_focus_widget` slot. Only the
last reference is released later. `gtkwindow-deferred-focus-ref.patch` replaces
that raw assignment with `g_set_object`, preserving one owned slot, including
the same-widget case. The three unchanged Popover modes must then exit zero.
This patch is separate from the focused-column patch; neither adds extra
unrefs to callers or changes focus timing.

Pushes now run the patched variant only. A manual workflow dispatch still
runs both variants; the pinned baseline/source trace remains available from
the earlier run. Neither mode is a full GnuCash/platform CI result.

The patched job itself first runs the original ColumnView and all three
Popover cases against unmodified GTK, then applies the two patches and rebuilds
only their translation units. This keeps both sides' X11/Wayland build contract
identical. Both backends are required by the distribution WebKit link closure;
the actual GUI tests still select X11/Xvfb. A `RTLD_NOW` WebKit load check catches
an incompatible replacement library before the Core build. Build and runtime
use the same fresh GTK, with no private library shims.

The Popover helper checks `.symtab` and private Popover function symbols,
verifies the loaded library through `ldd` and same-process GDB mappings, and
uses the public `GObject.ref_count` hardware watchpoint. Debuginfod is off.
The original failure message, exit code, 120-second outer limit, and rejection
of the probe's after-paint watchdog remain mandatory. Unresolved frames remain
explicitly unidentified. Symbol tables are artifacts, not repeated CI output.

This is targeted diagnosis, not the full GnuCash CI matrix or a platform/package
release check. The helpers do not install GTK or change any existing packages.

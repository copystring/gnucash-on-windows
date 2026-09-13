# Focused GTK/GnuCash integration diagnostics

The fork-only `gtk4-column-focus-source-ab.yml` workflow reuses each freshly
built, uninstalled GTK 4.22.4 library for a second check:

- Baseline: trace the retained Popover reference with local GTK function
  symbols. The unchanged public-API probe must reproduce its original failure;
  a successful diagnostic does **not** mean the Popover bug is fixed.
- Patched: run four affected GnuCash regression executables from the explicitly
  pinned Core revision, including the Budget test using the GTK column fix.

The Popover helper checks `.symtab` and private Popover function symbols,
verifies the loaded library through `ldd` and same-process GDB mappings, and
uses the public `GObject.ref_count` hardware watchpoint. Debuginfod is off.
The original failure message, exit code, 120-second outer limit, and rejection
of the probe's after-paint watchdog remain mandatory. Unresolved frames remain
explicitly unidentified. Symbol tables are artifacts, not repeated CI output.

This is targeted diagnosis, not the full GnuCash CI matrix or a platform/package
release check. The helpers do not install GTK or change any existing packages.

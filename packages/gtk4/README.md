# Temporary GTK 4.24.0 staging package

This directory starts from the official MSYS2 `mingw-w64-gtk4` recipe at
`msys2/MINGW-packages` commit
`de381e6b410070c15e84a3fa40fa53962057d7c7` (verified 2026-09-19). Its GTK
files are unchanged from the previously recorded recipe commit
`62ef6f178fb03342b647f8172efb324bfe48a520`:

* GTK version and release: `4.24.0-1`
* source: `https://download.gnome.org/sources/gtk/4.24/gtk-4.24.0.tar.xz`
* source SHA-256:
  `28ba4ac1c04f86eac09b79a163cb163a4c2b54442d9f7eccc04679062a581044`
* official MSYS2 font patch SHA-256:
  `ebac78616a7668edbfdd77b9959ad63239aa59ed12b995a9663bf2df7158be26`

The local delta is deliberately limited to:

1. `pkgrel=1.1`, so an explicitly installed staging artifact is distinct from
   the official `4.24.0-1` package.
2. The repository-standard `debug`, `strip`, and `buildflags` package options.
   Meson uses `buildtype=release` and `debug=true`, retaining release
   optimization while makepkg preserves and splits the symbols. A successful
   build requires both the UCRT64 runtime and separate debug package. MSYS2
   names that automatically generated package `mingw-w64-gtk4-debug` from the
   recipe's `pkgbase`; its generic name does not identify the target
   environment. The workflow therefore verifies its `.PKGINFO` identity and
   version, requires the UCRT64 GTK DLL's detached symbols under `ucrt64/`, and
   rejects payload paths for the other MSYS2 environments. Failed runs still
   upload their diagnostics.
3. `gtkcolumnview-focus-column-ref.patch`, SHA-256
   `23046af144974f7a91d6a2cdad14f9de6764a667077bbb9dc6fd1a0611b3d5f9`.
   It releases the owned reference returned by `g_list_model_get_item()` after
   assigning the non-owning `focus_column` pointer.
4. Compilation is bounded to three jobs. The official recipe does not build
   GTK's test suite; packaging success is not a runtime-test result. The
   GnuCash regression suite must pass against the resulting package separately.

The patch was A/B tested independently by
`.worktrees/gtk4-ime-repro/tests/gtk4-column-focus-ownership-probe` against GTK
4.22.4: the baseline retained the successor column and the patched build
finalized it. On 2026-09-19 the unchanged patch also passed `git apply
--check` against the official GTK 4.24.0 tag, commit
`1f47f368b17701e693918fcd078436b39d4354d1`.

No deferred-focus patch belongs here. GTK 4.24.0 already uses
`g_set_object (&priv->move_focus_widget, widget)` in `gtk/gtkwindow.c`, so the
separate GTK 4.22 ownership correction is already present.

The accompanying workflow publishes only a GitHub Actions artifact. It does
not update the rolling dependency repository or any package feed. Alongside
the packages it writes `manifest.json` with the artifact name, exact source
and recipe commits, patch hashes, package names, package SHA-256 values, and
the required debug-package identity. The normal GnuCash Windows path continues
to consume official MSYS2 GTK unless a caller explicitly installs this
artifact.

Remove this directory and its workflow once an official GTK release or MSYS2
package contains the ColumnView ownership fix and the GnuCash budget-column
regression passes with that official package.

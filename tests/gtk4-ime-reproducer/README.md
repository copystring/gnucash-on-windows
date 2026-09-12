# GTK4 Win32 IME window-lifetime reproducer

This is a standalone GTK4-only reproducer for a Windows
`GTK_IS_IM_CONTEXT_IME` assertion observed after a focused entry's window was
destroyed. It contains no GnuCash source, test data, or private GTK API.

The program presents a real `GtkWindow` containing a real `GtkEntry`, requests
entry focus, and waits for a real `GdkFrameClock::after-paint` boundary plus
the public `GtkWindow::is-active` and root-focus observations. GTK4 may place
root focus on the Entry's `GtkText` delegate, so the focused root widget itself
must have GTK widget focus and belong to the real Entry. It then deliberately
keeps an explicit window reference while
calling `gtk_window_destroy()`, verifies that the window became unrealized, and
releases that retained reference after a normal main-loop interval. Only after
that final unref does it present a second real `GtkWindow` with a second
`GtkEntry`, observes another frame and active text focus, and dispatches its
ordinary main loop briefly. It never injects Win32 messages or emits synthetic
GTK signals.

The program makes GTK, GDK, GLib-GObject, and process-wide critical logs fatal.
The observed IME assertion therefore produces a failing native process instead
of being reported as a successful run.

## Fork-only Windows workflow

Run **GTK4 Win32 IME reproducer** from the repository's Actions page. The
workflow uses the standard `windows-latest`
runner with an isolated UCRT64 toolchain. It builds only this small C program
and installs GTK4 plus build-tool dependencies; it does not build GnuCash.
It also runs automatically for changes to its own source or workflow on
`fix/gtk4-ime-reproducer-20260912`. The job is restricted to
`copystring/gnucash-on-windows`; no upstream workflow or default branch is
modified. Push runs use the explicit default package versions below.

The default package contract matches the environment in which the assertion
was observed:

- `mingw-w64-ucrt-x86_64-gtk4` 4.24.0-1
- `mingw-w64-ucrt-x86_64-glib2` 2.90.0-1
- UCRT64 on x86-64
- no UCRT64 GTK3 package or `gtk+-3.0` pkg-config module

The workflow verifies this contract before executing the reproducer. Version
drift fails explicitly; it does not silently test a different GTK/GLib stack.
The expected package versions are visible dispatch inputs so that a deliberate
future rerun can name its new contract without editing or hiding it.

Both variants are separate native process invocations in the same inexpensive
runner job:

```powershell
.\gtk-ime-window-lifetime-repro.exe
.\gtk-ime-window-lifetime-repro.exe --early-focus-out
```

The baseline leaves the focused entry unchanged until
`gtk_window_destroy()`. The comparison variant calls public
`gtk_root_set_focus(window, NULL)` after the confirmed after-paint boundary and
before destruction. Both invocations run even when the first fails. Their
signed decimal and unsigned hexadecimal native exit codes, standard output,
standard error, package versions, architecture, and imported DLL names are
uploaded as one diagnostic artifact. Any nonzero or unavailable native exit
code or 15-second external timeout fails the job after both variants have been
recorded; there is no `continue-on-error` success conversion or fallback
implementation.

An exit code of zero means only that this bounded public GTK path completed
without a crash or fatal critical. In particular, it does **not** prove that a
later Win32 IME message occurred or that GTK has been fixed.

The hosted runner is not assumed to provide a usable interactive focus path.
Each initial and follow-up window has a two-second bounded precondition: it
must receive an `after-paint` frame, become active, and give a focused GTK root
delegate belonging to the real Entry. A timeout distinguishes a missing frame
from an arrived frame without active-window or delegate/root focus, and fails before the
corresponding teardown or follow-up probe. Such a result establishes a runner
limitation for this probe; it is not evidence for or against the IME lifetime
assertion itself.

Do not use a local GUI run for repository validation. The source may be built
manually in an appropriate UCRT64 environment only when an interactive Windows
diagnostic is explicitly intended:

```powershell
cmake -S . -B build -G Ninja
cmake --build build
```

GTK's public API cannot force an arbitrary future native message without
fabricating one. The reproducer therefore validates the public
focus/destroy/drain ordering and leaves native-message occurrence to the
Windows backend and runner.

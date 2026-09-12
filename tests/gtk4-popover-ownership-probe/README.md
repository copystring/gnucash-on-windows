# GTK4 Popover ownership probe

This is an isolated GTK4 probe for the unexplained final `GtkPopover`
reference observed by the GnuCash matcher test. It contains no GnuCash code,
import data, private GTK API, synthetic GTK signals, or reference-count
assumptions.

The probe presents a real window and anchor, opens a real default-autohide
popover, waits through an after-paint boundary, and closes it with
`gtk_popover_popdown()`. Its `closed` handler follows the product ordering:
clear the weak owner slot, then call `gtk_widget_unparent()`.

The first probe revision (`b8d2597`) used a non-focusable label and passed all
three modes on both runners. The current revision changes only that child to
a box of four focusable buttons, matching the matcher menu's focusable
content. Neither revision calls GnuCash callbacks or forces a focus override.

Three independent processes cover the public ownership paths:

```text
gtk-popover-ownership-probe
gtk-popover-ownership-probe --owner-release
gtk-popover-ownership-probe --replacement
```

The baseline retains exactly one external reference across normal close and
requires finalization after releasing it. `--owner-release` tears down an
active popover through the owner path without an external test reference.
`--replacement` creates a new real popover after closing the retained one and
then checks finalization of the old instance. GTK, GDK, and GLib-GObject
criticals remain fatal. Public widget state is printed only on failure.

The dedicated `gtk4-popover-ownership-probe.yml` workflow builds and runs all
three modes separately on Windows UCRT64 and Ubuntu 26.04 under Xvfb. It records
the GTK/GLib versions, executable architecture, GTK4 runtime dependency, full
stdout/stderr, and each process exit status. Any failed or timed-out mode fails
its job after the other modes have also produced diagnostics.

On Linux, the isolated probe is built as `RelWithDebInfo`. After the unchanged
three-mode baseline, the workflow separately reruns only the known failing
`retained-normal-close` case under batch GDB. GDB starts and stops before
`main`, enables Ubuntu's official HTTPS debuginfod service through
`DEBUGINFOD_URLS`, records `info sharedlibrary` plus `info proc mappings` for
that same process, and explicitly preloads the GTK4 and GObject shared-library
symbols. The actually linked GTK DSO's `readelf --notes` Build ID is a separate
artifact. Download and preload time count against the outer 120-second trace
limit, before the probe can arm its own two-second after-paint watchdog.

A deliberately global, non-inlined marker immediately after the Popover
creation supplies its public `GObject *` to GDB; GDB must install a hardware
watchpoint on `GObject.ref_count`, record every observed transition with a
twelve-frame backtrace, and retain the native exit `1`. Exit `1` is not
sufficient: the diagnostic also requires the exact remaining-Popover message
and rejects the probe's inner two-second after-paint watchdog, which would be a
timing/setup failure rather than ownership evidence. If Ubuntu cannot supply
the necessary private-library symbols, the trace, mappings, and Build ID still
state that diagnosis boundary; they are not treated as a fabricated symbolic
owner. This trace is an additional artifact: it never converts the preceding
baseline failure to success or weakens fatal GTK, GDK, or GLib-GObject
diagnostics.

The Windows job pins the same GTK4 4.24.0-1 and GLib 2.90.0-1 package contract
as the IME reproducer. The Linux job records the distribution-provided GTK4 and
GLib versions for an independent comparison. Neither job accepts a GTK3-linked
binary.

A zero exit status means only that this public sequence finalized correctly in
that runner environment. It does not prove a GTK fix and does not justify
weakening the unresolved GnuCash assertion. The probe has intentionally not
been built or run locally.

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

The Windows job pins the same GTK4 4.24.0-1 and GLib 2.90.0-1 package contract
as the IME reproducer. The Linux job records the distribution-provided GTK4 and
GLib versions for an independent comparison. Neither job accepts a GTK3-linked
binary.

A zero exit status means only that this public sequence finalized correctly in
that runner environment. It does not prove a GTK fix and does not justify
weakening the unresolved GnuCash assertion. The probe has intentionally not
been built or run locally.

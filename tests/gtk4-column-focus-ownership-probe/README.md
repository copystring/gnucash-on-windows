# GTK4 ColumnView focused-column baseline probe

This standalone GTK4 probe checks the focused-column replacement path in an
unpatched distribution GTK. It is not GnuCash code, contains no private GTK
API, and has not been built or run locally.

The program presents a real `GtkColumnView` with one row, three real columns,
and signal list-item factories. It first places real focus inside the mapped
view, then public `gtk_column_view_scroll_to(..., GTK_LIST_SCROLL_FOCUS, ...)`
sets GTK's focused-column path. The probe subsequently places actual public
widget focus on the mapped middle-cell `GtkEntry` and verifies that the root
focus is that entry or its descendant before removal begins. It then removes
the focused column, appends a replacement, removes the remaining columns,
destroys the window, and requires the original successor column to finalize
through a `GWeakRef`.

Only standard owner references are balanced: the creator references after
`append_column()` and transfer-full references from `g_list_model_get_item()`.
The test emits no GTK signals, uses no private GTK API, and performs no extra
unref. Its focus setup uses only public `GtkWidget` focus operations on the
actual mapped view and its actual middle-cell entry.

The dedicated workflow compiles and runs this exact baseline on Ubuntu 26.04
under Xvfb and Windows UCRT64. It preserves the native exit status, timeout,
environment, stdout, and stderr in an artifact. A nonzero native exit makes the
job fail without classifying every abort as an ownership result. A zero exit is
a pass only in the narrow sense that this probe found no failure on that runner;
it is not a GnuCash test pass and it does not disprove the upstream owner-path
analysis.

The candidate upstream implementation change is intentionally not applied here.
It belongs to the separate artifact review, not to a distribution-package build.

/* Standalone GtkColumnView focused-column ownership probe.
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation; either version 2 of the License, or (at your
 * option) any later version.
 */

#include <gtk/gtk.h>

typedef struct
{
    GMainLoop *loop;
    gboolean after_paint;
    gboolean timed_out;
    gulong after_paint_handler;
    guint timeout_id;
    GdkFrameClock *clock;
} FrameWait;

static guint bound_cells;
static GWeakRef middle_entry_ref;

static void
quit_wait_loop (FrameWait *wait)
{
    if (g_main_loop_is_running (wait->loop))
        g_main_loop_quit (wait->loop);
}

static void
after_paint_cb (GdkFrameClock *clock, FrameWait *wait)
{
    (void)clock;
    wait->after_paint = TRUE;
    quit_wait_loop (wait);
}

static gboolean
wait_timeout_cb (gpointer user_data)
{
    FrameWait *wait = user_data;

    wait->timeout_id = 0;
    wait->timed_out = TRUE;
    quit_wait_loop (wait);
    return G_SOURCE_REMOVE;
}

static void
wait_for_after_paint (GtkWidget *widget)
{
    FrameWait wait = { 0 };

    wait.loop = g_main_loop_new (NULL, FALSE);
    wait.clock = gtk_widget_get_frame_clock (widget);
    g_assert_nonnull (wait.clock);
    g_object_ref (wait.clock);
    wait.after_paint_handler =
        g_signal_connect (wait.clock, "after-paint", G_CALLBACK (after_paint_cb), &wait);

    gdk_frame_clock_request_phase (wait.clock, GDK_FRAME_CLOCK_PHASE_PAINT);
    if (!wait.after_paint)
    {
        wait.timeout_id = g_timeout_add (2000, wait_timeout_cb, &wait);
        g_main_loop_run (wait.loop);
    }

    if (wait.timeout_id != 0)
        g_source_remove (wait.timeout_id);
    g_signal_handler_disconnect (wait.clock, wait.after_paint_handler);
    g_object_unref (wait.clock);
    g_main_loop_unref (wait.loop);

    g_assert_false (wait.timed_out);
    g_assert_true (wait.after_paint);
}

static void
setup_cell (GtkSignalListItemFactory *factory,
            GtkListItem              *list_item,
            gpointer                  user_data)
{
    GtkWidget *entry;

    guint column_index = GPOINTER_TO_UINT (user_data);

    (void)factory;
    entry = gtk_entry_new ();
    gtk_editable_set_editable (GTK_EDITABLE (entry), FALSE);
    gtk_list_item_set_child (list_item, entry);
    if (column_index == 1)
        g_weak_ref_set (&middle_entry_ref, entry);
}

static void
bind_cell (GtkSignalListItemFactory *factory,
           GtkListItem              *list_item,
           gpointer                  user_data)
{
    GtkStringObject *item;
    GtkWidget *entry;

    (void)factory;
    (void)user_data;
    item = GTK_STRING_OBJECT (gtk_list_item_get_item (list_item));
    entry = gtk_list_item_get_child (list_item);
    g_assert_true (GTK_IS_ENTRY (entry));
    gtk_editable_set_text (GTK_EDITABLE (entry), gtk_string_object_get_string (item));
    bound_cells++;
}

static GtkColumnViewColumn *
append_column (GtkColumnView *view, const char *title, guint column_index)
{
    GtkListItemFactory *factory;
    GtkColumnViewColumn *column;

    factory = gtk_signal_list_item_factory_new ();
    g_signal_connect (factory, "setup", G_CALLBACK (setup_cell),
                      GUINT_TO_POINTER (column_index));
    g_signal_connect (factory, "bind", G_CALLBACK (bind_cell), NULL);
    column = gtk_column_view_column_new (title, factory);
    gtk_column_view_append_column (view, column);

    return column;
}

static gboolean
wait_until_finalized (GWeakRef *weak_ref)
{
    gint64 deadline = g_get_monotonic_time () + 2 * G_TIME_SPAN_SECOND;

    do
    {
        GObject *object = g_weak_ref_get (weak_ref);

        if (object == NULL)
            return TRUE;
        g_object_unref (object);

        while (g_main_context_pending (NULL))
            g_main_context_iteration (NULL, FALSE);
    }
    while (g_get_monotonic_time () < deadline);

    return FALSE;
}

int
main (int argc, char **argv)
{
    const char *items[] = { "row", NULL };
    GtkStringList *strings;
    GtkSingleSelection *selection;
    GtkWindow *window;
    GtkColumnView *view;
    GListModel *columns;
    GtkColumnViewColumn *first;
    GtkColumnViewColumn *focused;
    GtkColumnViewColumn *successor;
    GtkColumnViewColumn *rebuilt;
    GtkWidget *middle_entry;
    GtkWidget *root_focus;
    GWeakRef successor_ref;

    (void)argc;
    (void)argv;
    gtk_init ();
    g_weak_ref_init (&middle_entry_ref, NULL);

    strings = gtk_string_list_new (items);
    selection = gtk_single_selection_new (G_LIST_MODEL (strings));
    view = GTK_COLUMN_VIEW (gtk_column_view_new (GTK_SELECTION_MODEL (selection)));
    window = GTK_WINDOW (gtk_window_new ());
    gtk_window_set_default_size (window, 480, 180);
    gtk_window_set_child (window, GTK_WIDGET (view));

    /* append_column retains its own list-model reference; drop each creator ref. */
    first = append_column (view, "First", 0);
    focused = append_column (view, "Focused", 1);
    successor = append_column (view, "Successor", 2);
    g_object_unref (first);
    g_object_unref (focused);
    g_object_unref (successor);

    gtk_window_present (window);
    wait_for_after_paint (GTK_WIDGET (window));
    g_assert_cmpuint (bound_cells, >=, 3);
    middle_entry = g_weak_ref_get (&middle_entry_ref);
    g_assert_true (GTK_IS_ENTRY (middle_entry));
    g_assert_true (gtk_widget_get_mapped (middle_entry));

    columns = gtk_column_view_get_columns (view);
    first = g_list_model_get_item (columns, 0);
    focused = g_list_model_get_item (columns, 1);
    successor = g_list_model_get_item (columns, 2);
    g_assert_nonnull (first);
    g_assert_nonnull (focused);
    g_assert_nonnull (successor);
    g_weak_ref_init (&successor_ref, successor);

    /* Establish real focus inside the view before targeting its middle cell. */
    g_assert_true (gtk_widget_grab_focus (GTK_WIDGET (view)));
    gtk_column_view_scroll_to (view, 0, focused, GTK_LIST_SCROLL_FOCUS, NULL);
    wait_for_after_paint (GTK_WIDGET (window));

    /* Confirm that the public focus target is the mapped middle-cell widget. */
    g_assert_true (gtk_widget_grab_focus (middle_entry));
    wait_for_after_paint (GTK_WIDGET (window));
    root_focus = gtk_root_get_focus (GTK_ROOT (window));
    g_assert_true (root_focus != NULL &&
                   (root_focus == middle_entry ||
                    gtk_widget_is_ancestor (root_focus, middle_entry)));
    g_object_unref (middle_entry);

    /* Normal removal and rebuild; every local get_item reference is balanced. */
    gtk_column_view_remove_column (view, focused);
    g_clear_object (&focused);
    rebuilt = append_column (view, "Rebuilt", 3);
    g_object_unref (rebuilt);
    rebuilt = g_list_model_get_item (columns, 2);
    g_assert_nonnull (rebuilt);

    gtk_column_view_remove_column (view, first);
    g_clear_object (&first);
    gtk_column_view_remove_column (view, successor);
    g_clear_object (&successor);
    gtk_column_view_remove_column (view, rebuilt);
    g_clear_object (&rebuilt);

    gtk_window_destroy (window);
    g_assert_true (wait_until_finalized (&successor_ref));
    g_weak_ref_clear (&successor_ref);
    g_weak_ref_clear (&middle_entry_ref);

    return 0;
}

#include <gtk/gtk.h>

typedef struct
{
    GtkWindow *window;
    GtkEntry *entry;
    GMainLoop *loop;
    guint watchdog_id;
    guint release_id;
    guint post_unref_id;
    guint tick_id;
    GdkFrameClock *after_paint_clock;
    gulong after_paint_id;
    gboolean early_focus_out;
    gboolean completed;
} ReproState;

static gboolean
focus_belongs_to_entry (GtkWindow *window, GtkEntry *entry)
{
    GtkWidget *focus = gtk_root_get_focus (GTK_ROOT (window));

    return focus == GTK_WIDGET (entry) ||
           (focus && gtk_widget_is_ancestor (focus, GTK_WIDGET (entry)));
}

static gboolean
quit_after_final_unref (gpointer user_data)
{
    ReproState *state = user_data;

    state->post_unref_id = 0;
    state->completed = TRUE;
    g_main_loop_quit (state->loop);
    return G_SOURCE_REMOVE;
}

static gboolean
release_destroyed_window (gpointer user_data)
{
    ReproState *state = user_data;

    state->release_id = 0;
    g_object_unref (state->window);
    state->window = NULL;
    /* Continue dispatching normally after the final unref as well. */
    state->post_unref_id = g_timeout_add (250, quit_after_final_unref, state);
    return G_SOURCE_REMOVE;
}

static void
clear_after_paint (ReproState *state)
{
    if (state->after_paint_id)
    {
        g_signal_handler_disconnect (state->after_paint_clock,
                                     state->after_paint_id);
        state->after_paint_id = 0;
    }
    g_clear_object (&state->after_paint_clock);
}

static void
clear_callbacks (ReproState *state)
{
    if (state->watchdog_id)
    {
        g_source_remove (state->watchdog_id);
        state->watchdog_id = 0;
    }
    if (state->release_id)
    {
        g_source_remove (state->release_id);
        state->release_id = 0;
    }
    if (state->post_unref_id)
    {
        g_source_remove (state->post_unref_id);
        state->post_unref_id = 0;
    }
    if (state->tick_id)
    {
        if (state->window)
            gtk_widget_remove_tick_callback (GTK_WIDGET (state->window),
                                             state->tick_id);
        state->tick_id = 0;
    }
    clear_after_paint (state);
}

static void
fail_repro (ReproState *state, const char *message)
{
    g_printerr ("%s\n", message);
    clear_callbacks (state);
    if (state->window)
    {
        gtk_window_destroy (state->window);
        g_object_unref (state->window);
        state->window = NULL;
    }
    g_main_loop_quit (state->loop);
}

static void
after_paint (GdkFrameClock *clock, ReproState *state)
{
    (void)clock;
    clear_after_paint (state);
    if (state->watchdog_id)
    {
        g_source_remove (state->watchdog_id);
        state->watchdog_id = 0;
    }

    if (!focus_belongs_to_entry (state->window, state->entry))
    {
        fail_repro (state,
                    "The GtkEntry delegate did not own root focus after paint.");
        return;
    }

    if (state->early_focus_out)
    {
        gtk_root_set_focus (GTK_ROOT (state->window), NULL);
        if (gtk_root_get_focus (GTK_ROOT (state->window)) != NULL)
        {
            fail_repro (state,
                        "gtk_root_set_focus(NULL) did not clear root focus.");
            return;
        }
    }

    gtk_window_destroy (state->window);
    if (gtk_widget_get_realized (GTK_WIDGET (state->window)))
    {
        fail_repro (state,
                    "GtkWindow remained realized after gtk_window_destroy().");
        return;
    }

    /* The explicit reference survives destroy/unrealize. Dispatch the normal
     * main context before and after its final release; no native message is
     * fabricated. */
    state->release_id = g_timeout_add (250, release_destroyed_window, state);
}

static gboolean
arm_after_paint (GtkWidget *widget, GdkFrameClock *clock, gpointer user_data)
{
    ReproState *state = user_data;

    (void)widget;
    state->tick_id = 0;
    state->after_paint_clock = g_object_ref (clock);
    state->after_paint_id = g_signal_connect (state->after_paint_clock,
                                               "after-paint",
                                               G_CALLBACK (after_paint), state);
    return G_SOURCE_REMOVE;
}

static gboolean
watchdog_expired (gpointer user_data)
{
    ReproState *state = user_data;

    state->watchdog_id = 0;
    fail_repro (state, "No after-paint callback arrived within two seconds.");
    return G_SOURCE_REMOVE;
}

int
main (int argc, char **argv)
{
    ReproState state = { 0 };
    const GLogLevelFlags fatal_levels = G_LOG_FATAL_MASK | G_LOG_LEVEL_CRITICAL;

    if (argc == 2 && g_str_equal (argv[1], "--early-focus-out"))
        state.early_focus_out = TRUE;
    else if (argc != 1)
    {
        g_printerr ("Usage: %s [--early-focus-out]\n", argv[0]);
        return 2;
    }

    g_log_set_always_fatal (fatal_levels);
    g_log_set_fatal_mask ("Gtk", fatal_levels);
    g_log_set_fatal_mask ("Gdk", fatal_levels);
    g_log_set_fatal_mask ("GLib-GObject", fatal_levels);
    gtk_init ();
    state.loop = g_main_loop_new (NULL, FALSE);
    state.window = GTK_WINDOW (gtk_window_new ());
    state.entry = GTK_ENTRY (gtk_entry_new ());
    gtk_window_set_title (state.window, "GTK IME lifetime repro");
    gtk_window_set_child (state.window, GTK_WIDGET (state.entry));
    gtk_window_present (state.window);
    gtk_widget_grab_focus (GTK_WIDGET (state.entry));
    state.tick_id = gtk_widget_add_tick_callback (GTK_WIDGET (state.window),
                                                   arm_after_paint, &state, NULL);
    state.watchdog_id = g_timeout_add (2000, watchdog_expired, &state);

    /* Keep an explicit external reference across destroy/unrealize. */
    g_object_ref (state.window);
    g_main_loop_run (state.loop);

    clear_callbacks (&state);
    if (state.window)
    {
        gtk_window_destroy (state.window);
        g_object_unref (state.window);
    }
    g_main_loop_unref (state.loop);

    return state.completed ? 0 : 1;
}

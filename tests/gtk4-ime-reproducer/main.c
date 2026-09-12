#include <gtk/gtk.h>

typedef struct
{
    GtkWindow *window;
    GtkEntry *entry;
    GMainLoop *loop;
    guint watchdog_id;
    guint release_id;
    guint completion_id;
    guint tick_id;
    guint focus_tick_id;
    gulong window_active_id;
    GdkFrameClock *after_paint_clock;
    gulong after_paint_id;
    gboolean early_focus_out;
    gboolean followup_window;
    gboolean frame_seen;
    gboolean phase_ready;
    gboolean completed;
} ReproState;

static void present_focused_window (ReproState *state, const char *title);
static gboolean watchdog_expired (gpointer user_data);
static gboolean arm_after_paint (GtkWidget *widget, GdkFrameClock *clock,
                                 gpointer user_data);
static void advance_after_ready (ReproState *state);
static gboolean focus_tick (GtkWidget *widget, GdkFrameClock *clock,
                            gpointer user_data);

static gboolean
focus_belongs_to_entry (GtkWindow *window, GtkEntry *entry)
{
    GtkWidget *focus = gtk_root_get_focus (GTK_ROOT (window));

    return focus == GTK_WIDGET (entry) ||
           (focus && gtk_widget_is_ancestor (focus, GTK_WIDGET (entry)));
}

static gboolean
release_destroyed_window (gpointer user_data)
{
    ReproState *state = user_data;

    state->release_id = 0;
    g_object_unref (state->window);
    state->window = NULL;
    state->entry = NULL;
    state->followup_window = TRUE;
    present_focused_window (state, "GTK IME lifetime follow-up");
    state->watchdog_id = g_timeout_add (2000, watchdog_expired, state);
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
clear_focus_observers (ReproState *state)
{
    if (state->window_active_id)
    {
        g_signal_handler_disconnect (state->window, state->window_active_id);
        state->window_active_id = 0;
    }
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
    if (state->completion_id)
    {
        g_source_remove (state->completion_id);
        state->completion_id = 0;
    }
    clear_focus_observers (state);
    if (state->tick_id)
    {
        if (state->window)
            gtk_widget_remove_tick_callback (GTK_WIDGET (state->window),
                                             state->tick_id);
        state->tick_id = 0;
    }
    if (state->focus_tick_id)
    {
        if (state->window)
            gtk_widget_remove_tick_callback (GTK_WIDGET (state->window),
                                             state->focus_tick_id);
        state->focus_tick_id = 0;
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
        state->entry = NULL;
    }
    g_main_loop_quit (state->loop);
}

static gboolean
entry_has_active_window_focus (ReproState *state)
{
    GtkWidget *focus = gtk_root_get_focus (GTK_ROOT (state->window));

    return gtk_window_is_active (state->window) && focus &&
           gtk_widget_has_focus (focus) &&
           focus_belongs_to_entry (state->window, state->entry);
}

static void
fail_missing_focus_precondition (ReproState *state)
{
    if (!gtk_window_is_active (state->window))
        fail_repro (state, "GtkWindow did not become active before the IME probe.");
    else if (!gtk_root_get_focus (GTK_ROOT (state->window)))
        fail_repro (state, "GtkRoot had no focused text delegate before the IME probe.");
    else if (!gtk_widget_has_focus (gtk_root_get_focus (GTK_ROOT (state->window))))
        fail_repro (state, "GtkRoot focus widget did not have GTK widget focus before the IME probe.");
    else
        fail_repro (state, "GtkRoot focus widget did not belong to the GtkEntry before the IME probe.");
}

static void
window_state_changed (GObject *object, GParamSpec *pspec, gpointer user_data)
{
    ReproState *state = user_data;

    (void)object;
    (void)pspec;
    advance_after_ready (state);
}

static gboolean
finish_followup_window (gpointer user_data)
{
    ReproState *state = user_data;

    state->completion_id = 0;
    clear_callbacks (state);
    /* Only the initial window is the teardown subject of this probe. */
    gtk_root_set_focus (GTK_ROOT (state->window), NULL);
    gtk_window_destroy (state->window);
    if (gtk_widget_get_realized (GTK_WIDGET (state->window)))
    {
        fail_repro (state,
                    "Follow-up GtkWindow remained realized after gtk_window_destroy().");
        return G_SOURCE_REMOVE;
    }
    g_object_unref (state->window);
    state->window = NULL;
    state->entry = NULL;
    state->completed = TRUE;
    g_main_loop_quit (state->loop);
    return G_SOURCE_REMOVE;
}

static void
advance_after_ready (ReproState *state)
{
    if (state->phase_ready || !state->frame_seen ||
        !entry_has_active_window_focus (state))
        return;
    state->phase_ready = TRUE;
    if (state->focus_tick_id)
    {
        guint tick_id = state->focus_tick_id;

        state->focus_tick_id = 0;
        gtk_widget_remove_tick_callback (GTK_WIDGET (state->window), tick_id);
    }
    if (state->watchdog_id)
    {
        g_source_remove (state->watchdog_id);
        state->watchdog_id = 0;
    }
    clear_focus_observers (state);

    if (state->followup_window)
    {
        /* A real post-unref native toplevel/Entry has received a frame and
         * active text focus. Continue its normal main loop briefly. */
        state->completion_id = g_timeout_add (250, finish_followup_window, state);
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
                    "Initial GtkWindow remained realized after gtk_window_destroy().");
        return;
    }

    /* The explicit reference survives destroy/unrealize. The next callback
     * releases it, then presents a distinct real toplevel for native events. */
    state->release_id = g_timeout_add (250, release_destroyed_window, state);
}

static void
present_focused_window (ReproState *state, const char *title)
{
    state->window = GTK_WINDOW (gtk_window_new ());
    state->entry = GTK_ENTRY (gtk_entry_new ());
    state->frame_seen = FALSE;
    state->phase_ready = FALSE;
    gtk_window_set_title (state->window, title);
    gtk_window_set_child (state->window, GTK_WIDGET (state->entry));
    state->window_active_id = g_signal_connect (state->window, "notify::is-active",
                                                 G_CALLBACK (window_state_changed), state);
    state->tick_id = gtk_widget_add_tick_callback (GTK_WIDGET (state->window),
                                                   arm_after_paint, state, NULL);
    gtk_window_present (state->window);
    gtk_widget_grab_focus (GTK_WIDGET (state->entry));
    /* Keep an explicit external reference across destroy/unrealize. */
    g_object_ref (state->window);
}

static void
after_paint (GdkFrameClock *clock, ReproState *state)
{
    (void)clock;
    clear_after_paint (state);
    state->frame_seen = TRUE;
    state->focus_tick_id = gtk_widget_add_tick_callback (GTK_WIDGET (state->window),
                                                         focus_tick, state, NULL);
    advance_after_ready (state);
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
    gdk_frame_clock_request_phase (clock, GDK_FRAME_CLOCK_PHASE_AFTER_PAINT);
    return G_SOURCE_REMOVE;
}

static gboolean
focus_tick (GtkWidget *widget, GdkFrameClock *clock, gpointer user_data)
{
    ReproState *state = user_data;

    (void)widget;
    (void)clock;
    advance_after_ready (state);
    if (!state->watchdog_id)
    {
        state->focus_tick_id = 0;
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

static gboolean
watchdog_expired (gpointer user_data)
{
    ReproState *state = user_data;

    state->watchdog_id = 0;
    if (!state->frame_seen)
        fail_repro (state, state->followup_window
                    ? "Follow-up GtkWindow did not reach after-paint within two seconds."
                    : "Initial GtkWindow did not reach after-paint within two seconds.");
    else
        fail_missing_focus_precondition (state);
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
    present_focused_window (&state, "GTK IME lifetime repro");
    state.watchdog_id = g_timeout_add (2000, watchdog_expired, &state);

    g_main_loop_run (state.loop);

    clear_callbacks (&state);
    if (state.window)
    {
        gtk_window_destroy (state.window);
        g_object_unref (state.window);
        state.window = NULL;
        state.entry = NULL;
    }
    g_main_loop_unref (state.loop);

    return state.completed ? 0 : 1;
}

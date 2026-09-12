/* Standalone GTK popover ownership regression probe.
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation; either version 2 of the License, or (at your
 * option) any later version.
 */

#include <gtk/gtk.h>

typedef enum
{
    RETAINED_NORMAL_CLOSE,
    OWNER_RELEASE,
    RETAINED_REPLACEMENT,
} ProbeMode;

typedef struct
{
    GtkWindow *window;
    GtkWidget *anchor;
    GtkWidget *tick_widget;
    GtkPopover *current_popover;
    GObject *test_ref;
    GWeakRef closed_popover;
    GMainLoop *loop;
    guint watchdog_id;
    guint tick_id;
    guint followup_id;
    GdkFrameClock *clock;
    gulong after_paint_id;
    ProbeMode mode;
    gboolean weak_initialized;
    gboolean closed;
    gboolean finished;
    gboolean completed;
} ProbeState;

static void finish_probe (ProbeState *state, gboolean success);

static void
clear_frame_wait (ProbeState *state)
{
    if (state->tick_id && state->tick_widget)
        gtk_widget_remove_tick_callback (state->tick_widget, state->tick_id);
    state->tick_id = 0;
    state->tick_widget = NULL;
    if (state->after_paint_id)
        g_signal_handler_disconnect (state->clock, state->after_paint_id);
    state->after_paint_id = 0;
    g_clear_object (&state->clock);
}

static void
clear_sources (ProbeState *state)
{
    if (state->watchdog_id)
        g_source_remove (state->watchdog_id);
    state->watchdog_id = 0;
    if (state->followup_id)
        g_source_remove (state->followup_id);
    state->followup_id = 0;
    clear_frame_wait (state);
}

static void
log_lifecycle (const char *phase, GtkWidget *popover)
{
    g_printerr ("%s: parent=%d root=%d visible=%d mapped=%d realized=%d autohide=%d\n",
                phase,
                gtk_widget_get_parent (popover) != NULL,
                gtk_widget_get_root (popover) != NULL,
                gtk_widget_get_visible (popover),
                gtk_widget_get_mapped (popover),
                gtk_widget_get_realized (popover),
                gtk_popover_get_autohide (GTK_POPOVER (popover)));
}

static void
unparent_after_closed (GtkPopover *popover, ProbeState *state)
{
    if (state->current_popover == popover)
    {
        state->current_popover = NULL;
        g_object_remove_weak_pointer (G_OBJECT (popover),
                                      (gpointer *)&state->current_popover);
    }
    state->closed = TRUE;
    gtk_widget_unparent (GTK_WIDGET (popover));
}

static GtkPopover *
new_popover (ProbeState *state)
{
    GtkPopover *popover = GTK_POPOVER (gtk_popover_new ());
    GtkWidget *menu = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);

    g_assert_true (gtk_popover_get_autohide (popover));
    for (guint index = 0; index < 4; index++)
    {
        GtkWidget *button = gtk_button_new_with_label ("Popover action");
        gtk_button_set_has_frame (GTK_BUTTON (button), FALSE);
        gtk_box_append (GTK_BOX (menu), button);
    }
    gtk_popover_set_child (popover, menu);
    gtk_widget_set_parent (GTK_WIDGET (popover), state->anchor);
    state->current_popover = popover;
    g_object_add_weak_pointer (G_OBJECT (popover),
                               (gpointer *)&state->current_popover);
    g_signal_connect (popover, "closed", G_CALLBACK (unparent_after_closed), state);
    gtk_popover_popup (popover);
    return popover;
}

static void
release_active_popover (ProbeState *state)
{
    GtkPopover *popover = state->current_popover;

    if (!popover)
        return;

    state->current_popover = NULL;
    g_object_remove_weak_pointer (G_OBJECT (popover),
                                  (gpointer *)&state->current_popover);
    g_signal_handlers_disconnect_by_data (popover, state);
    gtk_popover_popdown (popover);
    gtk_widget_unparent (GTK_WIDGET (popover));
}

static gboolean
check_closed_popover (gpointer user_data)
{
    ProbeState *state = user_data;
    GObject *retained;

    state->followup_id = 0;
    retained = g_weak_ref_get (&state->closed_popover);
    if (retained)
    {
        log_lifecycle ("popover still alive after test-ref release", GTK_WIDGET (retained));
        g_object_unref (retained);
        finish_probe (state, FALSE);
        return G_SOURCE_REMOVE;
    }
    finish_probe (state, TRUE);
    return G_SOURCE_REMOVE;
}

static gboolean
after_normal_close (gpointer user_data)
{
    ProbeState *state = user_data;

    state->followup_id = 0;
    if (!state->closed || state->current_popover)
    {
        g_printerr ("Popover closed callback did not clear its weak owner slot.\n");
        finish_probe (state, FALSE);
        return G_SOURCE_REMOVE;
    }

    if (state->mode == RETAINED_REPLACEMENT)
        new_popover (state);
    g_clear_object (&state->test_ref);
    state->followup_id = g_timeout_add (100, check_closed_popover, state);
    return G_SOURCE_REMOVE;
}

static void
trigger_close (ProbeState *state)
{
    GtkPopover *popover = state->current_popover;

    if (!popover || !gtk_widget_get_mapped (GTK_WIDGET (popover)))
    {
        g_printerr ("Popover was not mapped after its after-paint boundary.\n");
        finish_probe (state, FALSE);
        return;
    }

    g_weak_ref_init (&state->closed_popover, G_OBJECT (popover));
    state->weak_initialized = TRUE;
    if (state->mode != OWNER_RELEASE)
        state->test_ref = G_OBJECT (g_object_ref (popover));

    if (state->mode == OWNER_RELEASE)
    {
        release_active_popover (state);
        state->followup_id = g_timeout_add (100, check_closed_popover, state);
    }
    else
    {
        gtk_popover_popdown (popover);
        state->followup_id = g_idle_add (after_normal_close, state);
    }
}

static void
popover_after_paint (GdkFrameClock *clock, ProbeState *state)
{
    (void)clock;
    clear_frame_wait (state);
    trigger_close (state);
}

static gboolean
arm_popover_after_paint (GtkWidget *widget, GdkFrameClock *clock, gpointer data)
{
    ProbeState *state = data;

    (void)widget;
    state->tick_id = 0;
    state->tick_widget = NULL;
    state->clock = g_object_ref (clock);
    state->after_paint_id = g_signal_connect (clock, "after-paint",
                                               G_CALLBACK (popover_after_paint), state);
    gdk_frame_clock_request_phase (clock, GDK_FRAME_CLOCK_PHASE_AFTER_PAINT);
    return G_SOURCE_REMOVE;
}

static void
window_after_paint (GdkFrameClock *clock, ProbeState *state)
{
    GtkPopover *popover;

    (void)clock;
    clear_frame_wait (state);
    popover = new_popover (state);
    state->tick_widget = GTK_WIDGET (popover);
    state->tick_id = gtk_widget_add_tick_callback (state->tick_widget,
                                                    arm_popover_after_paint,
                                                    state, NULL);
}

static gboolean
arm_window_after_paint (GtkWidget *widget, GdkFrameClock *clock, gpointer data)
{
    ProbeState *state = data;

    (void)widget;
    state->tick_id = 0;
    state->tick_widget = NULL;
    state->clock = g_object_ref (clock);
    state->after_paint_id = g_signal_connect (clock, "after-paint",
                                               G_CALLBACK (window_after_paint), state);
    gdk_frame_clock_request_phase (clock, GDK_FRAME_CLOCK_PHASE_AFTER_PAINT);
    return G_SOURCE_REMOVE;
}

static gboolean
watchdog_expired (gpointer user_data)
{
    ProbeState *state = user_data;

    state->watchdog_id = 0;
    g_printerr ("No required after-paint boundary arrived within two seconds.\n");
    finish_probe (state, FALSE);
    return G_SOURCE_REMOVE;
}

static void
finish_probe (ProbeState *state, gboolean success)
{
    if (state->finished)
        return;

    state->finished = TRUE;
    state->completed = success;
    clear_sources (state);
    release_active_popover (state);
    g_clear_object (&state->test_ref);
    if (state->window)
    {
        gtk_window_destroy (state->window);
        g_object_unref (state->window);
        state->window = NULL;
    }
    g_main_loop_quit (state->loop);
}

int
main (int argc, char **argv)
{
    ProbeState state = { 0 };
    const GLogLevelFlags fatal_levels = G_LOG_FATAL_MASK | G_LOG_LEVEL_CRITICAL;

    if (argc == 2 && g_str_equal (argv[1], "--owner-release"))
        state.mode = OWNER_RELEASE;
    else if (argc == 2 && g_str_equal (argv[1], "--replacement"))
        state.mode = RETAINED_REPLACEMENT;
    else if (argc != 1)
    {
        g_printerr ("Usage: %s [--owner-release|--replacement]\n", argv[0]);
        return 2;
    }

    g_log_set_always_fatal (fatal_levels);
    g_log_set_fatal_mask ("Gtk", fatal_levels);
    g_log_set_fatal_mask ("Gdk", fatal_levels);
    g_log_set_fatal_mask ("GLib-GObject", fatal_levels);
    gtk_init ();
    state.loop = g_main_loop_new (NULL, FALSE);
    state.window = GTK_WINDOW (gtk_window_new ());
    state.anchor = gtk_button_new_with_label ("Popover anchor");
    gtk_window_set_child (state.window, state.anchor);
    gtk_window_present (state.window);
    g_object_ref (state.window);
    state.tick_widget = state.anchor;
    state.tick_id = gtk_widget_add_tick_callback (state.tick_widget,
                                                   arm_window_after_paint,
                                                   &state, NULL);
    state.watchdog_id = g_timeout_add (2000, watchdog_expired, &state);
    g_main_loop_run (state.loop);

    clear_sources (&state);
    if (state.weak_initialized)
        g_weak_ref_clear (&state.closed_popover);
    g_main_loop_unref (state.loop);
    return state.completed ? 0 : 1;
}

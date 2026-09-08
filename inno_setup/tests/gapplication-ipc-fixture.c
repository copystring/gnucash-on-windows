/* gapplication-ipc-fixture.c: Verify Windows GApplication command forwarding. */
/* Copyright 2026 GnuCash Development Team */
/* SPDX-License-Identifier: GPL-2.0-or-later */

#include <gio/gio.h>
#include <string.h>

typedef struct
{
    gboolean held;
} FixtureState;

static const gchar *
environment_state (const gchar *name)
{
    const gchar *value = g_getenv (name);

    if (value == NULL)
        return "unset";
    return *value == '\0' ? "empty" : "set";
}

static gboolean
write_bus_probe (const gchar *path,
                 GDBusConnection *connection,
                 const gchar *stage,
                 const GError *bus_error,
                 GError **write_error)
{
    const gchar *domain = bus_error == NULL
                              ? ""
                              : g_quark_to_string (bus_error->domain);
    const gchar *message = bus_error == NULL ? "" : bus_error->message;
    const gchar *unique_name = connection == NULL
                                   ? ""
                                   : g_dbus_connection_get_unique_name (connection);
    g_autofree gchar *contents = g_strdup_printf (
        "succeeded=%s\nstage=%s\ndomain=%s\ncode=%d\nmessage=%s\n"
        "unique_name=%s\ndbus_session_bus_address=%s\nxdg_runtime_dir=%s\n",
        connection != NULL && bus_error == NULL ? "true" : "false", stage,
        domain == NULL ? "" : domain,
        bus_error == NULL ? 0 : bus_error->code,
        message, unique_name == NULL ? "" : unique_name,
        environment_state ("DBUS_SESSION_BUS_ADDRESS"),
        environment_state ("XDG_RUNTIME_DIR"));

    return g_file_set_contents (path, contents, -1, write_error);
}

static int
write_error (GApplicationCommandLine *command_line,
             const gchar *operation,
             const gchar *path,
             GError *error)
{
    g_application_command_line_printerr (command_line,
                                         "%s '%s' failed: %s\n",
                                         operation, path, error->message);
    g_error_free (error);
    return 10;
}

static int
on_command_line (GApplication *application,
                 GApplicationCommandLine *command_line,
                 gpointer user_data)
{
    FixtureState *state = user_data;
    g_auto (GStrv) arguments = NULL;
    gint argument_count = 0;

    arguments = g_application_command_line_get_arguments (command_line,
                                                           &argument_count);

    if (argument_count == 4 && g_str_equal (arguments[1], "--primary"))
    {
        g_autofree gchar *contents = NULL;
        GError *error = NULL;

        if (g_application_command_line_get_is_remote (command_line))
        {
            g_application_command_line_printerr (
                command_line, "The primary invocation was unexpectedly remote.\n");
            return 2;
        }
        if (g_application_get_dbus_connection (application) == NULL)
        {
            g_application_command_line_printerr (
                command_line, "The primary invocation has no session-bus connection.\n");
            return 7;
        }

        g_application_hold (application);
        state->held = TRUE;
        contents = g_strdup ("remote=false\n");
        if (!g_file_set_contents (arguments[2], contents, -1, &error))
        {
            g_application_release (application);
            state->held = FALSE;
            return write_error (command_line, "Writing the readiness record",
                                arguments[2], error);
        }
        return 0;
    }

    if (argument_count == 4 && g_str_equal (arguments[1], "--forward"))
    {
        const gchar *cwd = g_application_command_line_get_cwd (command_line);
        g_autoptr (GFile) file = NULL;
        g_autofree gchar *uri = NULL;
        g_autofree gchar *contents = NULL;
        GError *error = NULL;

        if (!g_application_command_line_get_is_remote (command_line))
        {
            g_application_command_line_printerr (
                command_line, "The forwarding invocation was not delivered remotely.\n");
            return 3;
        }
        if (cwd == NULL)
        {
            g_application_command_line_printerr (
                command_line,
                "The forwarding invocation did not preserve its working directory.\n");
            return 4;
        }

        file = g_application_command_line_create_file_for_arg (command_line,
                                                               arguments[2]);
        uri = g_file_get_uri (file);
        contents = g_strdup_printf ("remote=true\ncwd=%s\nargument=%s\nuri=%s\n",
                                    cwd, arguments[2], uri);
        if (!g_file_set_contents (arguments[3], contents, -1, &error))
            return write_error (command_line, "Writing the forwarding record",
                                arguments[3], error);
        return 0;
    }

    if (argument_count == 2 && g_str_equal (arguments[1], "--reject"))
    {
        if (!g_application_command_line_get_is_remote (command_line))
        {
            g_application_command_line_printerr (
                command_line, "The rejected invocation was not delivered remotely.\n");
            return 8;
        }
        g_application_command_line_printerr (
            command_line, "Intentional remote fixture rejection.\n");
        return 23;
    }

    if (argument_count == 2 && g_str_equal (arguments[1], "--quit"))
    {
        if (!g_application_command_line_get_is_remote (command_line))
        {
            g_application_command_line_printerr (
                command_line, "The quit invocation was not delivered remotely.\n");
            return 5;
        }
        if (!state->held)
        {
            g_application_command_line_printerr (
                command_line, "The primary application was not held.\n");
            return 6;
        }

        state->held = FALSE;
        g_application_release (application);
        return 0;
    }

    g_application_command_line_printerr (
        command_line,
        "Usage: %s --primary READY BUS_PROBE | --forward ARG RECORD | --reject | --quit\n",
        arguments[0]);
    return 64;
}

int
main (int argc, char **argv)
{
    FixtureState state = { FALSE };
    g_autoptr (GApplication) application = NULL;
    g_autoptr (GDBusConnection) session_bus = NULL;

    if (argc == 4 && g_str_equal (argv[1], "--primary"))
    {
        GError *bus_error = NULL;
        GError *write_error = NULL;

        session_bus = g_bus_get_sync (G_BUS_TYPE_SESSION, NULL, &bus_error);
        if (!write_bus_probe (argv[3], session_bus, "g_bus_get_sync",
                              bus_error, &write_error))
        {
            g_printerr ("Writing the session-bus probe '%s' failed: %s\n",
                        argv[3], write_error->message);
            g_clear_error (&write_error);
            g_clear_error (&bus_error);
            return 70;
        }
        if (session_bus == NULL)
        {
            if (bus_error != NULL)
                g_printerr ("Session-bus probe failed (%s:%d): %s\n",
                            g_quark_to_string (bus_error->domain),
                            bus_error->code, bus_error->message);
            else
                g_printerr ("Session-bus probe returned no connection or error.\n");
            g_clear_error (&bus_error);
            return 71;
        }
    }

    application = g_application_new ("org.gnucash.GApplicationIpcFixture",
                                     G_APPLICATION_HANDLES_COMMAND_LINE);
    if (session_bus != NULL)
    {
        GError *registration_error = NULL;
        GError *write_error = NULL;

        if (!g_application_register (application, NULL, &registration_error))
        {
            if (!write_bus_probe (argv[3], session_bus,
                                  "g_application_register",
                                  registration_error, &write_error))
            {
                g_printerr ("Updating the session-bus probe '%s' failed: %s\n",
                            argv[3], write_error->message);
                g_clear_error (&write_error);
            }
            g_printerr ("GApplication registration failed (%s:%d): %s\n",
                        g_quark_to_string (registration_error->domain),
                        registration_error->code, registration_error->message);
            g_clear_error (&registration_error);
            return 72;
        }
    }
    g_signal_connect (application, "command-line",
                      G_CALLBACK (on_command_line), &state);
    return g_application_run (application, argc, argv);
}

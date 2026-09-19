/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Native GTK regression: a display filter must not outlive its IM context. */
#include <gtk/gtk.h>
#include <gdk/win32/gdkwin32.h>
#include <windows.h>
#include <imm.h>

/* The built-in type is exported by GTK, but has no installed public header.
 * All instance operations below use GtkIMContext's public interface. */
GType gtk_im_context_ime_get_type (void);

typedef enum
{
  NORMAL_FOCUS,
  REPEATED_FOCUS,
  DETACHED_CLIENT,
  DISPOSE_FOCUSED,
  REENTRANT_FOCUS
} Scenario;

typedef struct
{
  guint starts;
  guint ends;
  gboolean refocused;
} ReentrantState;

static void
preedit_started (GtkIMContext *context, ReentrantState *state)
{
  if (++state->starts == 1)
    gtk_im_context_focus_out (context);
}

static void
preedit_ended (GtkIMContext *context, ReentrantState *state)
{
  state->ends++;
  if (!state->refocused)
    {
      state->refocused = TRUE;
      gtk_im_context_focus_in (context);
    }
}

static void
context_finalized (gpointer data, GObject *object)
{
  gboolean *finalized = data;
  (void) object;
  *finalized = TRUE;
}

static void
run_scenario (Scenario scenario)
{
  GtkWidget *window = gtk_window_new ();
  /* An inert widget avoids a second GtkText-owned IM context consuming the
   * composition messages before the context under test can receive them. */
  GtkWidget *client = gtk_label_new ("IME filter lifetime");
  GtkIMContext *context;
  GdkSurface *surface;
  HWND hwnd;
  HIMC himc;
  gboolean finalized = FALSE;
  ReentrantState state = { 0, 0, FALSE };

  g_object_ref_sink (window);
  gtk_window_set_child (GTK_WINDOW (window), client);
  gtk_window_present (GTK_WINDOW (window));
  surface = gtk_native_get_surface (GTK_NATIVE (window));
  g_assert_true (GDK_IS_WIN32_SURFACE (surface));
  hwnd = gdk_win32_surface_get_handle (surface);
  himc = ImmGetContext (hwnd);
  /* A runner without an IM context cannot prove this regression. */
  g_assert_nonnull (himc);
  ImmReleaseContext (hwnd, himc);

  context = g_object_new (gtk_im_context_ime_get_type (), NULL);
  g_object_weak_ref (G_OBJECT (context), context_finalized, &finalized);
  gtk_im_context_set_client_widget (context, client);
  gtk_im_context_focus_in (context);
  if (scenario == REENTRANT_FOCUS)
    {
      guint previous;

      g_signal_connect (context, "preedit-start", G_CALLBACK (preedit_started), &state);
      g_signal_connect (context, "preedit-end", G_CALLBACK (preedit_ended), &state);
      SendMessageW (hwnd, WM_IME_STARTCOMPOSITION, 0, 0);
      g_assert_true (state.refocused);
      previous = state.ends;
      SendMessageW (hwnd, WM_IME_ENDCOMPOSITION, 0, 0);
      g_assert_cmpuint (state.ends, ==, previous + 1);
      previous = state.starts;
      SendMessageW (hwnd, WM_IME_STARTCOMPOSITION, 0, 0);
      g_assert_cmpuint (state.starts, ==, previous + 1);
      SendMessageW (hwnd, WM_IME_ENDCOMPOSITION, 0, 0);
    }
  if (scenario == REPEATED_FOCUS)
    gtk_im_context_focus_in (context);
  if (scenario == DETACHED_CLIENT)
    gtk_im_context_set_client_widget (context, NULL);
  if (scenario != DISPOSE_FOCUSED)
    gtk_im_context_focus_out (context);
  g_object_unref (context);
  g_assert_true (finalized);

  /* Dispatch a harmless native message even if presentation is deferred.
   * GDK applies the display filters before translating the message type. */
  SendMessageW (hwnd, WM_NULL, 0, 0);
  /* Closing a mapped window also dispatches WM_SHOWWINDOW, just like closing
   * GnuCash's transfer dialog. */
  gtk_window_destroy (GTK_WINDOW (window));
  g_object_unref (window);
}

static void
test_scenario (gconstpointer data)
{
  if (g_test_subprocess ())
    run_scenario (GPOINTER_TO_INT (data));
  else
    {
      g_test_trap_subprocess (NULL, 10 * G_USEC_PER_SEC, 0);
      g_test_trap_assert_passed ();
    }
}

int
main (int argc, char **argv)
{
  wchar_t filename[32768];
  HMODULE module;
  DWORD length;
  char *utf8_filename;

  gtk_test_init (&argc, &argv, NULL);
  module = GetModuleHandleW (L"libgtk-4-1.dll");
  g_assert_nonnull (module);
  length = GetModuleFileNameW (module, filename, G_N_ELEMENTS (filename));
  g_assert_cmpuint (length, >, 0);
  g_assert_cmpuint (length, <, G_N_ELEMENTS (filename));
  utf8_filename = g_utf16_to_utf8 ((const gunichar2 *) filename, length, NULL, NULL, NULL);
  g_assert_nonnull (utf8_filename);
  g_test_message ("loaded_gtk_dll=%s", utf8_filename);
  g_free (utf8_filename);
  g_test_add_data_func ("/ime/filter/normal", GINT_TO_POINTER (NORMAL_FOCUS), test_scenario);
  g_test_add_data_func ("/ime/filter/repeated-focus", GINT_TO_POINTER (REPEATED_FOCUS), test_scenario);
  g_test_add_data_func ("/ime/filter/detached-client", GINT_TO_POINTER (DETACHED_CLIENT), test_scenario);
  g_test_add_data_func ("/ime/filter/dispose-focused", GINT_TO_POINTER (DISPOSE_FOCUSED), test_scenario);
  g_test_add_data_func ("/ime/filter/reentrant-focus", GINT_TO_POINTER (REENTRANT_FOCUS), test_scenario);
  return g_test_run ();
}

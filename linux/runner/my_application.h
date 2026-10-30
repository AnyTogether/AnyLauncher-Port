#ifndef FLUTTER_MY_APPLICATION_H_
#define FLUTTER_MY_APPLICATION_H_

#include <gtk/gtk.h>

G_DECLARE_FINAL_TYPE(MyApplication,
                     my_application,
                     MY,
                     APPLICATION,
                     GtkApplication)

/**
 * my_application_new:
 *
 * Creates a new Flutter-based application.
 *
 * Returns: a new #MyApplication.
 */
MyApplication* my_application_new();

/**
 * my_application_take_run_marker:
 *
 * The launcher's marker of this run ("removeAfterClose"), for main to take away once the
 * application has ended cleanly; NULL when the launcher gave none. Free with g_free().
 */
gchar* my_application_take_run_marker(MyApplication* self);

#endif  // FLUTTER_MY_APPLICATION_H_

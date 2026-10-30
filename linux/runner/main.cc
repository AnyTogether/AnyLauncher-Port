#include <glib/gstdio.h>

#include "my_application.h"

int main(int argc, char** argv) {
  g_autofree gchar* run_marker = nullptr;
  int status;
  {
    g_autoptr(MyApplication) app = my_application_new();
    status = g_application_run(G_APPLICATION(app), argc, argv);
    run_marker = my_application_take_run_marker(app);
  }
  // A clean close: the launcher's marker of this run goes, so the next start finds no crash. A
  // crash anywhere before this line leaves it, and the next start offers a report.
  if (run_marker != nullptr) {
    g_remove(run_marker);
  }
  return status;
}

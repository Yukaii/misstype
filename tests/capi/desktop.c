/* Synthetic production-frontend smoke: a real GTK entry under Xvfb. */
#include <gtk/gtk.h>
#include <stdio.h>
static void activated(GtkEntry *entry, gpointer data) {
    (void)data;
    puts(gtk_entry_get_text(entry));
    fflush(stdout);
}
int main(int argc, char **argv) {
    gtk_init(&argc, &argv);
    GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(window), "Misstype desktop smoke");
    GtkWidget *entry = gtk_entry_new();
    gtk_container_add(GTK_CONTAINER(window), entry);
    g_signal_connect(entry, "activate", G_CALLBACK(activated), NULL);
    g_signal_connect(window, "destroy", G_CALLBACK(gtk_main_quit), NULL);
    gtk_widget_show_all(window);
    gtk_widget_grab_focus(entry);
    gtk_main();
    return 0;
}

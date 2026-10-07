/* misstype-dictionary-editor: GTK4 window over the user dictionary
 * (the Linux counterpart of macOS Settings -> My Dictionary).
 *
 * It owns no dictionary logic: every read and change goes through
 * `misstypectl dict ...`, so validation and the file format stay in
 * MisstypeCore. The engine reloads the file at the next composition.
 *
 * Usage: misstype-dictionary-editor [--file PATH]
 */
#include <gtk/gtk.h>
#include <string.h>

static char *g_file = NULL;       /* --file override, or NULL */
static char *g_ctl = NULL;        /* misstypectl path */
static GtkWidget *g_list = NULL;
static GtkWidget *g_status = NULL;
static GtkWidget *g_reading = NULL;
static GtkWidget *g_text = NULL;

/* Runs `misstypectl dict <args...>`; returns the exit status (-1 = cannot start),
 * filling stdout/stderr text (caller frees). */
static int run_ctl(const char *const *args, char **out, char **err) {
    GPtrArray *argv = g_ptr_array_new();
    g_ptr_array_add(argv, g_ctl);
    g_ptr_array_add(argv, "dict");
    for (; *args; ++args) g_ptr_array_add(argv, (gpointer)*args);
    if (g_file) {
        g_ptr_array_add(argv, "--file");
        g_ptr_array_add(argv, g_file);
    }
    g_ptr_array_add(argv, NULL);
    gint status = -1;
    GError *error = NULL;
    gboolean ok = g_spawn_sync(NULL, (gchar **)argv->pdata, NULL, G_SPAWN_DEFAULT, NULL, NULL, out, err, &status, &error);
    g_ptr_array_free(argv, TRUE);
    if (!ok) {
        if (err) *err = g_strdup(error->message);
        g_clear_error(&error);
        return -1;
    }
    return g_spawn_check_wait_status(status, NULL) ? 0 : (WIFEXITED(status) ? WEXITSTATUS(status) : -1);
}

static void set_status(const char *message) { gtk_label_set_text(GTK_LABEL(g_status), message ? message : ""); }

static void reload(void);

/* A row's button: remove a word, or show a hidden built-in again. */
static void on_row_action(GtkButton *button, gpointer unused) {
    (void)unused;
    const char *reading = g_object_get_data(G_OBJECT(button), "reading");
    const char *text = g_object_get_data(G_OBJECT(button), "text");
    gboolean hidden = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "hidden"));
    const char *args[] = {hidden ? "unexclude" : "remove", reading, text, NULL};
    char *out = NULL, *err = NULL;
    int status = run_ctl(args, &out, &err);
    set_status(status == 0 ? NULL : (err && *err ? err : "Could not change the dictionary"));
    g_free(out);
    g_free(err);
    reload();
}

static void add_row(const char *reading, const char *text, const char *weight, gboolean hidden) {
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_set_margin_start(row, 12);
    gtk_widget_set_margin_end(row, 12);
    gtk_widget_set_margin_top(row, 6);
    gtk_widget_set_margin_bottom(row, 6);

    GtkWidget *word = gtk_label_new(text);
    gtk_widget_set_halign(word, GTK_ALIGN_START);
    gtk_widget_add_css_class(word, "title-4");
    GtkWidget *detail = gtk_label_new(NULL);
    char *markup = g_markup_printf_escaped("<small>%s%s%s</small>", reading, hidden ? "  ·  hidden built-in" : "",
                                           weight ? weight : "");
    gtk_label_set_markup(GTK_LABEL(detail), markup);
    g_free(markup);
    gtk_widget_set_halign(detail, GTK_ALIGN_START);
    gtk_widget_add_css_class(detail, "dim-label");

    GtkWidget *labels = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_hexpand(labels, TRUE);
    gtk_box_append(GTK_BOX(labels), word);
    gtk_box_append(GTK_BOX(labels), detail);
    gtk_box_append(GTK_BOX(row), labels);

    GtkWidget *button = gtk_button_new_with_label(hidden ? "Show again" : "Remove");
    gtk_widget_set_valign(button, GTK_ALIGN_CENTER);
    g_object_set_data_full(G_OBJECT(button), "reading", g_strdup(reading), g_free);
    g_object_set_data_full(G_OBJECT(button), "text", g_strdup(text), g_free);
    g_object_set_data(G_OBJECT(button), "hidden", GINT_TO_POINTER(hidden));
    g_signal_connect(button, "clicked", G_CALLBACK(on_row_action), NULL);
    gtk_box_append(GTK_BOX(row), button);

    gtk_list_box_append(GTK_LIST_BOX(g_list), row);
}

/* `dict list --tsv` lines: [!]reading<TAB>text[<TAB>weight]. */
static void reload(void) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(g_list))) gtk_list_box_remove(GTK_LIST_BOX(g_list), child);

    const char *args[] = {"list", "--tsv", NULL};
    char *out = NULL, *err = NULL;
    if (run_ctl(args, &out, &err) != 0) {
        set_status(err && *err ? err : "misstypectl could not be started");
        g_free(out);
        g_free(err);
        return;
    }
    gchar **lines = g_strsplit(out, "\n", -1);
    for (gchar **line = lines; *line; ++line) {
        if (!**line) continue;
        gboolean hidden = (*line)[0] == '!';
        gchar **fields = g_strsplit(*line + (hidden ? 1 : 0), "\t", 3);
        if (fields[0] && fields[1]) {
            char *weight = fields[2] ? g_strdup_printf("  ·  weight %s", fields[2]) : NULL;
            add_row(fields[0], fields[1], weight, hidden);
            g_free(weight);
        }
        g_strfreev(fields);
    }
    g_strfreev(lines);
    g_free(out);
    g_free(err);
}

static void on_add(GtkWidget *unused, gpointer data) {
    (void)unused;
    (void)data;
    const char *reading = gtk_editable_get_text(GTK_EDITABLE(g_reading));
    const char *text = gtk_editable_get_text(GTK_EDITABLE(g_text));
    const char *args[] = {"add", reading, text, NULL};
    char *out = NULL, *err = NULL;
    int status = run_ctl(args, &out, &err);
    if (status == 0) {
        gtk_editable_set_text(GTK_EDITABLE(g_reading), "");
        gtk_editable_set_text(GTK_EDITABLE(g_text), "");
        set_status(NULL);
    } else {
        /* misstypectl says why: "1 character for 2 syllables", "not a Zhuyin syllable"... */
        char *message = err && *err ? g_strstrip(g_strdup(err)) : g_strdup("Could not add the word");
        set_status(message);
        g_free(message);
    }
    g_free(out);
    g_free(err);
    reload();
}

static char *find_ctl(const char *argv0) {
    char *dir = g_path_get_dirname(argv0);
    char *sibling = g_build_filename(dir, "misstypectl", NULL);
    g_free(dir);
    if (g_file_test(sibling, G_FILE_TEST_IS_EXECUTABLE)) return sibling;
    g_free(sibling);
    return g_find_program_in_path("misstypectl");
}

static void on_activate(GtkApplication *app, gpointer unused) {
    (void)unused;
    GtkWidget *window = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(window), "Misstype \xe2\x80\x94 My Dictionary");
    gtk_window_set_default_size(GTK_WINDOW(window), 520, 560);

    GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_start(root, 12);
    gtk_widget_set_margin_end(root, 12);
    gtk_widget_set_margin_top(root, 12);
    gtk_widget_set_margin_bottom(root, 12);
    gtk_window_set_child(GTK_WINDOW(window), root);

    GtkWidget *hint = gtk_label_new("Words you add rank above the built-in dictionary. "
                                    "In the input method, Shift+\xe2\x86\x90/\xe2\x86\x92 marks a phrase and "
                                    "Return files it here.");
    gtk_label_set_wrap(GTK_LABEL(hint), TRUE);
    gtk_label_set_xalign(GTK_LABEL(hint), 0);
    gtk_widget_add_css_class(hint, "dim-label");
    gtk_box_append(GTK_BOX(root), hint);

    GtkWidget *form = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    g_reading = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(g_reading), "Reading, e.g. \xe3\x84\x8b\xe3\x84\xa7\xcb\x87-\xe3\x84\x8f\xe3\x84\xa0\xcb\x87");
    gtk_widget_set_hexpand(g_reading, TRUE);
    g_text = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(g_text), "Word");
    gtk_widget_set_hexpand(g_text, TRUE);
    GtkWidget *add = gtk_button_new_with_label("Add");
    gtk_widget_add_css_class(add, "suggested-action");
    g_signal_connect(add, "clicked", G_CALLBACK(on_add), NULL);
    g_signal_connect(g_text, "activate", G_CALLBACK(on_add), NULL);
    gtk_box_append(GTK_BOX(form), g_reading);
    gtk_box_append(GTK_BOX(form), g_text);
    gtk_box_append(GTK_BOX(form), add);
    gtk_box_append(GTK_BOX(root), form);

    g_status = gtk_label_new(NULL);
    gtk_label_set_xalign(GTK_LABEL(g_status), 0);
    gtk_label_set_wrap(GTK_LABEL(g_status), TRUE);
    gtk_widget_add_css_class(g_status, "error");
    gtk_box_append(GTK_BOX(root), g_status);

    g_list = gtk_list_box_new();
    gtk_list_box_set_selection_mode(GTK_LIST_BOX(g_list), GTK_SELECTION_NONE);
    gtk_widget_add_css_class(g_list, "boxed-list");
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(scroll, TRUE);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), g_list);
    gtk_box_append(GTK_BOX(root), scroll);

    reload();
    gtk_window_present(GTK_WINDOW(window));
}

int main(int argc, char **argv) {
    char *ctl = find_ctl(argv[0]);
    /* Strip our own option before GTK sees the command line. */
    int out = 1;
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--file") == 0 && i + 1 < argc) {
            g_file = g_strdup(argv[++i]);
        } else {
            argv[out++] = argv[i];
        }
    }
    argc = out;
    if (!ctl) {
        g_printerr("misstype-dictionary-editor: misstypectl not found (install it next to this program or in PATH)\n");
        return 1;
    }
    g_ctl = ctl;
    GtkApplication *app = gtk_application_new("org.misstype.DictionaryEditor", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(app, "activate", G_CALLBACK(on_activate), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}

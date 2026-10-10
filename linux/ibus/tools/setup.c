/* ibus-setup-misstype: GTK4 settings window for the IBus engine (the Linux
 * counterpart of macOS Settings and the fcitx5 configtool page).
 *
 * ibus-setup and GNOME Settings launch it through the <setup> element of the
 * engine in misstype.xml. It owns no settings logic: values are read with
 * `misstypectl config list` and written with `misstypectl config set`, which
 * validates them and edits the same misstype.conf the engine watches, so a
 * change applies to the running engine at once.
 *
 * Keys, labels and choices mirror `settings` in core-zig/src/ctl.zig and
 * MisstypeConfig in linux/fcitx5/src/engine.cpp; keep them in step.
 * ShiftTogglesEnglish is not listed: under IBus lone Shift always toggles.
 *
 * Usage: ibus-setup-misstype [--file PATH]
 */
#include <gtk/gtk.h>
#include <string.h>

typedef enum { K_BOOL, K_CHOICE, K_INT, K_KEYS } Kind;
typedef struct {
    const char *key, *title, *subtitle;
    Kind kind;
    const char *const *choices; /* K_CHOICE, NULL-terminated */
    int lo, hi;                 /* K_INT */
} Row;

static const char *const repair[] = {"Off", "Light", "Standard", "Strong", NULL};
static const char *const cursor[] = {"Covering", "EndingAt", "BeginningAt", NULL};
static const char *const cursor_labels[] = {"Covering the cursor", "Ending at the cursor", "Beginning at the cursor", NULL};

static const Row rows[] = {
    {"RepairStrength", "Repair typing mistakes", "How far to guess past slips and neighbour keys", K_CHOICE, repair, 0, 0},
    {"ToneTolerance", "Tolerate wrong tones", NULL, K_BOOL, NULL, 0, 0},
    {"UserLearning", "Learn phrases you type", NULL, K_BOOL, NULL, 0, 0},
    {"ChannelLearning", "Learn your typing slips", "Experimental; needs phrase learning", K_BOOL, NULL, 0, 0},
    {"MixedEnglish", "Recognize English words while typing", NULL, K_BOOL, NULL, 0, 0},
    {"AutoShowCandidates", "Show candidates automatically", NULL, K_BOOL, NULL, 0, 0},
    {"ReturnConfirmsSelection", "Return confirms the selected candidate", NULL, K_BOOL, NULL, 0, 0},
    {"CandidateKeys", "Selection keys", "Up to ten distinct lowercase keys, e.g. asdfghjkl;", K_KEYS, NULL, 0, 0},
    {"CandidatesPerPage", "Candidates per page", NULL, K_INT, NULL, 4, 10},
    {"CursorCandidates", "Words listed at the syllable cursor", NULL, K_CHOICE, cursor, 0, 0},
    {"AutoCommitSyllables", "Commit long input in chunks", "After this many syllables (0 = never)", K_INT, NULL, 0, 64},
};
#define N_ROWS (sizeof rows / sizeof rows[0])

static char *g_file = NULL; /* --file override, or NULL */
static char *g_ctl = NULL;
static GtkWidget *g_status = NULL;
static gboolean g_loading = FALSE; /* programmatic widget updates must not write back */

/* Runs `misstypectl config <args...> [--file F]`; 0 = success. */
static int run_ctl(const char *const *args, char **out, char **err) {
    GPtrArray *argv = g_ptr_array_new();
    g_ptr_array_add(argv, g_ctl);
    g_ptr_array_add(argv, "config");
    for (; *args; ++args) g_ptr_array_add(argv, (gpointer)*args);
    g_ptr_array_add(argv, "--no-reload"); /* the IBus engine watches the file; fcitx5 is not involved */
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

static void set_status(const char *message) {
    char *text = message ? g_strstrip(g_strdup(message)) : NULL;
    gtk_label_set_text(GTK_LABEL(g_status), text ? text : "");
    g_free(text);
}

static void store(const char *key, const char *value) {
    if (g_loading) return;
    const char *args[] = {"set", key, value, NULL};
    char *out = NULL, *err = NULL;
    int status = run_ctl(args, &out, &err);
    set_status(status == 0 ? NULL : (err && *err ? err : "Could not save the setting"));
    g_free(out);
    g_free(err);
}

static const Row *row_of(gpointer widget) { return g_object_get_data(G_OBJECT(widget), "row"); }

static void on_switch(GObject *sw, GParamSpec *pspec, gpointer unused) {
    (void)pspec;
    (void)unused;
    store(row_of(sw)->key, gtk_switch_get_active(GTK_SWITCH(sw)) ? "on" : "off");
}

static void on_choice(GObject *dd, GParamSpec *pspec, gpointer unused) {
    (void)pspec;
    (void)unused;
    const Row *row = row_of(dd);
    guint i = gtk_drop_down_get_selected(GTK_DROP_DOWN(dd));
    store(row->key, row->choices[i]);
}

static void on_spin(GtkSpinButton *spin, gpointer unused) {
    (void)unused;
    char value[16];
    g_snprintf(value, sizeof value, "%d", gtk_spin_button_get_value_as_int(spin));
    store(row_of(spin)->key, value);
}

static void on_keys(GtkWidget *entry, gpointer unused) {
    (void)unused;
    store(row_of(entry)->key, gtk_editable_get_text(GTK_EDITABLE(entry)));
}

static void on_keys_leave(GtkEventControllerFocus *focus, gpointer entry) {
    (void)focus;
    on_keys(entry, NULL);
}

static GtkWidget *widgets[N_ROWS];

/* Fills every widget from `config list`: lines are Key=value[  (default)]. */
static void load(void) {
    const char *args[] = {"list", NULL};
    char *out = NULL, *err = NULL;
    if (run_ctl(args, &out, &err) != 0) {
        set_status(err && *err ? err : "misstypectl could not be started");
        g_free(out);
        g_free(err);
        return;
    }
    g_loading = TRUE;
    gchar **lines = g_strsplit(out, "\n", -1);
    for (gchar **line = lines; *line; ++line) {
        char *eq = strchr(*line, '=');
        if (!eq) continue;
        *eq = '\0';
        char *value = g_strstrip(eq + 1);
        char *tail = strstr(value, "  (default)");
        if (tail) *tail = '\0';
        for (size_t i = 0; i < N_ROWS; ++i) {
            if (strcmp(rows[i].key, *line) != 0) continue;
            GtkWidget *w = widgets[i];
            switch (rows[i].kind) {
            case K_BOOL: gtk_switch_set_active(GTK_SWITCH(w), g_ascii_strcasecmp(value, "true") == 0); break;
            case K_CHOICE:
                for (guint c = 0; rows[i].choices[c]; ++c)
                    if (g_ascii_strcasecmp(rows[i].choices[c], value) == 0) gtk_drop_down_set_selected(GTK_DROP_DOWN(w), c);
                break;
            case K_INT: gtk_spin_button_set_value(GTK_SPIN_BUTTON(w), g_ascii_strtod(value, NULL)); break;
            case K_KEYS: gtk_editable_set_text(GTK_EDITABLE(w), value); break;
            }
        }
    }
    g_strfreev(lines);
    g_loading = FALSE;
    g_free(out);
    g_free(err);
}

static GtkWidget *make_control(size_t i) {
    const Row *row = &rows[i];
    GtkWidget *w = NULL;
    switch (row->kind) {
    case K_BOOL:
        w = gtk_switch_new();
        g_signal_connect(w, "notify::active", G_CALLBACK(on_switch), NULL);
        break;
    case K_CHOICE: {
        const char *const *labels = row->choices == cursor ? cursor_labels : row->choices;
        w = gtk_drop_down_new_from_strings(labels);
        g_signal_connect(w, "notify::selected", G_CALLBACK(on_choice), NULL);
        break;
    }
    case K_INT:
        w = gtk_spin_button_new_with_range(row->lo, row->hi, 1);
        g_signal_connect(w, "value-changed", G_CALLBACK(on_spin), NULL);
        break;
    case K_KEYS: {
        w = gtk_entry_new();
        gtk_entry_set_max_length(GTK_ENTRY(w), 10);
        gtk_widget_set_size_request(w, 140, -1);
        g_signal_connect(w, "activate", G_CALLBACK(on_keys), NULL);
        GtkEventController *focus = gtk_event_controller_focus_new();
        g_signal_connect(focus, "leave", G_CALLBACK(on_keys_leave), w);
        gtk_widget_add_controller(w, focus);
        break;
    }
    }
    g_object_set_data(G_OBJECT(w), "row", (gpointer)row);
    gtk_widget_set_valign(w, GTK_ALIGN_CENTER);
    widgets[i] = w;
    return w;
}

static GtkWidget *make_row(size_t i) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_set_margin_start(box, 12);
    gtk_widget_set_margin_end(box, 12);
    gtk_widget_set_margin_top(box, 8);
    gtk_widget_set_margin_bottom(box, 8);

    GtkWidget *labels = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_hexpand(labels, TRUE);
    GtkWidget *title = gtk_label_new(rows[i].title);
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(labels), title);
    if (rows[i].subtitle) {
        GtkWidget *sub = gtk_label_new(rows[i].subtitle);
        gtk_widget_set_halign(sub, GTK_ALIGN_START);
        gtk_label_set_wrap(GTK_LABEL(sub), TRUE);
        gtk_label_set_xalign(GTK_LABEL(sub), 0);
        gtk_widget_add_css_class(sub, "dim-label");
        gtk_box_append(GTK_BOX(labels), sub);
    }
    gtk_box_append(GTK_BOX(box), labels);
    gtk_box_append(GTK_BOX(box), make_control(i));
    return box;
}

/* Opens the dictionary editor: the GTK4 tool from the fcitx5 package if
 * installed, else misstypectl's own `dict gui`. */
static void on_dictionary(GtkButton *button, gpointer unused) {
    (void)button;
    (void)unused;
    char *editor = g_find_program_in_path("misstype-dictionary-editor");
    GError *error = NULL;
    gboolean ok;
    if (editor) {
        const char *argv[] = {editor, NULL};
        ok = g_spawn_async(NULL, (gchar **)argv, NULL, G_SPAWN_DEFAULT, NULL, NULL, NULL, &error);
    } else {
        const char *argv[] = {g_ctl, "dict", "gui", NULL};
        ok = g_spawn_async(NULL, (gchar **)argv, NULL, G_SPAWN_DEFAULT, NULL, NULL, NULL, &error);
    }
    if (!ok) {
        set_status(error->message);
        g_clear_error(&error);
    }
    g_free(editor);
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
    gtk_window_set_title(GTK_WINDOW(window), "Misstype \xe2\x80\x94 Settings");
    gtk_window_set_default_size(GTK_WINDOW(window), 520, 640);

    GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_start(root, 12);
    gtk_widget_set_margin_end(root, 12);
    gtk_widget_set_margin_top(root, 12);
    gtk_widget_set_margin_bottom(root, 12);
    gtk_window_set_child(GTK_WINDOW(window), root);

    GtkWidget *list = gtk_list_box_new();
    gtk_list_box_set_selection_mode(GTK_LIST_BOX(list), GTK_SELECTION_NONE);
    gtk_widget_add_css_class(list, "boxed-list");
    for (size_t i = 0; i < N_ROWS; ++i) gtk_list_box_append(GTK_LIST_BOX(list), make_row(i));
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(scroll, TRUE);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), list);
    gtk_box_append(GTK_BOX(root), scroll);

    g_status = gtk_label_new(NULL);
    gtk_label_set_xalign(GTK_LABEL(g_status), 0);
    gtk_label_set_wrap(GTK_LABEL(g_status), TRUE);
    gtk_widget_add_css_class(g_status, "error");
    gtk_box_append(GTK_BOX(root), g_status);

    GtkWidget *dict = gtk_button_new_with_label("My Dictionary\xe2\x80\xa6");
    gtk_widget_set_halign(dict, GTK_ALIGN_START);
    g_signal_connect(dict, "clicked", G_CALLBACK(on_dictionary), NULL);
    gtk_box_append(GTK_BOX(root), dict);

    load();
    gtk_window_present(GTK_WINDOW(window));
}

int main(int argc, char **argv) {
    char *ctl = find_ctl(argv[0]);
    int out = 1; /* strip our own option before GTK sees the command line */
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--file") == 0 && i + 1 < argc) g_file = g_strdup(argv[++i]);
        else argv[out++] = argv[i];
    }
    argc = out;
    if (!ctl) {
        g_printerr("ibus-setup-misstype: misstypectl not found (install it next to this program or in PATH)\n");
        return 1;
    }
    g_ctl = ctl;
    GtkApplication *app = gtk_application_new("org.misstype.IBusSetup", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(app, "activate", G_CALLBACK(on_activate), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}

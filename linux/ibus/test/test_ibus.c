// Headless conformance test for the IBus adapter: docs/cross-platform.md
// scenarios C1-C15 and the delivery rules LR1-LR5, driven through a real
// ibus-daemon (script/linux/test_ibus.sh starts it and the engine). The test
// is an IBus client plus the panel: it sends key events with the evdev codes
// real clients send and reads the signals the daemon forwards.
#include <ibus.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    IBusBus *bus;
    IBusInputContext *ctx;
    IBusPanelService *panel;
    // What the client currently shows.
    char *preedit;
    guint caret; // characters
    gboolean preedit_visible;
    GPtrArray *candidates;
    GPtrArray *labels;
    guint cursor, page_size;
    gboolean lookup_visible;
    char *aux;
    gboolean aux_visible;
    GPtrArray *commits;
} Client;

static Client c;
static int failures;

#define CHECK(cond, ...)                                                       \
    do {                                                                       \
        if (!(cond)) {                                                         \
            fprintf(stderr, "FAIL %s:%d: %s: ", __FILE__, __LINE__, #cond);    \
            fprintf(stderr, __VA_ARGS__);                                      \
            fprintf(stderr, "\n");                                             \
            ++failures;                                                        \
        }                                                                      \
    } while (0)

static void pass(const char *id) { printf("PASS %s\n", id); fflush(stdout); }

// MARK: signals

static void on_commit(IBusInputContext *ctx, IBusText *text, gpointer data) {
    (void)ctx; (void)data;
    g_ptr_array_add(c.commits, g_strdup(ibus_text_get_text(text)));
}

static void on_preedit(IBusInputContext *ctx, IBusText *text, guint cursor, gboolean visible, guint mode, gpointer data) {
    (void)ctx; (void)mode; (void)data;
    g_free(c.preedit);
    c.preedit = g_strdup(ibus_text_get_text(text));
    c.caret = cursor;
    c.preedit_visible = visible;
}

static void on_hide_preedit(IBusInputContext *ctx, gpointer data) {
    (void)ctx; (void)data;
    c.preedit_visible = FALSE;
}

static void on_lookup(IBusInputContext *ctx, IBusLookupTable *table, gboolean visible, gpointer data) {
    (void)ctx; (void)data;
    g_ptr_array_set_size(c.candidates, 0);
    g_ptr_array_set_size(c.labels, 0);
    for (guint i = 0; i < ibus_lookup_table_get_number_of_candidates(table); ++i)
        g_ptr_array_add(c.candidates, g_strdup(ibus_text_get_text(ibus_lookup_table_get_candidate(table, i))));
    guint labels = ibus_lookup_table_get_number_of_candidates(table) ? ibus_lookup_table_get_page_size(table) : 0;
    for (guint i = 0; i < labels; ++i) {
        IBusText *label = ibus_lookup_table_get_label(table, i);
        g_ptr_array_add(c.labels, g_strdup(label ? ibus_text_get_text(label) : ""));
    }
    c.cursor = ibus_lookup_table_get_cursor_pos(table);
    c.page_size = ibus_lookup_table_get_page_size(table);
    c.lookup_visible = visible;
}

static void on_hide_lookup(IBusInputContext *ctx, gpointer data) {
    (void)ctx; (void)data;
    c.lookup_visible = FALSE;
}

static void on_aux(IBusInputContext *ctx, IBusText *text, gboolean visible, gpointer data) {
    (void)ctx; (void)data;
    g_free(c.aux);
    c.aux = g_strdup(ibus_text_get_text(text));
    c.aux_visible = visible;
}

static void on_hide_aux(IBusInputContext *ctx, gpointer data) {
    (void)ctx; (void)data;
    c.aux_visible = FALSE;
}

// Lets the daemon's signals arrive: iterate until the loop has been quiet.
static void pump(void) {
    int quiet = 0;
    while (quiet < 6) {
        gboolean any = FALSE;
        while (g_main_context_iteration(NULL, FALSE)) any = TRUE;
        quiet = any ? 0 : quiet + 1;
        g_usleep(8000);
    }
}

// MARK: helpers

typedef struct { guint keyval; guint evdev; } Physical;

// US-ANSI physical keys by unshifted label; evdev codes from linux/input-event-codes.h.
static Physical physical(char ch) {
    static const char *rows[] = {"qwertyuiop", "asdfghjkl", "zxcvbnm", "1234567890"};
    static const guint starts[] = {16, 30, 44, 2};
    for (int r = 0; r < 4; ++r) {
        const char *at = strchr(rows[r], ch);
        if (at && ch) return (Physical){(guint)ch, starts[r] + (guint)(at - rows[r])};
    }
    switch (ch) {
    case ';': return (Physical){IBUS_KEY_semicolon, 39};
    case '`': return (Physical){IBUS_KEY_grave, 41};
    case ',': return (Physical){IBUS_KEY_comma, 51};
    }
    CHECK(FALSE, "no physical key for %c", ch);
    return (Physical){0, 0};
}

enum { kEnter = 28, kBackspace = 14, kTab = 15, kEsc = 1, kLeft = 105, kRight = 106, kDown = 108, kSpace = 57,
       kShiftL = 42, kCtrlL = 29 };

// Returns whether the engine handled (swallowed) the key.
static gboolean key(guint keyval, guint evdev, guint state, gboolean release) {
    gboolean handled = ibus_input_context_process_key_event(c.ctx, keyval, evdev, release ? state | IBUS_RELEASE_MASK : state);
    pump();
    return handled;
}

static void type(const char *keys) {
    for (const char *p = keys; *p; ++p) {
        Physical k = physical(*p);
        CHECK(key(k.keyval, k.evdev, 0, FALSE), "key '%c' should be swallowed", *p);
    }
}

static const char *preedit(void) { return c.preedit_visible && c.preedit ? c.preedit : ""; }
static const char *aux(void) { return c.aux_visible && c.aux ? c.aux : ""; }
static gboolean lookup(void) { return c.lookup_visible && c.candidates->len > 0; }
static const char *cand(guint i) { return i < c.candidates->len ? g_ptr_array_index(c.candidates, i) : ""; }
static const char *label(guint i) { return i < c.labels->len ? g_ptr_array_index(c.labels, i) : ""; }

// Exactly these commits arrived since the last call.
static void expect_commits(const char *first, ...) {
    GPtrArray *want = g_ptr_array_new();
    va_list ap;
    va_start(ap, first);
    for (const char *s = first; s; s = va_arg(ap, const char *)) g_ptr_array_add(want, (gpointer)s);
    va_end(ap);
    gboolean same = want->len == c.commits->len;
    for (guint i = 0; same && i < want->len; ++i) same = strcmp(g_ptr_array_index(want, i), g_ptr_array_index(c.commits, i)) == 0;
    if (!same) {
        fprintf(stderr, "FAIL commits: want [");
        for (guint i = 0; i < want->len; ++i) fprintf(stderr, "%s'%s'", i ? ", " : "", (char *)g_ptr_array_index(want, i));
        fprintf(stderr, "] got [");
        for (guint i = 0; i < c.commits->len; ++i) fprintf(stderr, "%s'%s'", i ? ", " : "", (char *)g_ptr_array_index(c.commits, i));
        fprintf(stderr, "]\n");
        ++failures;
    }
    g_ptr_array_set_size(c.commits, 0);
    g_ptr_array_free(want, TRUE);
}
#define NO_COMMIT() expect_commits(NULL)

// Ends whatever composition is left (Escape leaves selection, then clears).
static void clear(void) {
    for (int i = 0; i < 3; ++i) key(IBUS_KEY_Escape, kEsc, 0, FALSE);
    CHECK(preedit()[0] == '\0', "composition not cleared: %s", preedit());
    CHECK(!lookup(), "candidate list not cleared");
    g_ptr_array_set_size(c.commits, 0);
}

// MARK: scenarios

static void run_all(void) {
    const guint shift = IBUS_SHIFT_MASK, ctrl = IBUS_CONTROL_MASK, alt = IBUS_MOD1_MASK;

    // C1: su3cl3, then Enter commits the preview.
    type("su3cl3");
    CHECK(strcmp(preedit(), "你好") == 0, "%s", preedit());
    CHECK(c.caret == 2, "caret %u", c.caret);
    CHECK(lookup() && c.candidates->len == 10, "candidates %u", c.candidates->len);
    CHECK(c.page_size == 8 && c.cursor == 0, "page %u cursor %u", c.page_size, c.cursor);
    CHECK(label(0)[0] == '\0', "selection keys type Zhuyin, so no labels: '%s'", label(0));
    CHECK(key(IBUS_KEY_Return, kEnter, 0, FALSE), "Enter swallowed");
    expect_commits("你好", NULL);
    CHECK(preedit()[0] == '\0' && !lookup(), "cleared after commit: '%s'", preedit());
    pass("C1");

    // C2: empty composition passes Enter/Backspace/Left; Space commits " ".
    CHECK(!key(IBUS_KEY_Return, kEnter, 0, FALSE), "empty Enter passes");
    CHECK(!key(IBUS_KEY_BackSpace, kBackspace, 0, FALSE), "empty Backspace passes");
    CHECK(!key(IBUS_KEY_Left, kLeft, 0, FALSE), "empty Left passes");
    NO_COMMIT();
    CHECK(key(IBUS_KEY_space, kSpace, 0, FALSE), "Space swallowed");
    expect_commits(" ", NULL);
    pass("C2");

    // C3: Backspace edits without committing.
    type("su3cl3");
    CHECK(key(IBUS_KEY_BackSpace, kBackspace, 0, FALSE), "Backspace swallowed");
    CHECK(strcmp(preedit(), "你") == 0, "%s", preedit());
    NO_COMMIT();
    clear();
    pass("C3");

    // C4: Tab, d, Enter picks row 3 (尼) of the first page.
    type("su3");
    CHECK(key(IBUS_KEY_Tab, kTab, 0, FALSE), "Tab swallowed");
    CHECK(label(0)[0] == 'a', "Tab arms the selection keys: '%s'", label(0));
    type("d");
    CHECK(strcmp(preedit(), "尼") == 0, "%s", preedit());
    CHECK(key(IBUS_KEY_Return, kEnter, 0, FALSE), "Enter swallowed");
    expect_commits("尼", NULL);
    pass("C4");

    // C5: Down selects 妳; first Esc leaves selection, second clears.
    type("su3");
    CHECK(key(IBUS_KEY_Down, kDown, 0, FALSE), "Down swallowed");
    CHECK(strcmp(preedit(), "妳") == 0, "%s", preedit());
    CHECK(key(IBUS_KEY_Escape, kEsc, 0, FALSE), "Esc swallowed");
    CHECK(strcmp(preedit(), "妳") == 0, "%s", preedit());
    CHECK(key(IBUS_KEY_Escape, kEsc, 0, FALSE), "Esc swallowed");
    CHECK(preedit()[0] == '\0', "%s", preedit());
    NO_COMMIT();
    pass("C5");

    // C6: Shift+, and Shift+a stay inside the composition.
    type("su3");
    CHECK(key(IBUS_KEY_less, physical(',').evdev, shift, FALSE), "Shift+, swallowed");
    CHECK(strcmp(preedit(), "你，") == 0, "%s", preedit());
    CHECK(key(IBUS_KEY_A, physical('a').evdev, shift, FALSE), "Shift+a swallowed");
    CHECK(strcmp(preedit(), "你，A") == 0, "%s", preedit());
    CHECK(key(IBUS_KEY_Return, kEnter, 0, FALSE), "Enter swallowed");
    expect_commits("你，A", NULL);
    pass("C6");

    // C7: backtick starts a Latin run that survives Escape.
    type("su3`hi");
    CHECK(strcmp(preedit(), "你hi") == 0, "%s", preedit());
    clear();
    type("ok");
    CHECK(strcmp(preedit(), "ok") == 0, "run survives Escape: %s", preedit());
    clear();
    type("`");
    pass("C7");

    // C8: Right at the end beeps (swallowed, no change); Left focuses a word
    // without arming the selection keys; Tab arms them.
    type("su3cl3");
    CHECK(key(IBUS_KEY_Right, kRight, 0, FALSE), "Right swallowed");
    CHECK(strcmp(preedit(), "你好") == 0, "%s", preedit());
    CHECK(key(IBUS_KEY_Left, kLeft, 0, FALSE), "Left swallowed");
    CHECK(strcmp(preedit(), "你好") == 0 && c.caret == 1, "caret %u", c.caret);
    CHECK(lookup() && strcmp(cand(0), "你好") == 0, "first candidate %s", cand(0));
    CHECK(label(0)[0] == '\0', "selection keys type at the cursor: '%s'", label(0));
    CHECK(key(IBUS_KEY_Tab, kTab, 0, FALSE), "Tab swallowed");
    CHECK(label(0)[0] == 'a', "Tab arms the selection keys: '%s'", label(0));
    clear();
    pass("C8");

    // C14: typing at the syllable cursor inserts there.
    type("su3a87");
    CHECK(strcmp(preedit(), "你嗎") == 0, "%s", preedit());
    CHECK(key(IBUS_KEY_Left, kLeft, 0, FALSE), "Left swallowed");
    type("cl3");
    CHECK(strcmp(preedit(), "你好嗎") == 0 && c.caret == 2, "%s caret %u", preedit(), c.caret);
    clear();
    pass("C14");

    // C15: in a Latin run Alt+Backspace deletes a word, Alt+Left jumps one
    // and typing follows the caret.
    type("su3`hello");
    CHECK(key(IBUS_KEY_space, kSpace, 0, FALSE), "Space swallowed");
    type("world");
    CHECK(key(IBUS_KEY_BackSpace, kBackspace, alt, FALSE), "Alt+Backspace swallowed");
    CHECK(strcmp(preedit(), "你hello ") == 0, "%s", preedit());
    type("world");
    CHECK(key(IBUS_KEY_Left, kLeft, alt, FALSE), "Alt+Left swallowed");
    CHECK(c.caret == 7, "caret %u", c.caret); // 你hello_ = 7 characters
    type("big");
    CHECK(key(IBUS_KEY_space, kSpace, 0, FALSE), "Space swallowed");
    CHECK(strcmp(preedit(), "你hello big world") == 0 && c.caret == 11, "%s caret %u", preedit(), c.caret);
    clear();
    type("`");
    pass("C15");

    // C9: Ctrl+c commits the preview, then the shortcut reaches the application.
    type("su3");
    CHECK(!key('c', physical('c').evdev, ctrl, FALSE), "Ctrl+c passes");
    expect_commits("你", NULL);
    CHECK(preedit()[0] == '\0', "%s", preedit());
    pass("C9");

    // C10: Shift+Space commits, flips to English (indicator), and letters pass.
    type("su3");
    CHECK(key(IBUS_KEY_space, kSpace, shift, FALSE), "Shift+Space swallowed");
    expect_commits("你", NULL);
    CHECK(strcmp(aux(), "英") == 0, "mode indicator: '%s'", aux());
    CHECK(!key('s', physical('s').evdev, 0, FALSE), "English mode passes letters");
    CHECK(aux()[0] == '\0', "next render clears the indicator: '%s'", aux());
    CHECK(key(IBUS_KEY_space, kSpace, shift, FALSE), "Shift+Space swallowed");
    CHECK(strcmp(aux(), "中") == 0, "'%s'", aux());
    type("su3"); // Chinese again
    clear();
    pass("C10");

    // C11: focus out commits the composition exactly once.
    type("su3");
    ibus_input_context_focus_out(c.ctx);
    pump();
    ibus_input_context_focus_in(c.ctx);
    pump();
    expect_commits("你", NULL);
    CHECK(preedit()[0] == '\0' && !lookup(), "cleared: '%s'", preedit());
    CHECK(!key(IBUS_KEY_Return, kEnter, 0, FALSE), "session must be empty after focus out");
    pass("C11");

    // LR4: a client without preedit support still gets the text exactly once
    // when focus leaves (the engine draws no preedit for it, so it must insert).
    ibus_input_context_set_capabilities(c.ctx, IBUS_CAP_FOCUS | IBUS_CAP_AUXILIARY_TEXT | IBUS_CAP_LOOKUP_TABLE);
    pump();
    type("su3");
    ibus_input_context_focus_out(c.ctx);
    pump();
    ibus_input_context_focus_in(c.ctx);
    pump();
    expect_commits("你", NULL);
    ibus_input_context_set_capabilities(c.ctx, IBUS_CAP_PREEDIT_TEXT | IBUS_CAP_FOCUS | IBUS_CAP_AUXILIARY_TEXT |
                                                   IBUS_CAP_LOOKUP_TABLE | IBUS_CAP_SURROUNDING_TEXT);
    pump();
    pass("LR4");

    // C12: a panel click on row 3 replaces the preview with 泥.
    type("su3");
    CHECK(c.candidates->len == 5, "candidates %u", c.candidates->len);
    ibus_panel_service_candidate_clicked(c.panel, 3, 1, 0);
    pump();
    CHECK(strcmp(preedit(), "泥") == 0, "%s", preedit());
    clear();
    pass("C12");

    // C13: Shift+Left twice marks 你好; Enter files the phrase without committing.
    type("su3cl3");
    CHECK(key(IBUS_KEY_Left, kLeft, shift, FALSE), "Shift+Left swallowed");
    CHECK(key(IBUS_KEY_Left, kLeft, shift, FALSE), "Shift+Left swallowed");
    CHECK(strcmp(preedit(), "你好") == 0, "%s", preedit());
    CHECK(strstr(aux(), "add") != NULL && strstr(aux(), "你好") != NULL, "mark hint: '%s'", aux());
    CHECK(key(IBUS_KEY_Return, kEnter, 0, FALSE), "Enter swallowed");
    NO_COMMIT();
    CHECK(strcmp(preedit(), "你好") == 0, "%s", preedit());
    clear();
    pass("C13");

    // LR5: rewriting the settings file (misstypectl config set, the settings
    // window) reaches the running engine without a restart.
    const char *conf = g_getenv("MISSTYPE_CONFIG");
    if (conf) {
        gchar *before = NULL;
        CHECK(g_file_get_contents(conf, &before, NULL, NULL), "read %s", conf);
        type("su3");
        CHECK(c.page_size == 8, "default page size: %u", c.page_size);
        clear();
        gchar *changed = g_strconcat(before ? before : "", "CandidatesPerPage=4\n", NULL);
        CHECK(g_file_set_contents(conf, changed, -1, NULL), "write %s", conf);
        for (int i = 0; i < 10; ++i) { // rate limit 50 ms + debounce 150 ms
            g_usleep(60000);
            pump();
        }
        type("su3");
        CHECK(c.page_size == 4, "page size after the file changed: %u", c.page_size);
        clear();
        g_file_set_contents(conf, before ? before : "", -1, NULL);
        g_free(changed);
        g_free(before);
        pass("LR5");
    }

    // LR1: a key release is never swallowed and changes nothing.
    type("su3");
    CHECK(!key('s', physical('s').evdev, 0, TRUE), "release passes");
    CHECK(strcmp(preedit(), "你") == 0, "%s", preedit());
    pass("LR1");

    // LR2: a bare Control press is not swallowed and leaves the preedit alone.
    CHECK(!key(IBUS_KEY_Control_L, kCtrlL, 0, FALSE), "bare Ctrl passes");
    CHECK(strcmp(preedit(), "你") == 0, "%s", preedit());
    CHECK(!key(IBUS_KEY_Control_L, kCtrlL, ctrl, TRUE), "Ctrl release passes");
    CHECK(strcmp(preedit(), "你") == 0, "%s", preedit());
    pass("LR2");

    // LR3: a Shift tap is not swallowed; the composition stays.
    CHECK(!key(IBUS_KEY_Shift_L, kShiftL, 0, FALSE), "Shift press passes");
    CHECK(strcmp(preedit(), "你") == 0, "%s", preedit());
    CHECK(!key(IBUS_KEY_Shift_L, kShiftL, shift, TRUE), "Shift release passes");
    clear();
    pass("LR3");
}

int main(void) {
    ibus_init();
    c.bus = ibus_bus_new();
    if (!ibus_bus_is_connected(c.bus)) {
        fprintf(stderr, "no ibus-daemon\n");
        return 2;
    }
    c.candidates = g_ptr_array_new_with_free_func(g_free);
    c.labels = g_ptr_array_new_with_free_func(g_free);
    c.commits = g_ptr_array_new_with_free_func(g_free);

    // The test is the panel too, so candidate clicks can be sent (the daemon
    // started with --panel disable).
    c.panel = ibus_panel_service_new(ibus_bus_get_connection(c.bus));
    ibus_bus_request_name(c.bus, IBUS_SERVICE_PANEL, 0);

    c.ctx = ibus_bus_create_input_context(c.bus, "misstype-test");
    if (!c.ctx) {
        fprintf(stderr, "cannot create an input context\n");
        return 2;
    }
    g_signal_connect(c.ctx, "commit-text", G_CALLBACK(on_commit), NULL);
    g_signal_connect(c.ctx, "update-preedit-text", G_CALLBACK(on_preedit), NULL);
    g_signal_connect(c.ctx, "hide-preedit-text", G_CALLBACK(on_hide_preedit), NULL);
    g_signal_connect(c.ctx, "update-lookup-table", G_CALLBACK(on_lookup), NULL);
    g_signal_connect(c.ctx, "hide-lookup-table", G_CALLBACK(on_hide_lookup), NULL);
    g_signal_connect(c.ctx, "update-auxiliary-text", G_CALLBACK(on_aux), NULL);
    g_signal_connect(c.ctx, "hide-auxiliary-text", G_CALLBACK(on_hide_aux), NULL);
    ibus_input_context_set_capabilities(c.ctx, IBUS_CAP_PREEDIT_TEXT | IBUS_CAP_FOCUS | IBUS_CAP_AUXILIARY_TEXT |
                                                   IBUS_CAP_LOOKUP_TABLE | IBUS_CAP_SURROUNDING_TEXT);
    ibus_input_context_focus_in(c.ctx);
    ibus_input_context_set_engine(c.ctx, "misstype");
    pump();
    IBusEngineDesc *desc = ibus_input_context_get_engine(c.ctx);
    if (!desc || strcmp(ibus_engine_desc_get_name(desc), "misstype") != 0) {
        fprintf(stderr, "the misstype engine is not active\n");
        return 2;
    }
    run_all();
    printf(failures ? "IBUS FAILED (%d)\n" : "IBUS OK\n", failures);
    return failures ? 1 : 0;
}

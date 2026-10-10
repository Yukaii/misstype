// IBus adapter for Misstype: key translation, applying key results, drawing
// the session view (docs/cross-platform.md §1–§4, docs/ibus-port.md).
#include "engine.h"

#include <string.h>

static misstype_engine *g_core;

void misstype_ibus_set_core(misstype_engine *core) { g_core = core; }

struct _MisstypeIBusEngine {
    IBusEngine parent_instance;
    misstype_session *session;
    char *last_sig;      // signature of the view the client currently shows
    gboolean aux_shown;  // the 中/英 indicator is up
    int page_start;      // global index of the first row of the drawn page
};

G_DEFINE_TYPE(MisstypeIBusEngine, misstype_ibus_engine, IBUS_TYPE_ENGINE)

// MARK: - Key translation (contract §1)

static uint32_t modifier_bit(guint keyval) {
    switch (keyval) {
    case IBUS_KEY_Shift_L:
    case IBUS_KEY_Shift_R:
        return MISSTYPE_MOD_SHIFT;
    case IBUS_KEY_Control_L:
    case IBUS_KEY_Control_R:
        return MISSTYPE_MOD_CONTROL;
    case IBUS_KEY_Alt_L:
    case IBUS_KEY_Alt_R:
    case IBUS_KEY_Meta_L:
    case IBUS_KEY_Meta_R:
        return MISSTYPE_MOD_ALT;
    case IBUS_KEY_Super_L:
    case IBUS_KEY_Super_R:
        return MISSTYPE_MOD_SUPER;
    default:
        return 0;
    }
}

// Special keys by keysym, for clients that send no usable scancode.
static misstype_key_kind kind_from_keyval(guint keyval) {
    switch (keyval) {
    case IBUS_KEY_space: return MISSTYPE_KEY_SPACE;
    case IBUS_KEY_Return:
    case IBUS_KEY_KP_Enter: return MISSTYPE_KEY_ENTER;
    case IBUS_KEY_Tab:
    case IBUS_KEY_ISO_Left_Tab: return MISSTYPE_KEY_TAB;
    case IBUS_KEY_BackSpace: return MISSTYPE_KEY_BACKSPACE;
    case IBUS_KEY_Delete: return MISSTYPE_KEY_FORWARD_DELETE;
    case IBUS_KEY_Escape: return MISSTYPE_KEY_ESCAPE;
    case IBUS_KEY_Left: return MISSTYPE_KEY_LEFT;
    case IBUS_KEY_Right: return MISSTYPE_KEY_RIGHT;
    case IBUS_KEY_Up: return MISSTYPE_KEY_UP;
    case IBUS_KEY_Down: return MISSTYPE_KEY_DOWN;
    case IBUS_KEY_Page_Up: return MISSTYPE_KEY_PAGE_UP;
    case IBUS_KEY_Page_Down: return MISSTYPE_KEY_PAGE_DOWN;
    case IBUS_KEY_Shift_L: return MISSTYPE_KEY_SHIFT_LEFT;
    case IBUS_KEY_Shift_R: return MISSTYPE_KEY_SHIFT_RIGHT;
    default: return modifier_bit(keyval) ? MISSTYPE_KEY_MODIFIER : MISSTYPE_KEY_OTHER;
    }
}

// `text` backs misstype_key_event.text; it must outlive the handle call.
static misstype_key_event build_event(guint keyval, guint keycode, guint state, char text[8]) {
    misstype_key_event ev = {0};
    ev.kind = MISSTYPE_KEY_OTHER;
    ev.native_code = (int32_t)keycode;
    ev.timestamp = -1;
    ev.is_release = (state & IBUS_RELEASE_MASK) ? 1 : 0;

    // IBus clients send the evdev code (the X11 keycode minus 8).
    if (keycode > 0) ev.kind = misstype_key_from_evdev((int32_t)keycode, &ev.label);

    // Text the key types in the user's layout (case included).
    gunichar u = ibus_keyval_to_unicode(keyval);
    if (u && g_unichar_isprint(u)) {
        text[g_unichar_to_utf8(u, text)] = '\0';
        ev.text = text;
    }

    uint32_t mods = 0;
    if (state & IBUS_SHIFT_MASK) mods |= MISSTYPE_MOD_SHIFT;
    if (state & IBUS_CONTROL_MASK) mods |= MISSTYPE_MOD_CONTROL;
    if (state & IBUS_MOD1_MASK) mods |= MISSTYPE_MOD_ALT;
    if (state & (IBUS_SUPER_MASK | IBUS_MOD4_MASK)) mods |= MISSTYPE_MOD_SUPER;
    if (state & IBUS_LOCK_MASK) mods |= MISSTYPE_MOD_CAPS_LOCK;

    // IBus reports the state BEFORE the event; the contract wants AFTER. A
    // modifier key's own press adds its bit and its release removes it. Shift
    // goes by the physical key (xkb options can turn a Shift release into
    // Caps_Lock).
    const gboolean shift_key = ev.kind == MISSTYPE_KEY_SHIFT_LEFT || ev.kind == MISSTYPE_KEY_SHIFT_RIGHT;
    uint32_t own = shift_key ? MISSTYPE_MOD_SHIFT : modifier_bit(keyval);
    if (own) mods = ev.is_release ? (mods & ~own) : (mods | own);

    // No usable scancode: special keys by keysym, then the typed character.
    if (ev.kind == MISSTYPE_KEY_OTHER) {
        ev.kind = kind_from_keyval(keyval);
        if (ev.kind == MISSTYPE_KEY_OTHER && ev.text) {
            int32_t shifted = 0;
            ev.kind = misstype_key_from_character(ev.text, &ev.label, &shifted);
            if (ev.kind != MISSTYPE_KEY_OTHER && shifted) mods |= MISSTYPE_MOD_SHIFT;
        }
    }
    ev.modifiers = mods;
    return ev;
}

// MARK: - Rendering (contract §3)

static void hide_aux(IBusEngine *engine) { ibus_engine_hide_auxiliary_text(engine); }

static void show_aux(IBusEngine *engine, const char *text) {
    ibus_engine_update_auxiliary_text(engine, ibus_text_new_from_string(text), TRUE);
}

static void clear_preedit(IBusEngine *engine) {
    ibus_engine_update_preedit_text_with_mode(engine, ibus_text_new_from_string(""), 0, FALSE,
                                              IBUS_ENGINE_PREEDIT_CLEAR);
}

static void commit_string(IBusEngine *engine, const char *text) {
    ibus_engine_commit_text(engine, ibus_text_new_from_string(text));
}

// Everything the client can see, so an unchanged view is not redrawn.
static char *view_signature(const misstype_view *v, gboolean latin) {
    GString *s = g_string_new(NULL);
    g_string_append_printf(s, "%s|%d|%d|%d|%d|%d|%d|%d|%d|%d|%s|%s|%d", v->preedit ? v->preedit : "", v->caret_bytes,
                           v->selected, v->keys_active, v->shows_candidates, v->mark_action, v->mark_start_bytes,
                           v->mark_end_bytes, v->page_size, latin, v->mark_text ? v->mark_text : "",
                           v->mark_reading ? v->mark_reading : "", v->candidate_count);
    for (int i = 0; i < v->candidate_count; ++i) g_string_append_printf(s, "|%s", v->candidates[i]);
    for (int i = 0; i < v->selection_key_count; ++i) g_string_append_printf(s, "|%s", v->selection_keys[i]);
    return g_string_free(s, FALSE);
}

// What Enter will do with the mark (shown as auxiliary text).
static char *mark_hint(const misstype_view *v) {
    const char *text = v->mark_text ? v->mark_text : "";
    const char *reading = v->mark_reading ? v->mark_reading : "";
    switch (v->mark_action) {
    case MISSTYPE_MARK_ADD: return g_strdup_printf("⏎ add \"%s\"  %s", text, reading);
    case MISSTYPE_MARK_REMOVE: return g_strdup_printf("⏎ remove \"%s\"  %s", text, reading);
    case MISSTYPE_MARK_UNAVAILABLE: return g_strdup("Can't add this selection");
    default: return g_strdup("Mark 2-8 syllables");
    }
}

static void render(MisstypeIBusEngine *self, gboolean force) {
    IBusEngine *engine = IBUS_ENGINE(self);
    misstype_view *v = misstype_session_view(self->session);
    if (!v) return;
    const gboolean latin = misstype_session_latin_active(self->session) != 0;
    char *sig = view_signature(v, latin);
    if (!force && self->last_sig && strcmp(self->last_sig, sig) == 0) {
        g_free(sig);
        misstype_view_free(v);
        return;
    }
    g_free(self->last_sig);
    self->last_sig = sig;
    self->aux_shown = FALSE;

    const char *preedit = v->preedit ? v->preedit : "";
    const glong chars = g_utf8_strlen(preedit, -1);
    const gboolean marking = v->mark_action != MISSTYPE_MARK_NONE && v->mark_start_bytes >= 0 &&
                             v->mark_end_bytes >= v->mark_start_bytes && v->mark_end_bytes <= (int)strlen(preedit);
    if (chars == 0) {
        clear_preedit(engine);
    } else {
        IBusText *text = ibus_text_new_from_string(preedit);
        ibus_text_append_attribute(text, IBUS_ATTR_TYPE_UNDERLINE, IBUS_ATTR_UNDERLINE_SINGLE, 0, (guint)chars);
        if (marking) {
            guint from = (guint)g_utf8_pointer_to_offset(preedit, preedit + v->mark_start_bytes);
            guint to = (guint)g_utf8_pointer_to_offset(preedit, preedit + v->mark_end_bytes);
            ibus_text_append_attribute(text, IBUS_ATTR_TYPE_BACKGROUND, 0xd0e4ff, from, to);
        }
        guint caret = (guint)g_utf8_pointer_to_offset(preedit, preedit + CLAMP(v->caret_bytes, 0, (int)strlen(preedit)));
        // COMMIT: the daemon inserts the drawn preedit when focus leaves (contract §4).
        ibus_engine_update_preedit_text_with_mode(engine, text, caret, TRUE, IBUS_ENGINE_PREEDIT_COMMIT);
    }

    if (v->shows_candidates && v->candidate_count > 0) {
        const guint page = v->page_size > 0 ? (guint)v->page_size : 8;
        IBusLookupTable *table = ibus_lookup_table_new(page, 0, TRUE, FALSE);
        ibus_lookup_table_set_orientation(table, IBUS_ORIENTATION_VERTICAL);
        for (int i = 0; i < v->candidate_count; ++i)
            ibus_lookup_table_append_candidate(table, ibus_text_new_from_string(v->candidates[i]));
        // Labels are selection keys only while they pick; otherwise they type Zhuyin.
        for (guint i = 0; i < page; ++i) {
            const char *label = v->keys_active && (int)i < v->selection_key_count ? v->selection_keys[i] : "";
            ibus_lookup_table_append_label(table, ibus_text_new_from_string(label));
        }
        ibus_lookup_table_set_cursor_pos(table, (guint)CLAMP(v->selected, 0, v->candidate_count - 1));
        self->page_start = v->selected / (int)page * (int)page;
        ibus_engine_update_lookup_table(engine, table, TRUE);
    } else {
        ibus_engine_hide_lookup_table(engine);
        self->page_start = 0;
    }

    if (marking) {
        char *hint = mark_hint(v);
        show_aux(engine, hint);
        g_free(hint);
    } else if (latin) {
        show_aux(engine, "英");
    } else {
        hide_aux(engine);
    }
    misstype_view_free(v);
}

// MARK: - Engine callbacks

static gboolean process_key_event(IBusEngine *engine, guint keyval, guint keycode, guint state) {
    MisstypeIBusEngine *self = MISSTYPE_IBUS_ENGINE(engine);
    if (!self->session) return FALSE;

    char text[8];
    misstype_key_event ev = build_event(keyval, keycode, state, text);
    const gboolean latin_before = misstype_session_latin_active(self->session) != 0;
    misstype_key_result result = misstype_session_handle(self->session, &ev);
    const gboolean latin_closed = latin_before && !misstype_session_latin_active(self->session);

    // Contract §2: commit, then render, then the mode indicator.
    if (result.commit) {
        commit_string(engine, result.commit);
        misstype_string_free(result.commit);
        g_clear_pointer(&self->last_sig, g_free);
    }
    render(self, result.mode_changed || latin_closed || self->aux_shown);
    if (result.mode_changed || latin_closed) {
        const gboolean english = !latin_closed && g_core && misstype_engine_is_english(g_core) != 0;
        show_aux(engine, english ? "英" : "中");
        self->aux_shown = TRUE;
    }

    // Delivery rules: releases and bare modifiers are never filtered.
    const gboolean bare = ev.kind == MISSTYPE_KEY_MODIFIER || ev.kind == MISSTYPE_KEY_SHIFT_LEFT ||
                          ev.kind == MISSTYPE_KEY_SHIFT_RIGHT;
    return result.consumed && !ev.is_release && !bare;
}

static void drop_composition(MisstypeIBusEngine *self) {
    if (!self->session) return;
    // The session always drops its composition; the daemon inserts the drawn
    // preedit (PREEDIT_COMMIT) when focus leaves, so we only clear our state.
    char *text = misstype_session_commit(self->session);
    if (text) misstype_string_free(text);
    g_clear_pointer(&self->last_sig, g_free);
    self->aux_shown = FALSE;
}

static void focus_in(IBusEngine *engine) {
    MisstypeIBusEngine *self = MISSTYPE_IBUS_ENGINE(engine);
    if (self->session) misstype_session_reset_modifiers(self->session);
}

static void focus_out(IBusEngine *engine) { drop_composition(MISSTYPE_IBUS_ENGINE(engine)); }

// Client reset (the application dropped its text): discard, never insert.
static void reset(IBusEngine *engine) {
    MisstypeIBusEngine *self = MISSTYPE_IBUS_ENGINE(engine);
    drop_composition(self);
    clear_preedit(engine);
    ibus_engine_hide_lookup_table(engine);
    hide_aux(engine);
}

static void disable(IBusEngine *engine) { focus_out(engine); }

// A click on a candidate row: `index` counts rows of the drawn page.
static void candidate_clicked(IBusEngine *engine, guint index, guint button, guint state) {
    (void)button;
    (void)state;
    MisstypeIBusEngine *self = MISSTYPE_IBUS_ENGINE(engine);
    if (!self->session) return;
    misstype_session_pick(self->session, self->page_start + (int)index);
    render(self, FALSE);
}

static void finalize(GObject *object) {
    MisstypeIBusEngine *self = MISSTYPE_IBUS_ENGINE(object);
    if (self->session) misstype_session_free(self->session);
    g_free(self->last_sig);
    G_OBJECT_CLASS(misstype_ibus_engine_parent_class)->finalize(object);
}

static void misstype_ibus_engine_class_init(MisstypeIBusEngineClass *klass) {
    G_OBJECT_CLASS(klass)->finalize = finalize;
    IBusEngineClass *engine_class = IBUS_ENGINE_CLASS(klass);
    engine_class->process_key_event = process_key_event;
    engine_class->focus_in = focus_in;
    engine_class->focus_out = focus_out;
    engine_class->reset = reset;
    engine_class->disable = disable;
    engine_class->candidate_clicked = candidate_clicked;
}

static void misstype_ibus_engine_init(MisstypeIBusEngine *self) {
    self->session = g_core ? misstype_session_new(g_core) : NULL;
}

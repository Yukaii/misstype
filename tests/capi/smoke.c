#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <misstype.h>

#define ASSERT(cond, msg) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, msg); exit(1); } } while (0)

void test_keymap() {
    const char *label = NULL;
    misstype_key_kind k;
    
    k = misstype_key_from_evdev(31, &label);
    ASSERT(k == MISSTYPE_KEY_CHARACTER && label && strcmp(label, "s") == 0, "evdev31=s");
    
    k = misstype_key_from_evdev(57, &label);
    ASSERT(k == MISSTYPE_KEY_SPACE && label == NULL, "evdev57=space");
    
    k = misstype_key_from_evdev(42, &label);
    ASSERT(k == MISSTYPE_KEY_SHIFT_LEFT && label == NULL, "evdev42=shift-left");
    
    k = misstype_key_from_character("A", &label, NULL);
    ASSERT(k == MISSTYPE_KEY_CHARACTER && label && strcmp(label, "a") == 0, "A=a+shift");
    
    int32_t shifted = 0;
    k = misstype_key_from_character("!", &label, &shifted);
    ASSERT(k == MISSTYPE_KEY_CHARACTER && label && strcmp(label, "1") == 0 && shifted == 1, "! shift");
    
    k = misstype_key_from_character("~", &label, &shifted);
    ASSERT(k == MISSTYPE_KEY_CHARACTER && label && strcmp(label, "`") == 0 && shifted == 1, "~ shift");
    
    k = misstype_key_from_character(";", &label, &shifted);
    ASSERT(k == MISSTYPE_KEY_CHARACTER && label && strcmp(label, ";") == 0 && shifted == 0, "; no shift");
    
    k = misstype_key_from_character("中", &label, &shifted);
    ASSERT(k == MISSTYPE_KEY_OTHER, "中=other");
    
    printf("keymap evdev31=s evdev57=space evdev42=shift-left A=a+shift !=1+shift\n");
}

void run_c1(const char *res) {
    misstype_engine *eng = misstype_engine_new(res, "");
    ASSERT(eng, "engine C1");
    misstype_session *s = misstype_session_new(eng);
    ASSERT(s, "session C1");
    
    // s u 3 c l 3
    const char *keys[] = {"s", "u", "3", "c", "l", "3"};
    for (size_t i = 0; i < 6; i++) {
        misstype_key_event ev = {0};
        ev.kind = MISSTYPE_KEY_CHARACTER;
        ev.label = keys[i];
        ev.text = keys[i];
        ev.modifiers = 0;
        ev.is_release = 0;
        ev.native_code = -1;
        ev.timestamp = -1;
        misstype_key_result r = misstype_session_handle(s, &ev);
        ASSERT(r.consumed == 1 && r.commit == NULL, "C1 key consumed");
        misstype_string_free(r.commit);
    }
    
    misstype_view *v = misstype_session_view(s);
    ASSERT(v, "view C1");
    ASSERT(strcmp(v->preedit, "你好") == 0, "C1 preedit");
    ASSERT(v->caret_bytes == 6, "C1 caret_bytes");
    ASSERT(v->caret_utf16 == 2, "C1 caret_utf16");
    ASSERT(v->shows_candidates == 1, "C1 shows");
    ASSERT(v->candidate_count == 10, "C1 count"); // 4 single + 4 single + 1 phrase + 1 fallback
    
    printf("C1 preedit=你好 caret_bytes=6 caret_utf16=2 shows=1 count=10\n");
    
    // Enter
    misstype_key_event ev = {0};
    ev.kind = MISSTYPE_KEY_ENTER;
    ev.text = "\r";
    ev.modifiers = 0;
    ev.is_release = 0;
    ev.native_code = -1;
    ev.timestamp = -1;
    misstype_key_result r = misstype_session_handle(s, &ev);
    ASSERT(r.consumed == 1 && r.commit && strcmp(r.commit, "你好") == 0, "C1 commit");
    printf("C1 commit=[你好]\n");
    misstype_string_free(r.commit);
    
    misstype_view_free(v);
    misstype_session_free(s);
    misstype_engine_free(eng);
}

static misstype_key_result send(misstype_session *s, misstype_key_kind kind, const char *label, uint32_t mods) {
    misstype_key_event ev = {0};
    ev.kind = kind;
    ev.label = label;
    ev.text = label ? label : (kind == MISSTYPE_KEY_ENTER ? "\r" : NULL);
    ev.modifiers = mods;
    ev.native_code = -1;
    ev.timestamp = -1;
    return misstype_session_handle(s, &ev);
}

void run_c13(const char *res) {
    misstype_engine *eng = misstype_engine_new(res, "");
    misstype_engine_set_user_dictionary_path(eng, ""); /* memory only */
    misstype_session *s = misstype_session_new(eng);
    const char *keys[] = {"s", "u", "3", "c", "l", "3"};
    for (size_t i = 0; i < 6; i++) misstype_string_free(send(s, MISSTYPE_KEY_CHARACTER, keys[i], 0).commit);

    misstype_view *v = misstype_session_view(s);
    ASSERT(v->mark_action == MISSTYPE_MARK_NONE && v->mark_start_bytes == -1 && v->mark_start_utf16 == -1, "C13 no mark yet");
    misstype_view_free(v);

    for (int i = 0; i < 2; i++) {
        misstype_key_result r = send(s, MISSTYPE_KEY_LEFT, NULL, MISSTYPE_MOD_SHIFT);
        ASSERT(r.consumed == 1 && r.commit == NULL && r.beep == 0, "C13 shift-left");
    }
    v = misstype_session_view(s);
    ASSERT(v->mark_action == MISSTYPE_MARK_ADD, "C13 action add");
    ASSERT(v->mark_start_utf16 == 0 && v->mark_end_utf16 == 2, "C13 utf16 range");
    ASSERT(v->mark_start_bytes == 0 && v->mark_end_bytes == 6, "C13 byte range");
    ASSERT(strcmp(v->mark_text, "你好") == 0 && strcmp(v->mark_reading, "ㄋㄧˇ-ㄏㄠˇ") == 0, "C13 text+reading");
    ASSERT(v->candidate_count == 0 && v->shows_candidates == 1, "C13 hint only");
    printf("C13 mark add range=0..6 text=你好 reading=ㄋㄧˇ-ㄏㄠˇ\n");
    misstype_view_free(v);

    misstype_key_result r = send(s, MISSTYPE_KEY_ENTER, NULL, 0);
    ASSERT(r.consumed == 1 && r.commit == NULL, "C13 enter files, no commit");
    v = misstype_session_view(s);
    ASSERT(v->mark_action == MISSTYPE_MARK_NONE && strcmp(v->preedit, "你好") == 0, "C13 mark cleared");
    misstype_view_free(v);

    /* The same mark now offers removal. */
    for (int i = 0; i < 2; i++) misstype_string_free(send(s, MISSTYPE_KEY_LEFT, NULL, MISSTYPE_MOD_SHIFT).commit);
    v = misstype_session_view(s);
    ASSERT(v->mark_action == MISSTYPE_MARK_REMOVE, "C13 action remove");
    printf("C13 filed then mark remove\n");
    misstype_view_free(v);

    misstype_session_free(s);
    misstype_engine_free(eng);
}

void run_c2(const char *res) {
    misstype_engine *eng = misstype_engine_new(res, "");
    misstype_session *s = misstype_session_new(eng);
    
    // empty: Enter
    misstype_key_event ev = {0};
    ev.kind = MISSTYPE_KEY_ENTER;
    ev.text = "\r";
    ev.modifiers = 0;
    ev.is_release = 0;
    ev.native_code = -1;
    ev.timestamp = -1;
    misstype_key_result r = misstype_session_handle(s, &ev);
    ASSERT(r.consumed == 0 && r.commit == NULL, "C2 enter pass");
    printf("C2 enter consumed=0 commit=(null)\n");
    misstype_string_free(r.commit);
    
    // Backspace
    ev.kind = MISSTYPE_KEY_BACKSPACE;
    ev.text = "\x7f";
    r = misstype_session_handle(s, &ev);
    ASSERT(r.consumed == 0 && r.commit == NULL, "C2 backspace pass");
    misstype_string_free(r.commit);
    
    // Left
    ev.kind = MISSTYPE_KEY_LEFT;
    ev.text = "\xF7\x02";
    r = misstype_session_handle(s, &ev);
    ASSERT(r.consumed == 0 && r.commit == NULL, "C2 left pass");
    misstype_string_free(r.commit);
    
    // Space
    ev.kind = MISSTYPE_KEY_SPACE;
    ev.text = " ";
    ev.modifiers = 0;
    r = misstype_session_handle(s, &ev);
    ASSERT(r.consumed == 1 && r.commit && strcmp(r.commit, " ") == 0, "C2 space commit");
    printf("C2 space consumed=1 commit=[ ]\n");
    misstype_string_free(r.commit);
    
    misstype_session_free(s);
    misstype_engine_free(eng);
}

void run_c4(const char *res) {
    misstype_engine *eng = misstype_engine_new(res, "");
    misstype_session *s = misstype_session_new(eng);
    
    // s u 3
    const char *keys[] = {"s", "u", "3"};
    for (size_t i = 0; i < 3; i++) {
        misstype_key_event ev = {0};
        ev.kind = MISSTYPE_KEY_CHARACTER;
        ev.label = keys[i];
        ev.text = keys[i];
        ev.modifiers = 0;
        ev.is_release = 0;
        ev.native_code = -1;
        ev.timestamp = -1;
        misstype_session_handle(s, &ev);
    }
    
    // Tab
    misstype_key_event ev = {0};
    ev.kind = MISSTYPE_KEY_TAB;
    ev.text = "\t";
    ev.modifiers = 0;
    ev.is_release = 0;
    ev.native_code = -1;
    ev.timestamp = -1;
    misstype_session_handle(s, &ev);
    
    misstype_view *v = misstype_session_view(s);
    ASSERT(v->shows_candidates == 1 && v->selected == 0 && v->keys_active == 1 && v->candidate_count == 5, "C4 tab");
    printf("C4 tab selected=0 keys_active=1 shows=1 count=5\n");
    misstype_view_free(v);
    
    // d (selection key for row 2)
    ev.kind = MISSTYPE_KEY_CHARACTER;
    ev.label = "d";
    ev.text = "d";
    ev.modifiers = 0;
    ev.is_release = 0;
    ev.native_code = -1;
    ev.timestamp = -1;
    misstype_session_handle(s, &ev);
    
    v = misstype_session_view(s);
    ASSERT(strcmp(v->preedit, "尼") == 0 && v->keys_active == 0, "C4 pick");
    printf("C4 pick preedit=尼 keys_active=0\n");
    misstype_view_free(v);
    
    // Enter
    ev.kind = MISSTYPE_KEY_ENTER;
    ev.text = "\r";
    misstype_key_result r = misstype_session_handle(s, &ev);
    ASSERT(r.consumed == 1 && r.commit && strcmp(r.commit, "尼") == 0, "C4 commit");
    printf("C4 commit=[尼]\n");
    misstype_string_free(r.commit);
    
    misstype_session_free(s);
    misstype_engine_free(eng);
}

void run_c8(const char *res) {
    misstype_engine *eng = misstype_engine_new(res, "");
    misstype_session *s = misstype_session_new(eng);
    
    // s u 3 c l 3
    const char *keys[] = {"s", "u", "3", "c", "l", "3"};
    for (size_t i = 0; i < 6; i++) {
        misstype_key_event ev = {0};
        ev.kind = MISSTYPE_KEY_CHARACTER;
        ev.label = keys[i];
        ev.text = keys[i];
        ev.modifiers = 0;
        ev.is_release = 0;
        ev.native_code = -1;
        ev.timestamp = -1;
        misstype_session_handle(s, &ev);
    }
    
    // Right (beep)
    misstype_key_event ev = {0};
    ev.kind = MISSTYPE_KEY_RIGHT;
    ev.text = "\xF7\x03";
    ev.modifiers = 0;
    ev.is_release = 0;
    ev.native_code = -1;
    ev.timestamp = -1;
    misstype_key_result r = misstype_session_handle(s, &ev);
    ASSERT(r.consumed == 1 && r.beep == 1, "C8 right beep");
    misstype_string_free(r.commit);
    
    // Left (cursor mode)
    ev.kind = MISSTYPE_KEY_LEFT;
    ev.text = "\xF7\x02";
    r = misstype_session_handle(s, &ev);
    ASSERT(r.consumed == 1, "C8 left");
    misstype_string_free(r.commit);
    
    misstype_view *v = misstype_session_view(s);
    // The cursor types where it stands (issue #32): Tab arms the keys.
    ASSERT(v->caret_bytes == 3 && v->caret_utf16 == 1 && v->keys_active == 0, "C8 cursor");
    ASSERT(v->candidates && strcmp(v->candidates[0], "你好") == 0, "C8 first candidate");
    misstype_view_free(v);
    ev.kind = MISSTYPE_KEY_TAB;
    ev.text = "\t";
    r = misstype_session_handle(s, &ev);
    ASSERT(r.consumed == 1, "C8 tab");
    misstype_string_free(r.commit);
    v = misstype_session_view(s);
    ASSERT(v->keys_active == 1, "C8 tab arms");
    printf("C8 left caret_bytes=3 caret_utf16=1 first=你好 keys_active=0, tab=1\n");
    misstype_view_free(v);
    
    misstype_session_free(s);
    misstype_engine_free(eng);
}

void run_c9(const char *res) {
    misstype_engine *eng = misstype_engine_new(res, "");
    misstype_session *s = misstype_session_new(eng);
    
    // s u 3
    const char *keys[] = {"s", "u", "3"};
    for (size_t i = 0; i < 3; i++) {
        misstype_key_event ev = {0};
        ev.kind = MISSTYPE_KEY_CHARACTER;
        ev.label = keys[i];
        ev.text = keys[i];
        ev.modifiers = 0;
        ev.is_release = 0;
        ev.native_code = -1;
        ev.timestamp = -1;
        misstype_session_handle(s, &ev);
    }
    
    // Ctrl+C
    misstype_key_event ev = {0};
    ev.kind = MISSTYPE_KEY_CHARACTER;
    ev.label = "c";
    ev.text = "c";
    ev.modifiers = MISSTYPE_MOD_CONTROL;
    ev.is_release = 0;
    ev.native_code = -1;
    ev.timestamp = -1;
    misstype_key_result r = misstype_session_handle(s, &ev);
    ASSERT(r.consumed == 0 && r.commit && strcmp(r.commit, "你") == 0, "C9 ctrl-c");
    printf("C9 ctrl-c consumed=0 commit=[你]\n");
    misstype_string_free(r.commit);
    
    misstype_session_free(s);
    misstype_engine_free(eng);
}

void run_c10(const char *res) {
    misstype_engine *eng = misstype_engine_new(res, "");
    misstype_session *s = misstype_session_new(eng);
    
    // s u 3
    const char *keys[] = {"s", "u", "3"};
    for (size_t i = 0; i < 3; i++) {
        misstype_key_event ev = {0};
        ev.kind = MISSTYPE_KEY_CHARACTER;
        ev.label = keys[i];
        ev.text = keys[i];
        ev.modifiers = 0;
        ev.is_release = 0;
        ev.native_code = -1;
        ev.timestamp = -1;
        misstype_session_handle(s, &ev);
    }
    
    // Shift+Space
    misstype_key_event ev = {0};
    ev.kind = MISSTYPE_KEY_SPACE;
    ev.text = " ";
    ev.modifiers = MISSTYPE_MOD_SHIFT;
    ev.is_release = 0;
    ev.native_code = -1;
    ev.timestamp = -1;
    misstype_key_result r = misstype_session_handle(s, &ev);
    ASSERT(r.consumed == 1 && r.commit && strcmp(r.commit, "你") == 0 && r.mode_changed == 1, "C10 shift-space");
    printf("C10 shift-space consumed=1 commit=[你] mode_changed=1 english=1\n");
    misstype_string_free(r.commit);
    
    int32_t eng_mode = misstype_engine_is_english(eng);
    ASSERT(eng_mode == 1, "C10 english mode");
    
    // s
    ev.kind = MISSTYPE_KEY_CHARACTER;
    ev.label = "s";
    ev.text = "s";
    ev.modifiers = 0;
    ev.is_release = 0;
    ev.native_code = -1;
    ev.timestamp = -1;
    r = misstype_session_handle(s, &ev);
    ASSERT(r.consumed == 0 && r.commit == NULL, "C10 s pass");
    printf("C10 s consumed=0 commit=(null)\n");
    misstype_string_free(r.commit);
    
    misstype_session_free(s);
    misstype_engine_free(eng);
}

void run_c11(const char *res) {
    misstype_engine *eng = misstype_engine_new(res, "");
    misstype_session *s = misstype_session_new(eng);
    
    // s u 3
    const char *keys[] = {"s", "u", "3"};
    for (size_t i = 0; i < 3; i++) {
        misstype_key_event ev = {0};
        ev.kind = MISSTYPE_KEY_CHARACTER;
        ev.label = keys[i];
        ev.text = keys[i];
        ev.modifiers = 0;
        ev.is_release = 0;
        ev.native_code = -1;
        ev.timestamp = -1;
        misstype_session_handle(s, &ev);
    }
    
    // focus out -> commit
    char *commit = misstype_session_commit(s);
    ASSERT(commit && strcmp(commit, "你") == 0, "C11 commit");
    printf("C11 commit=[你]\n");
    misstype_string_free(commit);
    
    misstype_session_free(s);
    misstype_engine_free(eng);
}

void run_c12(const char *res) {
    misstype_engine *eng = misstype_engine_new(res, "");
    misstype_session *s = misstype_session_new(eng);
    
    // s u 3
    const char *keys[] = {"s", "u", "3"};
    for (size_t i = 0; i < 3; i++) {
        misstype_key_event ev = {0};
        ev.kind = MISSTYPE_KEY_CHARACTER;
        ev.label = keys[i];
        ev.text = keys[i];
        ev.modifiers = 0;
        ev.is_release = 0;
        ev.native_code = -1;
        ev.timestamp = -1;
        misstype_session_handle(s, &ev);
    }
    
    // pick row 3 (index 3)
    misstype_session_pick(s, 3);
    
    misstype_view *v = misstype_session_view(s);
    ASSERT(strcmp(v->preedit, "泥") == 0 && v->selected == 3, "C12 pick");
    printf("C12 pick preedit=泥 selected=3\n");
    misstype_view_free(v);
    
    misstype_session_free(s);
    misstype_engine_free(eng);
}

static misstype_key_result shift_tap(misstype_session *s, misstype_key_kind kind, int release, double t) {
    misstype_key_event ev = {0};
    ev.kind = kind;
    ev.modifiers = release ? 0 : MISSTYPE_MOD_SHIFT;
    ev.is_release = release;
    ev.native_code = -1;
    ev.timestamp = t;
    return misstype_session_handle(s, &ev);
}

/* misstype_engine_set_settings must reach live sessions: with shift_toggle=0
 * (fcitx5 owns lone Shift) a Shift tap no longer flips 中/英. */
void run_settings(const char *res) {
    misstype_engine *eng = misstype_engine_new(res, "");
    ASSERT(eng, "engine settings");
    misstype_session *s = misstype_session_new(eng);
    shift_tap(s, MISSTYPE_KEY_SHIFT_LEFT, 0, 100.0);
    misstype_key_result r = shift_tap(s, MISSTYPE_KEY_SHIFT_LEFT, 1, 100.1);
    ASSERT(r.mode_changed == 1 && misstype_engine_is_english(eng) == 1, "default settings: Shift tap toggles");
    misstype_settings st = misstype_settings_default();
    st.shift_toggle = 0;
    misstype_engine_set_settings(eng, &st);
    shift_tap(s, MISSTYPE_KEY_SHIFT_LEFT, 0, 101.0);
    r = shift_tap(s, MISSTYPE_KEY_SHIFT_LEFT, 1, 101.1);
    ASSERT(r.mode_changed == 0 && misstype_engine_is_english(eng) == 1, "shift_toggle=0: Shift tap ignored");
    printf("settings shift_toggle=0 tap ignored\n");
    misstype_session_free(s);
    misstype_engine_free(eng);
}

/* Personal channel model: a one-key Backspace re-type (typed ㄩ, meant ㄧ)
 * is learned only when enabled, survives set_settings, and clears. */
static void retype_ni(misstype_session *s) {
    misstype_string_free(send(s, MISSTYPE_KEY_CHARACTER, "s", 0).commit);
    misstype_string_free(send(s, MISSTYPE_KEY_CHARACTER, "m", 0).commit);
    misstype_string_free(send(s, MISSTYPE_KEY_BACKSPACE, NULL, 0).commit);
    misstype_string_free(send(s, MISSTYPE_KEY_CHARACTER, "u", 0).commit);
    misstype_string_free(send(s, MISSTYPE_KEY_CHARACTER, "3", 0).commit);
    misstype_key_result r = send(s, MISSTYPE_KEY_ENTER, NULL, 0);
    ASSERT(r.commit && strcmp(r.commit, "你") == 0, "channel commit 你");
    misstype_string_free(r.commit);
}

void run_channel(const char *res) {
    misstype_engine *eng = misstype_engine_new(res, "");
    misstype_engine_set_channel_path(eng, ""); /* memory only */
    misstype_session *s = misstype_session_new(eng);
    retype_ni(s);
    ASSERT(misstype_engine_channel_pair_count(eng) == 0, "channel off by default");
    misstype_engine_set_channel_learning(eng, 1);
    misstype_settings st = misstype_settings_default();
    misstype_engine_set_settings(eng, &st); /* keeps the channel flag */
    retype_ni(s);
    int32_t learned = misstype_engine_channel_pair_count(eng);
    ASSERT(learned == 1, "channel learns the re-type");
    misstype_engine_clear_channel(eng);
    ASSERT(misstype_engine_channel_pair_count(eng) == 0, "channel cleared");
    printf("channel off=0 learned=%d cleared=0\n", learned);
    misstype_session_free(s);
    misstype_engine_free(eng);
}

/* Repair strength: off leaves bare ㄋˇ unrepaired, light still rescues it
 * (no clean reading, so any level competes); out-of-range levels are
 * ignored. */
static char *type_s3(misstype_session *s) {
    misstype_string_free(send(s, MISSTYPE_KEY_CHARACTER, "s", 0).commit);
    misstype_string_free(send(s, MISSTYPE_KEY_CHARACTER, "3", 0).commit);
    return send(s, MISSTYPE_KEY_ENTER, NULL, 0).commit;
}

void run_repair_strength(const char *res) {
    misstype_engine *eng = misstype_engine_new(res, "");
    misstype_session *s = misstype_session_new(eng);
    misstype_engine_set_repair_strength(eng, 0);
    char *off = type_s3(s);
    ASSERT(!off || strcmp(off, "你") != 0, "repair off: s3 stays raw");
    misstype_engine_set_repair_strength(eng, 1);
    misstype_settings st = misstype_settings_default();
    misstype_engine_set_settings(eng, &st);
    misstype_engine_set_repair_strength(eng, 9); /* ignored */
    char *light = type_s3(s);
    ASSERT(light && strcmp(light, "你") == 0, "repair light: s3 -> 你");
    printf("repair_strength off=%s light=%s\n", off ? off : "(null)", light);
    misstype_string_free(off);
    misstype_string_free(light);
    misstype_session_free(s);
    misstype_engine_free(eng);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <resource_dir> [keys]\n", argv[0]);
        return 1;
    }
    const char *res = argv[1];
    
    if (argc == 2) {
        // Run all conformance scenarios
        printf("abi=%d\n", misstype_abi_version());
        run_c1(res);
        run_c2(res);
        run_c4(res);
        run_c8(res);
        run_c9(res);
        run_c10(res);
        run_c11(res);
        run_c12(res);
        run_c13(res);
        run_settings(res);
        run_channel(res);
        run_repair_strength(res);
        test_keymap();
        printf("DONE\n");
        return 0;
    }
    
    // Single key sequence mode for L4
    const char *keys = argv[2];
    misstype_engine *eng = misstype_engine_new(res, "");
    misstype_session *s = misstype_session_new(eng);
    
    for (size_t i = 0; i < strlen(keys); i++) {
        char key[2] = {keys[i], 0};
        misstype_key_event ev = {0};
        ev.kind = MISSTYPE_KEY_CHARACTER;
        ev.label = key;
        ev.text = key;
        ev.modifiers = 0;
        ev.is_release = 0;
        ev.native_code = -1;
        ev.timestamp = -1;
        misstype_session_handle(s, &ev);
    }
    
    // Press Enter
    misstype_key_event ev = {0};
    ev.kind = MISSTYPE_KEY_ENTER;
    ev.text = "\r";
    ev.modifiers = 0;
    ev.is_release = 0;
    ev.native_code = -1;
    ev.timestamp = -1;
    misstype_key_result r = misstype_session_handle(s, &ev);
    
    if (r.commit) {
        printf("commit=%s\n", r.commit);
        misstype_string_free(r.commit);
    } else {
        printf("commit=(null)\n");
    }
    
    misstype_session_free(s);
    misstype_engine_free(eng);
    return 0;
}
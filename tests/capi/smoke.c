#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mistype.h>

#define ASSERT(cond, msg) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, msg); exit(1); } } while (0)

void test_keymap() {
    const char *label = NULL;
    mistype_key_kind k;
    
    k = mistype_key_from_evdev(31, &label);
    ASSERT(k == MISTYPE_KEY_CHARACTER && label && strcmp(label, "s") == 0, "evdev31=s");
    
    k = mistype_key_from_evdev(57, &label);
    ASSERT(k == MISTYPE_KEY_SPACE && label == NULL, "evdev57=space");
    
    k = mistype_key_from_evdev(42, &label);
    ASSERT(k == MISTYPE_KEY_SHIFT_LEFT && label == NULL, "evdev42=shift-left");
    
    k = mistype_key_from_character("A", &label, NULL);
    ASSERT(k == MISTYPE_KEY_CHARACTER && label && strcmp(label, "a") == 0, "A=a+shift");
    
    int32_t shifted = 0;
    k = mistype_key_from_character("!", &label, &shifted);
    ASSERT(k == MISTYPE_KEY_CHARACTER && label && strcmp(label, "1") == 0 && shifted == 1, "! shift");
    
    k = mistype_key_from_character("~", &label, &shifted);
    ASSERT(k == MISTYPE_KEY_CHARACTER && label && strcmp(label, "`") == 0 && shifted == 1, "~ shift");
    
    k = mistype_key_from_character(";", &label, &shifted);
    ASSERT(k == MISTYPE_KEY_CHARACTER && label && strcmp(label, ";") == 0 && shifted == 0, "; no shift");
    
    k = mistype_key_from_character("中", &label, &shifted);
    ASSERT(k == MISTYPE_KEY_OTHER, "中=other");
    
    printf("keymap evdev31=s evdev57=space evdev42=shift-left A=a+shift !=1+shift\n");
}

void run_c1(const char *res) {
    mistype_engine *eng = mistype_engine_new(res, "");
    ASSERT(eng, "engine C1");
    mistype_session *s = mistype_session_new(eng);
    ASSERT(s, "session C1");
    
    // s u 3 c l 3
    const char *keys[] = {"s", "u", "3", "c", "l", "3"};
    for (size_t i = 0; i < 6; i++) {
        mistype_key_event ev = {0};
        ev.kind = MISTYPE_KEY_CHARACTER;
        ev.label = keys[i];
        ev.text = keys[i];
        ev.modifiers = 0;
        ev.is_release = 0;
        ev.native_code = -1;
        ev.timestamp = -1;
        mistype_key_result r = mistype_session_handle(s, &ev);
        ASSERT(r.consumed == 1 && r.commit == NULL, "C1 key consumed");
        mistype_string_free(r.commit);
    }
    
    mistype_view *v = mistype_session_view(s);
    ASSERT(v, "view C1");
    ASSERT(strcmp(v->preedit, "你好") == 0, "C1 preedit");
    ASSERT(v->caret_bytes == 6, "C1 caret_bytes");
    ASSERT(v->caret_utf16 == 2, "C1 caret_utf16");
    ASSERT(v->shows_candidates == 1, "C1 shows");
    ASSERT(v->candidate_count == 10, "C1 count"); // 4 single + 4 single + 1 phrase + 1 fallback
    
    printf("C1 preedit=你好 caret_bytes=6 caret_utf16=2 shows=1 count=10\n");
    
    // Enter
    mistype_key_event ev = {0};
    ev.kind = MISTYPE_KEY_ENTER;
    ev.text = "\r";
    ev.modifiers = 0;
    ev.is_release = 0;
    ev.native_code = -1;
    ev.timestamp = -1;
    mistype_key_result r = mistype_session_handle(s, &ev);
    ASSERT(r.consumed == 1 && r.commit && strcmp(r.commit, "你好") == 0, "C1 commit");
    printf("C1 commit=[你好]\n");
    mistype_string_free(r.commit);
    
    mistype_view_free(v);
    mistype_session_free(s);
    mistype_engine_free(eng);
}

void run_c2(const char *res) {
    mistype_engine *eng = mistype_engine_new(res, "");
    mistype_session *s = mistype_session_new(eng);
    
    // empty: Enter
    mistype_key_event ev = {0};
    ev.kind = MISTYPE_KEY_ENTER;
    ev.text = "\r";
    ev.modifiers = 0;
    ev.is_release = 0;
    ev.native_code = -1;
    ev.timestamp = -1;
    mistype_key_result r = mistype_session_handle(s, &ev);
    ASSERT(r.consumed == 0 && r.commit == NULL, "C2 enter pass");
    printf("C2 enter consumed=0 commit=(null)\n");
    mistype_string_free(r.commit);
    
    // Backspace
    ev.kind = MISTYPE_KEY_BACKSPACE;
    ev.text = "\x7f";
    r = mistype_session_handle(s, &ev);
    ASSERT(r.consumed == 0 && r.commit == NULL, "C2 backspace pass");
    mistype_string_free(r.commit);
    
    // Left
    ev.kind = MISTYPE_KEY_LEFT;
    ev.text = "\xF7\x02";
    r = mistype_session_handle(s, &ev);
    ASSERT(r.consumed == 0 && r.commit == NULL, "C2 left pass");
    mistype_string_free(r.commit);
    
    // Space
    ev.kind = MISTYPE_KEY_SPACE;
    ev.text = " ";
    ev.modifiers = 0;
    r = mistype_session_handle(s, &ev);
    ASSERT(r.consumed == 1 && r.commit && strcmp(r.commit, " ") == 0, "C2 space commit");
    printf("C2 space consumed=1 commit=[ ]\n");
    mistype_string_free(r.commit);
    
    mistype_session_free(s);
    mistype_engine_free(eng);
}

void run_c4(const char *res) {
    mistype_engine *eng = mistype_engine_new(res, "");
    mistype_session *s = mistype_session_new(eng);
    
    // s u 3
    const char *keys[] = {"s", "u", "3"};
    for (size_t i = 0; i < 3; i++) {
        mistype_key_event ev = {0};
        ev.kind = MISTYPE_KEY_CHARACTER;
        ev.label = keys[i];
        ev.text = keys[i];
        ev.modifiers = 0;
        ev.is_release = 0;
        ev.native_code = -1;
        ev.timestamp = -1;
        mistype_session_handle(s, &ev);
    }
    
    // Tab
    mistype_key_event ev = {0};
    ev.kind = MISTYPE_KEY_TAB;
    ev.text = "\t";
    ev.modifiers = 0;
    ev.is_release = 0;
    ev.native_code = -1;
    ev.timestamp = -1;
    mistype_session_handle(s, &ev);
    
    mistype_view *v = mistype_session_view(s);
    ASSERT(v->shows_candidates == 1 && v->selected == 1 && v->keys_active == 1 && v->candidate_count == 5, "C4 tab");
    printf("C4 tab selected=1 keys_active=1 shows=1 count=5\n");
    mistype_view_free(v);
    
    // d (selection key for row 2)
    ev.kind = MISTYPE_KEY_CHARACTER;
    ev.label = "d";
    ev.text = "d";
    ev.modifiers = 0;
    ev.is_release = 0;
    ev.native_code = -1;
    ev.timestamp = -1;
    mistype_session_handle(s, &ev);
    
    v = mistype_session_view(s);
    ASSERT(strcmp(v->preedit, "尼") == 0 && v->keys_active == 0, "C4 pick");
    printf("C4 pick preedit=尼 keys_active=0\n");
    mistype_view_free(v);
    
    // Enter
    ev.kind = MISTYPE_KEY_ENTER;
    ev.text = "\r";
    mistype_key_result r = mistype_session_handle(s, &ev);
    ASSERT(r.consumed == 1 && r.commit && strcmp(r.commit, "尼") == 0, "C4 commit");
    printf("C4 commit=[尼]\n");
    mistype_string_free(r.commit);
    
    mistype_session_free(s);
    mistype_engine_free(eng);
}

void run_c8(const char *res) {
    mistype_engine *eng = mistype_engine_new(res, "");
    mistype_session *s = mistype_session_new(eng);
    
    // s u 3 c l 3
    const char *keys[] = {"s", "u", "3", "c", "l", "3"};
    for (size_t i = 0; i < 6; i++) {
        mistype_key_event ev = {0};
        ev.kind = MISTYPE_KEY_CHARACTER;
        ev.label = keys[i];
        ev.text = keys[i];
        ev.modifiers = 0;
        ev.is_release = 0;
        ev.native_code = -1;
        ev.timestamp = -1;
        mistype_session_handle(s, &ev);
    }
    
    // Right (beep)
    mistype_key_event ev = {0};
    ev.kind = MISTYPE_KEY_RIGHT;
    ev.text = "\xF7\x03";
    ev.modifiers = 0;
    ev.is_release = 0;
    ev.native_code = -1;
    ev.timestamp = -1;
    mistype_key_result r = mistype_session_handle(s, &ev);
    ASSERT(r.consumed == 1 && r.beep == 1, "C8 right beep");
    mistype_string_free(r.commit);
    
    // Left (cursor mode)
    ev.kind = MISTYPE_KEY_LEFT;
    ev.text = "\xF7\x02";
    r = mistype_session_handle(s, &ev);
    ASSERT(r.consumed == 1, "C8 left");
    mistype_string_free(r.commit);
    
    mistype_view *v = mistype_session_view(s);
    ASSERT(v->caret_bytes == 3 && v->caret_utf16 == 1 && v->keys_active == 1, "C8 cursor");
    ASSERT(v->candidates && strcmp(v->candidates[0], "你好") == 0, "C8 first candidate");
    printf("C8 left caret_bytes=3 caret_utf16=1 first=你好 keys_active=1\n");
    mistype_view_free(v);
    
    mistype_session_free(s);
    mistype_engine_free(eng);
}

void run_c9(const char *res) {
    mistype_engine *eng = mistype_engine_new(res, "");
    mistype_session *s = mistype_session_new(eng);
    
    // s u 3
    const char *keys[] = {"s", "u", "3"};
    for (size_t i = 0; i < 3; i++) {
        mistype_key_event ev = {0};
        ev.kind = MISTYPE_KEY_CHARACTER;
        ev.label = keys[i];
        ev.text = keys[i];
        ev.modifiers = 0;
        ev.is_release = 0;
        ev.native_code = -1;
        ev.timestamp = -1;
        mistype_session_handle(s, &ev);
    }
    
    // Ctrl+C
    mistype_key_event ev = {0};
    ev.kind = MISTYPE_KEY_CHARACTER;
    ev.label = "c";
    ev.text = "c";
    ev.modifiers = MISTYPE_MOD_CONTROL;
    ev.is_release = 0;
    ev.native_code = -1;
    ev.timestamp = -1;
    mistype_key_result r = mistype_session_handle(s, &ev);
    ASSERT(r.consumed == 0 && r.commit && strcmp(r.commit, "你") == 0, "C9 ctrl-c");
    printf("C9 ctrl-c consumed=0 commit=[你]\n");
    mistype_string_free(r.commit);
    
    mistype_session_free(s);
    mistype_engine_free(eng);
}

void run_c10(const char *res) {
    mistype_engine *eng = mistype_engine_new(res, "");
    mistype_session *s = mistype_session_new(eng);
    
    // s u 3
    const char *keys[] = {"s", "u", "3"};
    for (size_t i = 0; i < 3; i++) {
        mistype_key_event ev = {0};
        ev.kind = MISTYPE_KEY_CHARACTER;
        ev.label = keys[i];
        ev.text = keys[i];
        ev.modifiers = 0;
        ev.is_release = 0;
        ev.native_code = -1;
        ev.timestamp = -1;
        mistype_session_handle(s, &ev);
    }
    
    // Shift+Space
    mistype_key_event ev = {0};
    ev.kind = MISTYPE_KEY_SPACE;
    ev.text = " ";
    ev.modifiers = MISTYPE_MOD_SHIFT;
    ev.is_release = 0;
    ev.native_code = -1;
    ev.timestamp = -1;
    mistype_key_result r = mistype_session_handle(s, &ev);
    ASSERT(r.consumed == 1 && r.commit && strcmp(r.commit, "你") == 0 && r.mode_changed == 1, "C10 shift-space");
    printf("C10 shift-space consumed=1 commit=[你] mode_changed=1 english=1\n");
    mistype_string_free(r.commit);
    
    int32_t eng_mode = mistype_engine_is_english(eng);
    ASSERT(eng_mode == 1, "C10 english mode");
    
    // s
    ev.kind = MISTYPE_KEY_CHARACTER;
    ev.label = "s";
    ev.text = "s";
    ev.modifiers = 0;
    ev.is_release = 0;
    ev.native_code = -1;
    ev.timestamp = -1;
    r = mistype_session_handle(s, &ev);
    ASSERT(r.consumed == 0 && r.commit == NULL, "C10 s pass");
    printf("C10 s consumed=0 commit=(null)\n");
    mistype_string_free(r.commit);
    
    mistype_session_free(s);
    mistype_engine_free(eng);
}

void run_c11(const char *res) {
    mistype_engine *eng = mistype_engine_new(res, "");
    mistype_session *s = mistype_session_new(eng);
    
    // s u 3
    const char *keys[] = {"s", "u", "3"};
    for (size_t i = 0; i < 3; i++) {
        mistype_key_event ev = {0};
        ev.kind = MISTYPE_KEY_CHARACTER;
        ev.label = keys[i];
        ev.text = keys[i];
        ev.modifiers = 0;
        ev.is_release = 0;
        ev.native_code = -1;
        ev.timestamp = -1;
        mistype_session_handle(s, &ev);
    }
    
    // focus out -> commit
    char *commit = mistype_session_commit(s);
    ASSERT(commit && strcmp(commit, "你") == 0, "C11 commit");
    printf("C11 commit=[你]\n");
    mistype_string_free(commit);
    
    mistype_session_free(s);
    mistype_engine_free(eng);
}

void run_c12(const char *res) {
    mistype_engine *eng = mistype_engine_new(res, "");
    mistype_session *s = mistype_session_new(eng);
    
    // s u 3
    const char *keys[] = {"s", "u", "3"};
    for (size_t i = 0; i < 3; i++) {
        mistype_key_event ev = {0};
        ev.kind = MISTYPE_KEY_CHARACTER;
        ev.label = keys[i];
        ev.text = keys[i];
        ev.modifiers = 0;
        ev.is_release = 0;
        ev.native_code = -1;
        ev.timestamp = -1;
        mistype_session_handle(s, &ev);
    }
    
    // pick row 3 (index 3)
    mistype_session_pick(s, 3);
    
    mistype_view *v = mistype_session_view(s);
    ASSERT(strcmp(v->preedit, "泥") == 0 && v->selected == 3, "C12 pick");
    printf("C12 pick preedit=泥 selected=3\n");
    mistype_view_free(v);
    
    mistype_session_free(s);
    mistype_engine_free(eng);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <resource_dir> [keys]\n", argv[0]);
        return 1;
    }
    const char *res = argv[1];
    
    if (argc == 2) {
        // Run all conformance scenarios
        printf("abi=%d\n", mistype_abi_version());
        run_c1(res);
        run_c2(res);
        run_c4(res);
        run_c8(res);
        run_c9(res);
        run_c10(res);
        run_c11(res);
        run_c12(res);
        test_keymap();
        printf("DONE\n");
        return 0;
    }
    
    // Single key sequence mode for L4
    const char *keys = argv[2];
    mistype_engine *eng = mistype_engine_new(res, "");
    mistype_session *s = mistype_session_new(eng);
    
    for (size_t i = 0; i < strlen(keys); i++) {
        char key[2] = {keys[i], 0};
        mistype_key_event ev = {0};
        ev.kind = MISTYPE_KEY_CHARACTER;
        ev.label = key;
        ev.text = key;
        ev.modifiers = 0;
        ev.is_release = 0;
        ev.native_code = -1;
        ev.timestamp = -1;
        mistype_session_handle(s, &ev);
    }
    
    // Press Enter
    mistype_key_event ev = {0};
    ev.kind = MISTYPE_KEY_ENTER;
    ev.text = "\r";
    ev.modifiers = 0;
    ev.is_release = 0;
    ev.native_code = -1;
    ev.timestamp = -1;
    mistype_key_result r = mistype_session_handle(s, &ev);
    
    if (r.commit) {
        printf("commit=%s\n", r.commit);
        mistype_string_free(r.commit);
    } else {
        printf("commit=(null)\n");
    }
    
    mistype_session_free(s);
    mistype_engine_free(eng);
    return 0;
}
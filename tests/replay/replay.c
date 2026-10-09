/* replay: drive any misstype.h implementation from a key script and print
 * every key result and view, so the transcript can be diffed line for line
 * against the frozen Swift reference (tests/golden/replay_*.txt.gz).
 *
 *   replay <shipping resource dir> <fixture resource dir> <script>...
 *
 * Script lines (one action each, # comments):
 *   @engine shipping|fixture       new engine (memory-only user data)
 *   @set key=value ...             settings (fuzzy tone learn shift keys
 *                                  autoshow confirm mixed autocommit page
 *                                  cursor repair channel)
 *   @case name                     new session, header line
 *   k tok ...                      keys: a 3 ; space enter tab bs del esc
 *                                  left right up down pgup pgdn other mod
 *                                  modifier prefixes S- C- A- M- K-
 *                                  (shift ctrl alt super caps); stap/rtap
 *                                  = lone left/right Shift tap
 *   t text                         type UTF-8 text on a US layout
 *   pick N | commit | reset        host calls
 *
 * Timestamps come from a virtual clock (50 ms per event), so Shift-tap
 * timing is deterministic. MISSTYPE_REPLAY_WAIT=<seconds> sleeps after
 * creating an engine (Swift loads english.tsv in the background).
 */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <misstype.h>

static misstype_engine *engine;
static misstype_session *session;
static misstype_settings settings;
static double clock_now = 1000.0;
static const char *dirs[2];
static char keys_buf[64];
static long long handle_ns, max_handle_ns;
static unsigned long handle_count;

static void print_json_string(const char *s) {
    putchar('"');
    for (const unsigned char *p = (const unsigned char *)s; p && *p; p++) {
        if (*p == '"' || *p == '\\') printf("\\%c", *p);
        else if (*p == '\n') printf("\\n");
        else if (*p == '\r') printf("\\r");
        else if (*p == '\t') printf("\\t");
        else if (*p < 0x20) printf("\\u%04x", *p);
        else putchar(*p);
    }
    putchar('"');
}

static void print_state(void) {
    misstype_view *v = misstype_session_view(session);
    printf("  pre=");
    print_json_string(v->preedit);
    printf(" caret=%d/%d sel=%d n=%d show=%d act=%d", v->caret_bytes, v->caret_utf16, v->selected,
           v->candidate_count, v->shows_candidates, v->keys_active);
    printf(" keys=");
    for (int i = 0; i < v->selection_key_count; i++) printf("%s", v->selection_keys[i]);
    if (v->mark_action != MISSTYPE_MARK_NONE) {
        printf(" mark=%d %d-%d/%d-%d ", v->mark_action, v->mark_start_bytes, v->mark_end_bytes,
               v->mark_start_utf16, v->mark_end_utf16);
        print_json_string(v->mark_text);
        putchar(' ');
        print_json_string(v->mark_reading);
    }
    char *raw = misstype_session_raw_phonetic(session);
    printf(" raw=");
    print_json_string(raw);
    misstype_string_free(raw);
    printf(" latin=%d en=%d\n", misstype_session_latin_active(session), misstype_engine_is_english(engine));
    if (v->candidate_count > 0) {
        printf("  cands=[");
        for (int i = 0; i < v->candidate_count; i++) {
            if (i) putchar(',');
            print_json_string(v->candidates[i]);
        }
        printf("]\n");
    }
    misstype_view_free(v);
}

static void print_result(misstype_key_result r) {
    printf("  -> consumed=%d beep=%d mode=%d commit=", r.consumed, r.beep, r.mode_changed);
    if (r.commit) print_json_string(r.commit); else printf("null");
    putchar('\n');
    misstype_string_free(r.commit);
}

static void send(misstype_key_event ev) {
    ev.timestamp = clock_now;
    clock_now += 0.05;
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    misstype_key_result result = misstype_session_handle(session, &ev);
    clock_gettime(CLOCK_MONOTONIC, &end);
    long long elapsed = (end.tv_sec - start.tv_sec) * 1000000000LL + end.tv_nsec - start.tv_nsec;
    handle_ns += elapsed;
    if (elapsed > max_handle_ns) max_handle_ns = elapsed;
    handle_count++;
    print_result(result);
    print_state();
}

static void new_session(void) {
    if (session) misstype_session_free(session);
    session = misstype_session_new(engine);
}

static void new_engine(const char *which) {
    if (session) { misstype_session_free(session); session = NULL; }
    if (engine) misstype_engine_free(engine);
    engine = misstype_engine_new(strcmp(which, "fixture") == 0 ? dirs[1] : dirs[0], "");
    if (!engine) { fprintf(stderr, "replay: no engine for %s\n", which); exit(2); }
    const char *wait = getenv("MISSTYPE_REPLAY_WAIT");
    if (wait) {
        double s = atof(wait);
        struct timespec ts = { (time_t)s, (long)((s - (time_t)s) * 1e9) };
        nanosleep(&ts, NULL);
    }
    settings = misstype_settings_default();
    misstype_engine_set_settings(engine, &settings);
    new_session();
}

static void set_option(const char *key, const char *value) {
    int n = atoi(value);
    if (!strcmp(key, "fuzzy")) settings.fuzzy_repair = n;
    else if (!strcmp(key, "tone")) settings.tone_tolerance = n;
    else if (!strcmp(key, "learn")) settings.user_learning = n;
    else if (!strcmp(key, "shift")) settings.shift_toggle = n;
    else if (!strcmp(key, "keys")) { snprintf(keys_buf, sizeof keys_buf, "%s", value); settings.candidate_keys = keys_buf; }
    else if (!strcmp(key, "autoshow")) settings.auto_show_candidates = n;
    else if (!strcmp(key, "confirm")) settings.return_confirms_selection = n;
    else if (!strcmp(key, "mixed")) settings.mixed_english = n;
    else if (!strcmp(key, "autocommit")) settings.auto_commit_syllables = n;
    else if (!strcmp(key, "page")) settings.page_size = n;
    else if (!strcmp(key, "cursor")) settings.cursor_candidates = n;
    else if (!strcmp(key, "repair")) { misstype_engine_set_repair_strength(engine, n); return; }
    else if (!strcmp(key, "channel")) { misstype_engine_set_channel_learning(engine, n); return; }
    else { fprintf(stderr, "replay: unknown setting %s\n", key); exit(2); }
    misstype_engine_set_settings(engine, &settings);
}

static const struct { const char *name; misstype_key_kind kind; const char *text; } named[] = {
    {"space", MISSTYPE_KEY_SPACE, " "}, {"enter", MISSTYPE_KEY_ENTER, "\r"},
    {"tab", MISSTYPE_KEY_TAB, "\t"}, {"bs", MISSTYPE_KEY_BACKSPACE, NULL},
    {"del", MISSTYPE_KEY_FORWARD_DELETE, NULL}, {"esc", MISSTYPE_KEY_ESCAPE, "\x1b"},
    {"left", MISSTYPE_KEY_LEFT, NULL}, {"right", MISSTYPE_KEY_RIGHT, NULL},
    {"up", MISSTYPE_KEY_UP, NULL}, {"down", MISSTYPE_KEY_DOWN, NULL},
    {"pgup", MISSTYPE_KEY_PAGE_UP, NULL}, {"pgdn", MISSTYPE_KEY_PAGE_DOWN, NULL},
    {"other", MISSTYPE_KEY_OTHER, "\x01"}, {"mod", MISSTYPE_KEY_MODIFIER, NULL},
};

/* US shifted glyph of an unshifted label, for event text. */
static const char *shifted_text(const char *label) {
    static char out[2];
    const char *from = "1234567890-=[];'`\\,./", *to = "!@#$%^&*()_+{}:\"~|<>?";
    if (strlen(label) == 1) {
        const char *at = strchr(from, label[0]);
        if (at) { out[0] = to[at - from]; out[1] = 0; return out; }
        if (label[0] >= 'a' && label[0] <= 'z') { out[0] = (char)(label[0] - 32); out[1] = 0; return out; }
    }
    return label;
}

static void key_token(const char *token) {
    if (!strcmp(token, "stap") || !strcmp(token, "rtap")) {
        misstype_key_kind side = token[0] == 's' ? MISSTYPE_KEY_SHIFT_LEFT : MISSTYPE_KEY_SHIFT_RIGHT;
        misstype_key_event down = { side, NULL, NULL, MISSTYPE_MOD_SHIFT, 0, -1, 0 };
        misstype_key_event up = { side, NULL, NULL, 0, 1, -1, 0 };
        send(down);
        send(up);
        return;
    }
    uint32_t mods = 0;
    while (strlen(token) > 2 && token[1] == '-') {
        switch (token[0]) {
        case 'S': mods |= MISSTYPE_MOD_SHIFT; break;
        case 'C': mods |= MISSTYPE_MOD_CONTROL; break;
        case 'A': mods |= MISSTYPE_MOD_ALT; break;
        case 'M': mods |= MISSTYPE_MOD_SUPER; break;
        case 'K': mods |= MISSTYPE_MOD_CAPS_LOCK; break;
        default: fprintf(stderr, "replay: bad modifier in %s\n", token); exit(2);
        }
        token += 2;
    }
    misstype_key_event ev = { MISSTYPE_KEY_CHARACTER, NULL, NULL, mods, 0, -1, 0 };
    for (size_t i = 0; i < sizeof named / sizeof named[0]; i++) {
        if (!strcmp(token, named[i].name)) {
            ev.kind = named[i].kind;
            ev.text = named[i].text;
            send(ev);
            return;
        }
    }
    const char *label = NULL;
    int32_t shifted = 0;
    if (misstype_key_from_character(token, &label, &shifted) != MISSTYPE_KEY_CHARACTER || shifted) {
        fprintf(stderr, "replay: unknown key %s\n", token);
        exit(2);
    }
    ev.label = label;
    ev.text = (mods & MISSTYPE_MOD_SHIFT) ? shifted_text(label) : label;
    send(ev);
}

static void type_text(const char *text) {
    const unsigned char *p = (const unsigned char *)text;
    while (*p) {
        int len = *p < 0x80 ? 1 : *p < 0xE0 ? 2 : *p < 0xF0 ? 3 : 4;
        char ch[5] = {0};
        memcpy(ch, p, (size_t)len);
        p += len;
        const char *label = NULL;
        int32_t shifted = 0;
        misstype_key_kind kind = misstype_key_from_character(ch, &label, &shifted);
        misstype_key_event ev = { kind, label, ch, shifted ? MISSTYPE_MOD_SHIFT : 0, 0, -1, 0 };
        send(ev);
    }
}

static void run(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) { perror(path); exit(2); }
    char line[4096];
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\n")] = 0;
        if (!line[0] || line[0] == '#') continue;
        printf("%s\n", line);
        if (!strncmp(line, "@engine ", 8)) {
            new_engine(line + 8);
        } else if (!strncmp(line, "@set ", 5)) {
            for (char *tok = strtok(line + 5, " "); tok; tok = strtok(NULL, " ")) {
                char *eq = strchr(tok, '=');
                if (!eq) { fprintf(stderr, "replay: bad setting %s\n", tok); exit(2); }
                *eq = 0;
                set_option(tok, eq + 1);
            }
        } else if (!strncmp(line, "@case", 5)) {
            new_session();
            continue;
        } else if (!strncmp(line, "k ", 2)) {
            for (char *tok = strtok(line + 2, " "); tok; tok = strtok(NULL, " ")) key_token(tok);
            continue;
        } else if (!strncmp(line, "t ", 2)) {
            type_text(line + 2);
            continue;
        } else if (!strncmp(line, "pick ", 5)) {
            misstype_session_pick(session, atoi(line + 5));
        } else if (!strcmp(line, "commit")) {
            char *c = misstype_session_commit(session);
            printf("  -> commit=");
            if (c) print_json_string(c); else printf("null");
            putchar('\n');
            misstype_string_free(c);
        } else if (!strcmp(line, "reset")) {
            misstype_session_reset_modifiers(session);
        } else {
            fprintf(stderr, "replay: bad line %s\n", line);
            exit(2);
        }
        print_state();
    }
    fclose(f);
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: replay <shipping dir> <fixture dir> <script>...\n");
        return 2;
    }
    dirs[0] = argv[1];
    dirs[1] = argv[2];
    setvbuf(stdout, NULL, _IOFBF, 1 << 16);
    for (int i = 3; i < argc; i++) run(argv[i]);
    if (session) misstype_session_free(session);
    if (engine) misstype_engine_free(engine);
    if (getenv("MISSTYPE_REPLAY_METRICS") && handle_count)
        fprintf(stderr, "replay: events=%lu handle mean=%.1fus max=%.1fus\n", handle_count,
                (double)handle_ns / handle_count / 1000, (double)max_handle_ns / 1000);
    return 0;
}

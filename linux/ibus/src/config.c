// Settings for the IBus adapter. IBus has no settings-page API of its own, so
// the engine reads the same ini file the fcitx5 addon and `misstypectl config`
// edit (docs/linux-port.md L7): $XDG_CONFIG_HOME/fcitx5/conf/misstype.conf.
// Keys and defaults mirror MisstypeConfig in linux/fcitx5/src/engine.cpp
// (macOS MisstypePrefs); keep them in step with core-zig/src/ctl.zig.
#include "engine.h"

#include <stdlib.h>
#include <string.h>

typedef struct {
    int repair_strength; // 0 Off, 1 Light, 2 Standard, 3 Strong
    gboolean tone_tolerance, user_learning, channel_learning, mixed_english;
    gboolean auto_show_candidates, return_confirms_selection;
    char *candidate_keys;
    int page_size;
    int cursor_candidates; // 0 Covering, 1 EndingAt, 2 BeginningAt
    int auto_commit_syllables;
} Config;

static void config_defaults(Config *c) {
    c->repair_strength = 2;
    c->tone_tolerance = TRUE;
    c->user_learning = TRUE;
    c->channel_learning = FALSE;
    c->mixed_english = FALSE;
    c->auto_show_candidates = FALSE;
    c->return_confirms_selection = TRUE;
    c->candidate_keys = g_strdup("asdfghjkl;");
    c->page_size = 8;
    c->cursor_candidates = 0;
    c->auto_commit_syllables = 24;
}

static gboolean parse_bool(const char *v, gboolean fallback) {
    if (!g_ascii_strcasecmp(v, "true")) return TRUE;
    if (!g_ascii_strcasecmp(v, "false")) return FALSE;
    return fallback;
}

static int parse_enum(const char *v, const char *const *names, int count, int fallback) {
    for (int i = 0; i < count; ++i)
        if (!g_ascii_strcasecmp(v, names[i])) return i;
    return fallback;
}

static int parse_int(const char *v, int lo, int hi, int fallback) {
    char *end = NULL;
    long n = strtol(v, &end, 10);
    if (end == v || *end != '\0' || n < lo || n > hi) return fallback;
    return (int)n;
}

static void apply_line(Config *c, const char *key, const char *value) {
    static const char *const repair[] = {"Off", "Light", "Standard", "Strong"};
    static const char *const cursor[] = {"Covering", "EndingAt", "BeginningAt"};
    if (!strcmp(key, "RepairStrength")) c->repair_strength = parse_enum(value, repair, 4, c->repair_strength);
    else if (!strcmp(key, "ToneTolerance")) c->tone_tolerance = parse_bool(value, c->tone_tolerance);
    else if (!strcmp(key, "UserLearning")) c->user_learning = parse_bool(value, c->user_learning);
    else if (!strcmp(key, "ChannelLearning")) c->channel_learning = parse_bool(value, c->channel_learning);
    else if (!strcmp(key, "MixedEnglish")) c->mixed_english = parse_bool(value, c->mixed_english);
    else if (!strcmp(key, "AutoShowCandidates")) c->auto_show_candidates = parse_bool(value, c->auto_show_candidates);
    else if (!strcmp(key, "ReturnConfirmsSelection")) c->return_confirms_selection = parse_bool(value, c->return_confirms_selection);
    else if (!strcmp(key, "CandidateKeys")) {
        if (*value) {
            g_free(c->candidate_keys);
            c->candidate_keys = g_strdup(value);
        }
    } else if (!strcmp(key, "CandidatesPerPage")) c->page_size = parse_int(value, 4, 10, c->page_size);
    else if (!strcmp(key, "CursorCandidates")) c->cursor_candidates = parse_enum(value, cursor, 3, c->cursor_candidates);
    else if (!strcmp(key, "AutoCommitSyllables")) c->auto_commit_syllables = parse_int(value, 0, 64, c->auto_commit_syllables);
}

static char *config_path(void) {
    const char *override = g_getenv("MISSTYPE_CONFIG");
    if (override && *override) return g_strdup(override);
    const char *xdg = g_getenv("XDG_CONFIG_HOME");
    if (xdg && g_path_is_absolute(xdg)) return g_build_filename(xdg, "fcitx5", "conf", "misstype.conf", NULL);
    return g_build_filename(g_get_home_dir(), ".config", "fcitx5", "conf", "misstype.conf", NULL);
}

void misstype_ibus_apply_config(misstype_engine *core) {
    if (!core) return;
    Config c;
    config_defaults(&c);
    char *path = config_path();
    char *text = NULL;
    if (g_file_get_contents(path, &text, NULL, NULL)) {
        char **lines = g_strsplit(text, "\n", -1);
        for (char **l = lines; *l; ++l) {
            char *line = g_strstrip(*l);
            if (!*line || *line == '#' || *line == '[') continue;
            char *eq = strchr(line, '=');
            if (!eq) continue;
            *eq = '\0';
            apply_line(&c, g_strstrip(line), g_strstrip(eq + 1));
        }
        g_strfreev(lines);
        g_free(text);
    }
    g_free(path);

    // IBus has no competing lone-Shift trigger, so the session owns it (macOS).
    misstype_settings s = misstype_settings_default();
    s.shift_toggle = 1;
    s.fuzzy_repair = c.repair_strength != 0;
    s.tone_tolerance = c.tone_tolerance;
    s.user_learning = c.user_learning;
    s.mixed_english = c.mixed_english;
    s.auto_show_candidates = c.auto_show_candidates;
    s.return_confirms_selection = c.return_confirms_selection;
    s.auto_commit_syllables = c.auto_commit_syllables;
    s.page_size = c.page_size;
    s.cursor_candidates = c.cursor_candidates;
    s.candidate_keys = c.candidate_keys; // copied by the engine during the call
    misstype_engine_set_settings(core, &s);
    misstype_engine_set_repair_strength(core, c.repair_strength);
    misstype_engine_set_channel_learning(core, c.channel_learning);
    g_free(c.candidate_keys);
}

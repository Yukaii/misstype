/* misstype.h: C ABI of the Zig core's Session (core-zig/src/capi.zig; docs/cross-platform.md).
 *
 * Threading: all calls for one engine and its sessions on one thread.
 * Memory: every char* and misstype_view* returned is owned by the caller and
 * must be released with misstype_string_free / misstype_view_free. Labels
 * returned by the keymap functions are static (never free them).
 */
#ifndef MISSTYPE_H
#define MISSTYPE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 2 (2026-10-09): key_result.latin_toggled, view page size / word segments /
 * focus, key bindings, the macOS keycode table, user dictionary text and
 * learning editor functions. Fields were appended; misstype_key_result grew,
 * so callers rebuild against this header. */
#define MISSTYPE_ABI_VERSION 2
int32_t misstype_abi_version(void);

typedef struct misstype_engine misstype_engine;
typedef struct misstype_session misstype_session;

typedef enum misstype_key_kind {
    MISSTYPE_KEY_CHARACTER = 0, /* label = US-ANSI unshifted label: "a", "1", ";", "`" */
    MISSTYPE_KEY_SPACE = 1,
    MISSTYPE_KEY_ENTER = 2,
    MISSTYPE_KEY_TAB = 3,
    MISSTYPE_KEY_BACKSPACE = 4,
    MISSTYPE_KEY_FORWARD_DELETE = 5,
    MISSTYPE_KEY_ESCAPE = 6,
    MISSTYPE_KEY_LEFT = 7,
    MISSTYPE_KEY_RIGHT = 8,
    MISSTYPE_KEY_UP = 9,
    MISSTYPE_KEY_DOWN = 10,
    MISSTYPE_KEY_SHIFT_LEFT = 11,
    MISSTYPE_KEY_SHIFT_RIGHT = 12,
    MISSTYPE_KEY_MODIFIER = 13, /* Ctrl, Alt, Super, Caps Lock, Fn alone */
    MISSTYPE_KEY_OTHER = 14,
    MISSTYPE_KEY_PAGE_UP = 15,  /* appended: values above are ABI-stable */
    MISSTYPE_KEY_PAGE_DOWN = 16
} misstype_key_kind;

/* Modifier bit values (the macOS adapter's KeyEvent.Modifiers use the same). */
enum {
    MISSTYPE_MOD_SHIFT = 1 << 0,
    MISSTYPE_MOD_CONTROL = 1 << 1,
    MISSTYPE_MOD_ALT = 1 << 2,       /* Option on macOS */
    MISSTYPE_MOD_SUPER = 1 << 3,     /* Command on macOS */
    MISSTYPE_MOD_CAPS_LOCK = 1 << 4
};

typedef struct misstype_key_event {
    misstype_key_kind kind;
    const char *label;    /* MISSTYPE_KEY_CHARACTER only, else NULL */
    const char *text;     /* UTF-8 the key types in the user's layout, or NULL */
    uint32_t modifiers;   /* MISSTYPE_MOD_* state AFTER this event */
    int32_t is_release;   /* 1 = key-up or modifier-only transition */
    int32_t native_code;  /* diagnostics only; -1 = unknown */
    double timestamp;     /* seconds, monotonic; < 0 = now */
} misstype_key_event;

typedef struct misstype_key_result {
    int32_t consumed;     /* 0 = the application gets the key, after commit */
    char *commit;         /* UTF-8 to insert now, or NULL (misstype_string_free) */
    int32_t beep;
    int32_t mode_changed; /* 中/英 flipped: see misstype_engine_is_english */
    int32_t latin_toggled; /* v2: a Latin run opened/closed mid-composition (no
                            * commit, no global flip): flash 英/中 from
                            * misstype_session_latin_active */
} misstype_key_result;

typedef enum misstype_mark_action {
    MISSTYPE_MARK_NONE = 0,
    MISSTYPE_MARK_ADD = 1,         /* Enter adds the phrase to the user dictionary */
    MISSTYPE_MARK_REMOVE = 2,      /* already there: Enter removes it */
    MISSTYPE_MARK_TOO_SHORT = 3,   /* mark 2-8 syllables */
    MISSTYPE_MARK_TOO_LONG = 4,
    MISSTYPE_MARK_UNAVAILABLE = 5  /* crosses punctuation/Latin or raw Zhuyin */
} misstype_mark_action;

typedef struct misstype_view {
    char *preedit;              /* UTF-8, "" when idle */
    int32_t caret_bytes;        /* caret as a UTF-8 byte offset into preedit */
    int32_t caret_utf16;        /* same caret in UTF-16 units */
    char **candidates;          /* full list, candidate_count entries */
    int32_t candidate_count;
    int32_t selected;           /* index into candidates */
    char **selection_keys;      /* labels for the visible rows */
    int32_t selection_key_count;
    int32_t keys_active;        /* selection keys pick (else they type Zhuyin) */
    int32_t shows_candidates;
    /* Phrase mark (Shift+Left/Right; docs/cross-platform.md C13). Appended
     * fields: ABI v1 callers that predate them never read past
     * shows_candidates. While mark_action != MISSTYPE_MARK_NONE the host draws
     * [mark_start_*, mark_end_*) highlighted inside preedit and shows
     * mark_text / mark_reading as the hint for what Enter will do. */
    int32_t mark_action;        /* misstype_mark_action */
    int32_t mark_start_bytes;   /* UTF-8 byte offsets into preedit, else -1 */
    int32_t mark_end_bytes;
    int32_t mark_start_utf16;   /* same range in UTF-16 units, else -1 */
    int32_t mark_end_utf16;
    char *mark_text;            /* "" when no mark or unavailable */
    char *mark_reading;         /* hyphen-joined toned Zhuyin, "" when none */
    /* v2. Rows per page: the page holding `selected` starts at
     * selected / page_size * page_size. */
    int32_t page_size;
    /* v2. Word boundaries of preedit as contiguous UTF-16 ranges covering
     * all of it (decoded words, Latin/punctuation gaps, the raw tail): one
     * underline segment per word. segment_count == 0: draw one segment. */
    int32_t segment_count;
    int32_t *segments_utf16;    /* 2 * segment_count values: start, end, ... */
    int32_t focus_start_utf16;  /* v2: the syllable cursor's word, else -1 */
    int32_t focus_end_utf16;
} misstype_view;

/* Which words the syllable cursor (Left/Right) lists. */
typedef enum misstype_cursor_candidates {
    MISSTYPE_CURSOR_COVERING = 0,     /* every word covering the cursor syllable */
    MISSTYPE_CURSOR_ENDING_AT = 1,    /* words ending at the cursor syllable, caret after it */
    MISSTYPE_CURSOR_BEGINNING_AT = 2  /* words starting at the cursor syllable, caret before it */
} misstype_cursor_candidates;

typedef struct misstype_settings {
    int32_t fuzzy_repair;       /* default 1 */
    int32_t tone_tolerance;     /* default 1 */
    int32_t user_learning;      /* default 1 */
    int32_t shift_toggle;       /* default 1; fcitx5 sets 0 (AltTriggerKeys owns Shift_L) */
    const char *candidate_keys; /* NULL = "asdfghjkl;"; sanitized: distinct Zhuyin/tone keys, one page */
    /* Appended fields. misstype_settings_default() keeps the core's behavior. */
    int32_t auto_show_candidates;       /* default 1; 0 = panel opens on Tab/arrows only */
    int32_t return_confirms_selection;  /* default 0; 1 = Return confirms a pick, the next Return sends */
    int32_t mixed_english;              /* default 1; needs english.tsv, else no effect */
    int32_t auto_commit_syllables;      /* default 24; 0 = never commit in chunks */
    int32_t page_size;                  /* default 8; candidates per page, clamped to 4...10 */
    int32_t cursor_candidates;          /* misstype_cursor_candidates; default COVERING */
} misstype_settings;

misstype_settings misstype_settings_default(void);

/* resource_dir holds lexicon.tsv (required), local_phrases.tsv, toneless.tsv.
 * user_lexicon_path: NULL = user_phrases.json in the platform data directory
 * (~/Library/Application Support/Misstype on macOS, $XDG_DATA_HOME/misstype
 * elsewhere), "" = memory only.
 * Returns NULL when lexicon.tsv is missing or unreadable. */
misstype_engine *misstype_engine_new(const char *resource_dir, const char *user_lexicon_path);
/* Releases the caller's handle; live sessions keep the engine alive. */
void misstype_engine_free(misstype_engine *engine);
void misstype_engine_set_settings(misstype_engine *engine, const misstype_settings *settings);
int32_t misstype_engine_is_english(const misstype_engine *engine);

/* User dictionary (my words): path of user_dictionary.tsv. NULL =
 * the default (user_dictionary.tsv in the platform data directory),
 * "" = memory only (the default after misstype_engine_new, so tests are
 * hermetic). Loads the file now; Enter on a mark persists to it, and edits
 * made outside are picked up when the next composition starts. */
void misstype_engine_set_user_dictionary_path(misstype_engine *engine, const char *path);

/* Personal channel model (learned typing slips; docs/project-outline.md,
 * Personal channel model). Appended functions, the settings struct is
 * unchanged. Path: NULL = the default (channel_model.json in the platform data
 * directory), "" = memory only (the default after misstype_engine_new). Learning is off until enabled, and
 * also needs user_learning; misstype_engine_set_settings keeps the flag. */
void misstype_engine_set_channel_path(misstype_engine *engine, const char *path);
void misstype_engine_set_channel_learning(misstype_engine *engine, int32_t enabled);
/* Repair strength (how readily keyboard slips are repaired): 0 off,
 * 1 light, 2 standard (the default), 3 strong; other values are ignored.
 * Appended, like the channel functions. misstype_engine_set_settings keeps
 * it while fuzzy_repair stays 1; fuzzy_repair = 0 means off. */
void misstype_engine_set_repair_strength(misstype_engine *engine, int32_t level);
/* Forgets every learned slip, on disk too. */
void misstype_engine_clear_channel(misstype_engine *engine);
/* Number of learned pairs the decoder currently uses. */
int32_t misstype_engine_channel_pair_count(const misstype_engine *engine);

misstype_session *misstype_session_new(misstype_engine *engine);
void misstype_session_free(misstype_session *session);
misstype_key_result misstype_session_handle(misstype_session *session, const misstype_key_event *event);
char *misstype_session_commit(misstype_session *session); /* NULL = nothing to insert */
void misstype_session_pick(misstype_session *session, int32_t index);
void misstype_session_reset_modifiers(misstype_session *session);
char *misstype_session_raw_phonetic(misstype_session *session);
/* 1 while an English (latin) run is open mid-composition (Shift tap or
 * backtick), else 0. Appended 2026-10-07: the host
 * compares it across misstype_session_handle to show 英/中 (contract §2). */
int32_t misstype_session_latin_active(misstype_session *session);
misstype_view *misstype_session_view(misstype_session *session);

/* Keymap (tables live in core-zig/src/capi.zig). label receives a static string for
 * MISSTYPE_KEY_CHARACTER, else NULL. */
misstype_key_kind misstype_key_from_evdev(int32_t evdev_code, const char **label);
/* Fallback without a scancode: one UTF-8 character typed on a US layout.
 * *shifted = 1 when the glyph needs Shift ("A", "!"). Unknown: MISSTYPE_KEY_OTHER. */
misstype_key_kind misstype_key_from_character(const char *utf8, const char **label, int32_t *shifted);
/* v2. macOS virtual key codes (ANSI positions), same labels as evdev. */
misstype_key_kind misstype_key_from_mac(int32_t keycode, const char **label);

/* v2. Key bindings in text form, one action per line
 * ("nextCandidate = tab, ctrl+n"; "latinRun =" unbinds); NULL or "" = the
 * defaults. Kept across misstype_engine_set_settings. */
void misstype_engine_set_key_bindings(misstype_engine *engine, const char *text);

/* v2. Learned phrases (UserLexicon at the engine's user lexicon path). */
int32_t misstype_engine_learned_phrase_count(const misstype_engine *engine);
void misstype_engine_reload_learned_phrases(misstype_engine *engine); /* re-read the file */
void misstype_engine_save_learned_phrases(misstype_engine *engine);   /* flush to the file */
void misstype_engine_clear_learned_phrases(misstype_engine *engine);  /* forget all, on disk too */
/* v2. Learned typing slips the decoder uses, cheapest first: one
 * "typed<TAB>intended<TAB>cost" line each (Bopomofo symbols); "" when none. */
char *misstype_engine_channel_pairs(const misstype_engine *engine);

/* v2. User dictionary text (user_dictionary.tsv, vChewing format). */
/* Canonical text of the dictionary the engine has loaded. */
char *misstype_engine_user_dictionary_text(const misstype_engine *engine);
/* Problems of editor text, one "line<TAB>message" row each ("" = none);
 * *added / *hidden receive the valid word and hidden-word counts. */
char *misstype_user_dictionary_check(const char *text, int32_t *added, int32_t *hidden);
/* Appends the new entries of `source` to editor `text` in canonical lines
 * (nothing is written to disk). Returns the merged text; counts may be NULL. */
char *misstype_user_dictionary_import(const char *text, const char *source, int32_t *added,
                                      int32_t *duplicates, int32_t *skipped);

void misstype_view_free(misstype_view *view);
void misstype_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif /* MISSTYPE_H */
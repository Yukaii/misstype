/* mistype.h: C ABI over MistypeCore's InputSession (docs/cross-platform.md).
 *
 * Threading: all calls for one engine and its sessions on one thread.
 * Memory: every char* and mistype_view* returned is owned by the caller and
 * must be released with mistype_string_free / mistype_view_free. Labels
 * returned by the keymap functions are static (never free them).
 */
#ifndef MISTYPE_H
#define MISTYPE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MISTYPE_ABI_VERSION 1
int32_t mistype_abi_version(void);

typedef struct mistype_engine mistype_engine;
typedef struct mistype_session mistype_session;

typedef enum mistype_key_kind {
    MISTYPE_KEY_CHARACTER = 0, /* label = US-ANSI unshifted label: "a", "1", ";", "`" */
    MISTYPE_KEY_SPACE = 1,
    MISTYPE_KEY_ENTER = 2,
    MISTYPE_KEY_TAB = 3,
    MISTYPE_KEY_BACKSPACE = 4,
    MISTYPE_KEY_FORWARD_DELETE = 5,
    MISTYPE_KEY_ESCAPE = 6,
    MISTYPE_KEY_LEFT = 7,
    MISTYPE_KEY_RIGHT = 8,
    MISTYPE_KEY_UP = 9,
    MISTYPE_KEY_DOWN = 10,
    MISTYPE_KEY_SHIFT_LEFT = 11,
    MISTYPE_KEY_SHIFT_RIGHT = 12,
    MISTYPE_KEY_MODIFIER = 13, /* Ctrl, Alt, Super, Caps Lock, Fn alone */
    MISTYPE_KEY_OTHER = 14
} mistype_key_kind;

/* Bit values equal KeyEvent.Modifiers raw values. */
enum {
    MISTYPE_MOD_SHIFT = 1 << 0,
    MISTYPE_MOD_CONTROL = 1 << 1,
    MISTYPE_MOD_ALT = 1 << 2,       /* KeyEvent.Modifiers.option */
    MISTYPE_MOD_SUPER = 1 << 3,     /* KeyEvent.Modifiers.command */
    MISTYPE_MOD_CAPS_LOCK = 1 << 4
};

typedef struct mistype_key_event {
    mistype_key_kind kind;
    const char *label;    /* MISTYPE_KEY_CHARACTER only, else NULL */
    const char *text;     /* UTF-8 the key types in the user's layout, or NULL */
    uint32_t modifiers;   /* MISTYPE_MOD_* state AFTER this event */
    int32_t is_release;   /* 1 = key-up or modifier-only transition */
    int32_t native_code;  /* diagnostics only; -1 = unknown */
    double timestamp;     /* seconds, monotonic; < 0 = now */
} mistype_key_event;

typedef struct mistype_key_result {
    int32_t consumed;     /* 0 = the application gets the key, after commit */
    char *commit;         /* UTF-8 to insert now, or NULL (mistype_string_free) */
    int32_t beep;
    int32_t mode_changed; /* 中/英 flipped: see mistype_engine_is_english */
} mistype_key_result;

typedef struct mistype_view {
    char *preedit;              /* UTF-8, "" when idle */
    int32_t caret_bytes;        /* caret as a UTF-8 byte offset into preedit */
    int32_t caret_utf16;        /* same caret in UTF-16 units (SessionView.caret) */
    char **candidates;          /* full list, candidate_count entries */
    int32_t candidate_count;
    int32_t selected;           /* index into candidates */
    char **selection_keys;      /* labels for the visible rows */
    int32_t selection_key_count;
    int32_t keys_active;        /* selection keys pick (else they type Zhuyin) */
    int32_t shows_candidates;
} mistype_view;

typedef struct mistype_settings {
    int32_t fuzzy_repair;       /* default 1 */
    int32_t tone_tolerance;     /* default 1 */
    int32_t user_learning;      /* default 1 */
    int32_t shift_toggle;       /* default 1; fcitx5 sets 0 (AltTriggerKeys owns Shift_L) */
    const char *candidate_keys; /* NULL = "asdfghjkl;"; sanitized like SelectionKeys.sanitize */
} mistype_settings;

mistype_settings mistype_settings_default(void);

/* resource_dir holds lexicon.tsv (required), local_phrases.tsv, toneless.tsv.
 * user_lexicon_path: NULL = UserLexicon.defaultURL, "" = memory only.
 * Returns NULL when lexicon.tsv is missing or unreadable. */
mistype_engine *mistype_engine_new(const char *resource_dir, const char *user_lexicon_path);
/* Releases the caller's handle; live sessions keep the engine alive. */
void mistype_engine_free(mistype_engine *engine);
void mistype_engine_set_settings(mistype_engine *engine, const mistype_settings *settings);
int32_t mistype_engine_is_english(const mistype_engine *engine);

mistype_session *mistype_session_new(mistype_engine *engine);
void mistype_session_free(mistype_session *session);
mistype_key_result mistype_session_handle(mistype_session *session, const mistype_key_event *event);
char *mistype_session_commit(mistype_session *session); /* NULL = nothing to insert */
void mistype_session_pick(mistype_session *session, int32_t index);
void mistype_session_reset_modifiers(mistype_session *session);
char *mistype_session_raw_phonetic(mistype_session *session);
mistype_view *mistype_session_view(mistype_session *session);

/* Keymap (tables live in MistypeCore). label receives a static string for
 * MISTYPE_KEY_CHARACTER, else NULL. */
mistype_key_kind mistype_key_from_evdev(int32_t evdev_code, const char **label);
/* Fallback without a scancode: one UTF-8 character typed on a US layout.
 * *shifted = 1 when the glyph needs Shift ("A", "!"). Unknown: MISTYPE_KEY_OTHER. */
mistype_key_kind mistype_key_from_character(const char *utf8, const char **label, int32_t *shifted);

void mistype_view_free(mistype_view *view);
void mistype_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif /* MISTYPE_H */
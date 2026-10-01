// fcitx5 adapter for Mistype (docs/cross-platform.md, docs/linux-port.md L3).
// All editing rules live in MistypeCore's InputSession behind the C ABI in
// mistype.h; this file only translates key events, applies key results and
// draws the session view.
#include <fcitx-utils/key.h>
#include <fcitx-utils/log.h>
#include <fcitx-config/configuration.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/addonmanager.h>
#include <fcitx/candidatelist.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputcontextproperty.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/inputpanel.h>
#include <fcitx/instance.h>
#include <fcitx/text.h>

#include <mistype.h>

#include <cstdlib>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace {

constexpr int kPageSize = 8;

/// Owned copy of a mistype_view; comparable so unchanged views are not redrawn.
struct ViewSnapshot {
    std::string preedit;
    int caretBytes = 0;
    std::vector<std::string> candidates;
    int selected = 0;
    std::vector<std::string> selectionKeys;
    bool keysActive = false;
    bool showsCandidates = false;

    bool operator==(const ViewSnapshot &o) const {
        return preedit == o.preedit && caretBytes == o.caretBytes && candidates == o.candidates &&
               selected == o.selected && selectionKeys == o.selectionKeys && keysActive == o.keysActive &&
               showsCandidates == o.showsCandidates;
    }
};

bool snapshot(mistype_session *session, ViewSnapshot &out) {
    mistype_view *view = mistype_session_view(session);
    if (!view) {
        return false;
    }
    out = {};
    out.preedit = view->preedit ? view->preedit : "";
    out.caretBytes = view->caret_bytes;
    for (int i = 0; i < view->candidate_count; ++i) {
        out.candidates.emplace_back(view->candidates[i]);
    }
    out.selected = view->selected;
    for (int i = 0; i < view->selection_key_count; ++i) {
        out.selectionKeys.emplace_back(view->selection_keys[i]);
    }
    out.keysActive = view->keys_active != 0;
    out.showsCandidates = view->shows_candidates != 0;
    mistype_view_free(view);
    return true;
}

class MistypeState : public fcitx::InputContextProperty {
public:
    explicit MistypeState(mistype_engine *engine) : engine_(engine) {}
    ~MistypeState() override {
        if (session_) {
            mistype_session_free(session_);
        }
    }
    /// Created on first use: fcitx5 may build the state before the engine exists.
    mistype_session *session() {
        if (!session_ && engine_) {
            session_ = mistype_session_new(engine_);
        }
        return session_;
    }

    std::optional<ViewSnapshot> last; // what the client currently shows
    bool auxShown = false;            // 中/英 indicator is up

private:
    mistype_engine *engine_;
    mistype_session *session_ = nullptr;
};

class MistypeEngine;

/// macOS parity: the same option set as MistypePrefs (minus ShiftToggle,
/// which fcitx5 owns through AltTriggerKeys, and minus the Jev gateway,
/// which needs an async session host the C ABI does not have yet).
/// Surfaced in fcitx5-configtool via Configurable=True in mistype.conf.
FCITX_CONFIGURATION(MistypeConfig,
    fcitx::Option<bool> fuzzyRepair{this, "FuzzyRepair",
        "Fuzzy repair: recovers from transposed, substituted, missing or extra keys.", true};
    fcitx::Option<bool> toneTolerance{this, "ToneTolerance",
        "Tone tolerance: a wrong tone stays viable with a ranking penalty.", true};
    fcitx::Option<std::string> candidateKeys{this, "CandidateKeys",
        "Selection keys: pick a candidate in selection mode; while typing they stay Zhuyin keys.",
        "asdfghjkl;"};
    fcitx::Option<bool> userLearning{this, "UserLearning",
        "Learn from explicit picks: remembers candidates chosen on purpose and ranks them higher next time. Stored locally.", true};
    fcitx::Option<int, fcitx::IntConstrain> autoCommitSyllables{this, "AutoCommitSyllables",
        "Auto-commit long compositions: compositions longer than this many syllables commit their settled head in chunks (0 = off).",
        24, fcitx::IntConstrain(0, 200)};
);

/// One row of the candidate list; selecting it picks that row in the session.
/// macOS parity: the selection key is visually distinct from the character —
/// bold with a two-space gap, like the macOS panel's dimmed key + "  ".
class MistypeCandidate : public fcitx::CandidateWord {
public:
    MistypeCandidate(MistypeEngine *engine, int index, const std::string &text,
                     const std::string &labelKey = "")
        : fcitx::CandidateWord(fcitx::Text(text)), engine_(engine), index_(index) {
        if (!labelKey.empty()) {
            setCustomLabel(fcitx::Text(labelKey + "  ", fcitx::TextFormatFlag::Bold));
        }
    }
    void select(fcitx::InputContext *ic) const override;

private:
    MistypeEngine *engine_;
    int index_;
};

class MistypeEngine : public fcitx::InputMethodEngineV2 {
public:
    explicit MistypeEngine(fcitx::Instance *instance)
        : stateFactory_([this](fcitx::InputContext &) { return new MistypeState(engine_); }) {
        const std::string resources = resourcesDir();
        // Never run against a C ABI we were not compiled for: the struct
        // layout is versioned, and a skew would read garbage settings.
        if (mistype_abi_version() != MISTYPE_ABI_VERSION) {
            FCITX_ERROR() << "Mistype: C ABI version mismatch (want " << MISTYPE_ABI_VERSION
                          << ", got " << mistype_abi_version() << "); not filtering keys.";
            return;
        }
        // NULL user lexicon path: learned phrases go to $XDG_DATA_HOME/mistype.
        engine_ = mistype_engine_new(resources.c_str(), nullptr);
        if (engine_) {
            applySettings();
        } else {
            // Never crash and never filter: every key passes through.
            FCITX_ERROR() << "Mistype: cannot load lexicon.tsv from " << resources;
        }
        // After the engine exists: fcitx5 may build per-context state right away.
        instance->inputContextManager().registerProperty("mistype", &stateFactory_);
    }

    ~MistypeEngine() override {
        if (engine_) {
            mistype_engine_free(engine_);
        }
    }

    void keyEvent(const fcitx::InputMethodEntry &, fcitx::KeyEvent &event) override {
        auto *ic = event.inputContext();
        auto *state = stateFor(ic);
        if (!state) {
            return;
        }
        mistype_key_event keyEvent = buildKeyEvent(event);
        mistype_key_result result = mistype_session_handle(state->session(), &keyEvent);

        // Contract §2: commit, then render, then the mode indicator.
        if (result.commit) {
            ic->commitString(result.commit);
            mistype_string_free(result.commit);
            state->last.reset();
        }
        render(ic, state, /*force=*/result.mode_changed || state->auxShown);
        if (result.mode_changed) {
            const bool english = mistype_engine_is_english(engine_) != 0;
            ic->inputPanel().setAuxUp(fcitx::Text(english ? "英" : "中"));
            state->auxShown = true;
            ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
        }

        // Delivery rules: releases and bare modifiers are never filtered.
        const bool bare = keyEvent.kind == MISTYPE_KEY_MODIFIER || keyEvent.kind == MISTYPE_KEY_SHIFT_LEFT ||
                          keyEvent.kind == MISTYPE_KEY_SHIFT_RIGHT;
        if (result.consumed && !keyEvent.is_release && !bare) {
            event.filterAndAccept();
        }
    }

    // Client reset (the application dropped its text): discard, never insert.
    void reset(const fcitx::InputMethodEntry &, fcitx::InputContextEvent &event) override {
        flush(event, /*commit=*/false);
    }
    void deactivate(const fcitx::InputMethodEntry &, fcitx::InputContextEvent &event) override {
        // Contract §4: focus out commits the composition. fcitx5 already
        // commits client-side preedit itself when the input context loses
        // focus, so committing again would insert the text twice; every other
        // case (switching input method, panel-only preedit) is ours to commit.
        const bool coreCommits = event.type() == fcitx::EventType::InputContextFocusOut &&
                                 event.inputContext()->capabilityFlags().test(fcitx::CapabilityFlag::Preedit);
        flush(event, /*commit=*/!coreCommits);
    }

    void activate(const fcitx::InputMethodEntry &, fcitx::InputContextEvent &event) override {
        if (auto *state = stateFor(event.inputContext())) {
            mistype_session_reset_modifiers(state->session());
        }
    }

    void pick(fcitx::InputContext *ic, int index) {
        if (auto *state = stateFor(ic)) {
            mistype_session_pick(state->session(), index);
            render(ic, state, false);
        }
    }

    const fcitx::Configuration *getConfig() const override { return &config_; }
    void setConfig(const fcitx::RawConfig &config) override {
        config_.load(config, /*partial=*/true);
        applySettings();
    }
    void reloadConfig() override { applySettings(); }

private:
    /// Push the fcitx5 config into the core. fcitx5 owns lone Shift
    /// (AltTriggerKeys), so shift_toggle stays 0 here even though the macOS
    /// default is on; everything else mirrors MistypePrefs one-to-one.
    void applySettings() {
        if (!engine_) {
            return;
        }
        mistype_settings settings = mistype_settings_default();
        settings.fuzzy_repair = *config_.fuzzyRepair ? 1 : 0;
        settings.tone_tolerance = *config_.toneTolerance ? 1 : 0;
        settings.user_learning = *config_.userLearning ? 1 : 0;
        settings.shift_toggle = 0;
        candidateKeys_ = *config_.candidateKeys;
        settings.candidate_keys = candidateKeys_.c_str();
        settings.auto_commit_syllables = *config_.autoCommitSyllables;
        mistype_engine_set_settings(engine_, &settings);
    }
    static std::string resourcesDir() {
        const char *env = std::getenv("MISTYPE_RESOURCES");
        return env && *env ? env : MISTYPE_DATADIR;
    }

    MistypeState *stateFor(fcitx::InputContext *ic) {
        return engine_ && ic ? ic->propertyFor(&stateFactory_) : nullptr;
    }

    /// Ends the composition: optionally insert it, then clear the panel.
    void flush(fcitx::InputContextEvent &event, bool commit) {
        auto *ic = event.inputContext();
        auto *state = stateFor(ic);
        if (!state) {
            return;
        }
        // The session always drops its composition; only the insert is optional.
        if (char *text = mistype_session_commit(state->session())) {
            if (commit) {
                ic->commitString(text);
            }
            mistype_string_free(text);
            state->last.reset();
        }
        render(ic, state, state->auxShown);
    }

    mistype_key_event buildKeyEvent(const fcitx::KeyEvent &event) {
        const fcitx::Key &raw = event.rawKey();
        mistype_key_event out = {};
        out.kind = MISTYPE_KEY_OTHER;
        out.native_code = raw.code();
        out.timestamp = -1;
        out.is_release = event.isRelease() ? 1 : 0;

        // fcitx5 keycodes are evdev + 8.
        if (raw.code() > 8) {
            out.kind = mistype_key_from_evdev(raw.code() - 8, &out.label);
        }

        // Text the key types in the user's layout (case included).
        text_ = fcitx::Key::keySymToUTF8(raw.sym());
        out.text = text_.empty() ? nullptr : text_.c_str();

        uint32_t mods = 0;
        const auto states = raw.states();
        if (states.test(fcitx::KeyState::Shift)) mods |= MISTYPE_MOD_SHIFT;
        if (states.test(fcitx::KeyState::Ctrl)) mods |= MISTYPE_MOD_CONTROL;
        if (states.test(fcitx::KeyState::Alt)) mods |= MISTYPE_MOD_ALT;
        if (states.test(fcitx::KeyState::Super) || states.test(fcitx::KeyState::Super2)) mods |= MISTYPE_MOD_SUPER;
        if (states.test(fcitx::KeyState::CapsLock)) mods |= MISTYPE_MOD_CAPS_LOCK;

        // fcitx5 reports state BEFORE the event; the contract wants AFTER.
        // A modifier key's own press adds its bit and its release removes it.
        if (uint32_t own = modifierBit(raw.sym())) {
            mods = event.isRelease() ? (mods & ~own) : (mods | own);
        }

        // No usable scancode: fall back to the typed character.
        if (out.kind == MISTYPE_KEY_OTHER && out.text) {
            int32_t shifted = 0;
            out.kind = mistype_key_from_character(out.text, &out.label, &shifted);
            if (out.kind != MISTYPE_KEY_OTHER && shifted) {
                mods |= MISTYPE_MOD_SHIFT;
            }
        }
        out.modifiers = mods;
        return out;
    }

    static uint32_t modifierBit(fcitx::KeySym sym) {
        switch (sym) {
        case FcitxKey_Shift_L:
        case FcitxKey_Shift_R:
            return MISTYPE_MOD_SHIFT;
        case FcitxKey_Control_L:
        case FcitxKey_Control_R:
            return MISTYPE_MOD_CONTROL;
        case FcitxKey_Alt_L:
        case FcitxKey_Alt_R:
        case FcitxKey_Meta_L:
        case FcitxKey_Meta_R:
            return MISTYPE_MOD_ALT;
        case FcitxKey_Super_L:
        case FcitxKey_Super_R:
            return MISTYPE_MOD_SUPER;
        default:
            return 0;
        }
    }

    /// Contract §3: draw the session view; skip when nothing changed.
    void render(fcitx::InputContext *ic, MistypeState *state, bool force) {
        ViewSnapshot view;
        if (!snapshot(state->session(), view)) {
            return;
        }
        if (!force && state->last && *state->last == view) {
            return;
        }
        state->last = view;
        state->auxShown = false;

        auto &panel = ic->inputPanel();
        panel.reset(); // also clears the 中/英 indicator

        fcitx::Text preedit(view.preedit, fcitx::TextFormatFlag::Underline);
        preedit.setCursor(view.caretBytes);
        if (ic->capabilityFlags().test(fcitx::CapabilityFlag::Preedit)) {
            panel.setClientPreedit(preedit);
        } else {
            panel.setPreedit(preedit);
        }

        if (view.showsCandidates && !view.candidates.empty()) {
            auto list = std::make_unique<fcitx::CommonCandidateList>();
            list->setPageSize(kPageSize);
            // macOS parity: the candidate panel is a vertical list.
            list->setLayoutHint(fcitx::CandidateLayoutHint::Vertical);
            for (size_t i = 0; i < view.candidates.size(); ++i) {
                std::string key;
                if (view.keysActive && i < view.selectionKeys.size()) {
                    key = view.selectionKeys[i];
                }
                list->append<MistypeCandidate>(this, static_cast<int>(i), view.candidates[i], key);
            }
            // Labels are selection keys only while they pick; otherwise they type Zhuyin.
            list->setLabels(view.keysActive ? view.selectionKeys : std::vector<std::string>{});
            list->setGlobalCursorIndex(view.selected);
            panel.setCandidateList(std::move(list));
        }

        ic->updatePreedit();
        ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
    }

    mistype_engine *engine_ = nullptr;
    fcitx::FactoryFor<MistypeState> stateFactory_;
    MistypeConfig config_;
    std::string candidateKeys_; // backs settings.candidate_keys during applySettings
    std::string text_; // backs mistype_key_event::text during one keyEvent
};

void MistypeCandidate::select(fcitx::InputContext *ic) const { engine_->pick(ic, index_); }

class MistypeEngineFactory : public fcitx::AddonFactory {
public:
    fcitx::AddonInstance *create(fcitx::AddonManager *manager) override {
        return new MistypeEngine(manager->instance());
    }
};

} // namespace

FCITX_ADDON_FACTORY(MistypeEngineFactory)

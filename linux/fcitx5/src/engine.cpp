// fcitx5 adapter for Mistype (docs/cross-platform.md, docs/linux-port.md L3).
// All editing rules live in MistypeCore's InputSession behind the C ABI in
// mistype.h; this file only translates key events, applies key results and
// draws the session view.
#include <fcitx-utils/key.h>
#include <fcitx-utils/log.h>
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

/// One row of the candidate list; selecting it picks that row in the session.
class MistypeCandidate : public fcitx::CandidateWord {
public:
    MistypeCandidate(MistypeEngine *engine, int index, const std::string &text)
        : fcitx::CandidateWord(fcitx::Text(text)), engine_(engine), index_(index) {}
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
        // NULL user lexicon path: learned phrases go to $XDG_DATA_HOME/mistype.
        engine_ = mistype_engine_new(resources.c_str(), nullptr);
        if (engine_) {
            // fcitx5 owns lone Shift (AltTriggerKeys), so the session must not
            // also toggle 中/英 on a Shift tap.
            mistype_settings settings = mistype_settings_default();
            settings.shift_toggle = 0;
            mistype_engine_set_settings(engine_, &settings);
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

private:
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
            for (size_t i = 0; i < view.candidates.size(); ++i) {
                list->append<MistypeCandidate>(this, static_cast<int>(i), view.candidates[i]);
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

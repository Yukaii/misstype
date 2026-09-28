#include <fcitx-utils/log.h>
#include <fcitx-utils/standardpath.h>
#include <fcitx-utils/key.h>
#include <fcitx/instance.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/text.h>
#include <fcitx/addonmanager.h>
#include <fcitx/event.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/inputcontextproperty.h>
#include <fcitx/addonfactory.h>
#include <fcitx/inputpanel.h>
#include <fcitx/candidatelist.h>

#include <mistype.h>

#include <memory>
#include <string>

class MistypeState : public fcitx::InputContextProperty {
public:
    explicit MistypeState(mistype_engine *engine)
        : session_(mistype_session_new(engine)), lastView_(nullptr) {
    }
    ~MistypeState() override {
        if (session_) {
            mistype_session_free(session_);
        }
        if (lastView_) {
            mistype_view_free(lastView_);
        }
    }

    mistype_session *session() const { return session_; }
    mistype_view *lastView() const { return lastView_; }
    void setLastView(mistype_view *view) {
        if (lastView_) {
            mistype_view_free(lastView_);
        }
        lastView_ = view;
    }

private:
    mistype_session *session_ = nullptr;
    mistype_view *lastView_ = nullptr;
};

class MistypeEngine : public fcitx::InputMethodEngine {
public:
    explicit MistypeEngine(fcitx::Instance *instance)
        : engine_(nullptr),
          stateFactory_([this](fcitx::InputContext &) -> MistypeState * {
              return new MistypeState(engine_);
          }) {
        auto resourcesDir = getResourcesDir();
        if (resourcesDir.empty()) {
            FCITX_ERROR() << "Failed to find resources directory";
            return;
        }
        engine_ = mistype_engine_new(resourcesDir.c_str(), "");
        if (!engine_) {
            FCITX_ERROR() << "Failed to create mistype engine";
            return;
        }

        // fcitx5 owns lone-Shift via AltTriggerKeys
        mistype_settings settings = mistype_settings_default();
        settings.shift_toggle = 0;
        mistype_engine_set_settings(engine_, &settings);

        // Register per-input-context state factory
        instance->inputContextManager().registerProperty("mistype", &stateFactory_);
    }

    ~MistypeEngine() override {
        if (engine_) {
            mistype_engine_free(engine_);
        }
    }

    void keyEvent(const fcitx::InputMethodEntry &entry, fcitx::KeyEvent &event) override {
        FCITX_UNUSED(entry);
        if (!engine_) {
            return;
        }
        auto *ic = event.inputContext();
        if (!ic) {
            return;
        }
        auto *state = ic->propertyFor(&stateFactory_);
        if (!state) {
            return;
        }

        mistype_key_event keyEvent = {};
        buildKeyEvent(event, keyEvent);

        mistype_key_result result = mistype_session_handle(state->session(), &keyEvent);
        applyResult(ic, state, result);

        // Free commit string if any
        if (result.commit) {
            mistype_string_free(result.commit);
        }
    }

    void reset(const fcitx::InputMethodEntry &entry, fcitx::InputContextEvent &event) override {
        FCITX_UNUSED(entry);
        if (!engine_) {
            return;
        }
        auto *ic = event.inputContext();
        if (!ic) {
            return;
        }
        auto *state = ic->propertyFor(&stateFactory_);
        if (!state) {
            return;
        }

        char *commit = mistype_session_commit(state->session());
        if (commit) {
            ic->commitString(commit);
            mistype_string_free(commit);
        }
        render(ic, state);
    }

    void activate(const fcitx::InputMethodEntry &entry, fcitx::InputContextEvent &event) override {
        FCITX_UNUSED(entry);
        if (!engine_) {
            return;
        }
        auto *ic = event.inputContext();
        if (!ic) {
            return;
        }
        auto *state = ic->propertyFor(&stateFactory_);
        if (!state) {
            return;
        }
        mistype_session_reset_modifiers(state->session());
        render(ic, state);
    }

    void deactivate(const fcitx::InputMethodEntry &entry, fcitx::InputContextEvent &event) override {
        FCITX_UNUSED(entry);
        if (!engine_) {
            return;
        }
        auto *ic = event.inputContext();
        if (!ic) {
            return;
        }
        auto *state = ic->propertyFor(&stateFactory_);
        if (!state) {
            return;
        }

        char *commit = mistype_session_commit(state->session());
        if (commit) {
            ic->commitString(commit);
            mistype_string_free(commit);
        }
        render(ic, state);
    }

    std::vector<fcitx::InputMethodEntry> listInputMethods() override {
        std::vector<fcitx::InputMethodEntry> entries;
        entries.emplace_back("mistype", "Mistype", "zh_TW", "mistype");
        return entries;
    }

private:
    std::string getResourcesDir() {
        // Check environment variable first
        const char *env = std::getenv("MISTYPE_RESOURCES");
        if (env && *env) {
            return env;
        }
        // Fall back to compiled-in datadir
        return MISTYPE_DATADIR;
    }

    void buildKeyEvent(const fcitx::KeyEvent &event, mistype_key_event &out) {
        // fcitx5 key code is evdev + 8
        int code = event.rawKey().code();
        int evdev = (code > 8) ? code - 8 : -1;

        if (evdev >= 0) {
            const char *label = nullptr;
            out.kind = static_cast<mistype_key_kind>(mistype_key_from_evdev(evdev, &label));
            out.label = label;
        } else {
            out.kind = MISTYPE_KEY_OTHER;
            out.label = nullptr;
        }

        // Fallback to character if we got OTHER and have text
        if (out.kind == MISTYPE_KEY_OTHER) {
            auto text = event.rawKey().toString();
            if (text.size() == 1) {
                int32_t shifted = 0;
                const char *label = nullptr;
                out.kind = static_cast<mistype_key_kind>(mistype_key_from_character(text.c_str(), &label, &shifted));
                if (out.kind != MISTYPE_KEY_OTHER) {
                    out.label = label;
                }
                // Add shift modifier if the character needed it
                if (shifted) {
                    out.modifiers |= MISTYPE_MOD_SHIFT;
                }
            }
        }

        // Text the key types in user's layout
        auto text = event.rawKey().toString();
        out.text = text.empty() ? nullptr : strdup(text.c_str());

        // Modifiers (fcitx5 reports state BEFORE event, correct for Shift)
        uint32_t mods = 0;
        auto keyStates = event.rawKey().states();
        if (keyStates.test(fcitx::KeyState::Shift)) mods |= MISTYPE_MOD_SHIFT;
        if (keyStates.test(fcitx::KeyState::Ctrl)) mods |= MISTYPE_MOD_CONTROL;
        if (keyStates.test(fcitx::KeyState::Alt)) mods |= MISTYPE_MOD_ALT;
        if (keyStates.test(fcitx::KeyState::Super)) mods |= MISTYPE_MOD_SUPER;
        if (keyStates.test(fcitx::KeyState::CapsLock)) mods |= MISTYPE_MOD_CAPS_LOCK;

        // Correct Shift keys: press adds Shift, release removes it
        auto sym = event.rawKey().sym();
        if (sym == FcitxKey_Shift_L || sym == FcitxKey_Shift_R) {
            if (event.isRelease()) {
                mods &= ~MISTYPE_MOD_SHIFT;
            } else {
                mods |= MISTYPE_MOD_SHIFT;
            }
        }

        out.modifiers = mods;
        out.is_release = event.isRelease() ? 1 : 0;
        out.native_code = code;
        out.timestamp = -1;
    }

    void applyResult(fcitx::InputContext *ic, MistypeState *state, const mistype_key_result &result) {
        // If commit, insert it
        if (result.commit) {
            ic->commitString(result.commit);
        }

        // Render new view
        render(ic, state);

        // If modeChanged, show 中/英 indicator
        if (result.mode_changed) {
            bool english = mistype_engine_is_english(engine_) != 0;
            ic->inputPanel().setAuxUp(fcitx::Text(english ? "英" : "中"));
        }
    }

    void render(fcitx::InputContext *ic, MistypeState *state) {
        mistype_view *view = mistype_session_view(state->session());
        if (!view) {
            return;
        }

        // Skip if view unchanged
        if (state->lastView() && viewsEqual(state->lastView(), view)) {
            mistype_view_free(view);
            return;
        }
        state->setLastView(view);

        // Preedit
        fcitx::Text text(view->preedit);
        text.setCursor(view->caret_bytes);
        ic->inputPanel().setPreedit(text);

        ic->updatePreedit();
        ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
    }

    bool viewsEqual(const mistype_view *a, const mistype_view *b) {
        if (a->caret_bytes != b->caret_bytes ||
            a->caret_utf16 != b->caret_utf16 ||
            a->candidate_count != b->candidate_count ||
            a->selected != b->selected ||
            a->keys_active != b->keys_active ||
            a->shows_candidates != b->shows_candidates ||
            a->selection_key_count != b->selection_key_count) {
            return false;
        }
        if (strcmp(a->preedit, b->preedit) != 0) return false;
        for (int i = 0; i < a->candidate_count; ++i) {
            if (strcmp(a->candidates[i], b->candidates[i]) != 0) return false;
        }
        for (int i = 0; i < a->selection_key_count; ++i) {
            if (strcmp(a->selection_keys[i], b->selection_keys[i]) != 0) return false;
        }
        return true;
    }

    mistype_engine *engine_ = nullptr;
    fcitx::FactoryFor<MistypeState> stateFactory_;
};

class MistypeEngineFactory : public fcitx::AddonFactory {
public:
    fcitx::AddonInstance *create(fcitx::AddonManager *manager) override {
        return new MistypeEngine(manager->instance());
    }
};

static MistypeEngineFactory g_factory;

extern "C" FCITXCORE_EXPORT fcitx::AddonFactory *fcitx_addon_factory_instance() {
    return &g_factory;
}
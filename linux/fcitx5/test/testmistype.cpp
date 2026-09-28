#include <fcitx-utils/log.h>
#include <fcitx-utils/standardpath.h>
#include <fcitx/instance.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx-utils/key.h>
#include <fcitx/event.h>
#include <fcitx/addonmanager.h>
#include <fcitx-utils/testing.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>

#define PASS(id) FCITX_INFO() << "PASS " << id

// Helper to send a key event
static void sendKey(fcitx::ITestFrontend *frontend, const char *sym, fcitx::KeyStates states, int evdev) {
    fcitx::Key key(sym, states, evdev + 8);
    frontend->sendKeyEvent(key, false);
}

// Helper to send a key release
static void sendKeyRelease(fcitx::ITestFrontend *frontend, const char *sym, fcitx::KeyStates states, int evdev) {
    fcitx::Key key(sym, states, evdev + 8);
    frontend->sendKeyEvent(key, true);
}

static void expectCommit(fcitx::ITestFrontend *frontend, const char *expected) {
    frontend->pushCommitExpectation(expected);
}

static void checkPreedit(fcitx::ITestFrontend *frontend, const char *expected) {
    auto *ic = frontend->inputContext();
    std::string preedit = ic->inputPanel().preedit().toString();
    if (preedit != expected) {
        FCITX_ERROR() << "Preedit mismatch: expected '" << expected << "' got '" << preedit << "'";
        std::exit(1);
    }
}

static void checkCaret(fcitx::ITestFrontend *frontend, int expectedBytes, int expectedUtf16) {
    auto *ic = frontend->inputContext();
    if (ic->inputPanel().preedit().cursor() != expectedBytes) {
        FCITX_ERROR() << "Caret bytes mismatch: expected " << expectedBytes << " got " << ic->inputPanel().preedit().cursor();
        std::exit(1);
    }
}

static void checkCandidates(fcitx::ITestFrontend *frontend, int expectedCount, int expectedSelected, bool expectedKeysActive) {
    auto *ic = frontend->inputContext();
    auto *list = ic->inputPanel().candidateList();
    if (!list) {
        FCITX_ERROR() << "No candidate list";
        std::exit(1);
    }
    if (list->candidateCount() != expectedCount) {
        FCITX_ERROR() << "Candidate count mismatch: expected " << expectedCount << " got " << list->candidateCount();
        std::exit(1);
    }
    if (list->cursorPosition() != expectedSelected) {
        FCITX_ERROR() << "Candidate selected mismatch: expected " << expectedSelected << " got " << list->cursorPosition();
        std::exit(1);
    }
}

int main(int argc, char **argv) {
    fcitx::setupTestingEnvironment(TESTING_BINARY_DIR, {"src"},
                                   {TESTING_BINARY_DIR "/data", TESTING_SOURCE_DIR "/data"});

    fcitx::Instance instance(fcitx::Instance::CreateArgs()
                                 .setDisableAll(true)
                                 .setEnable("testim", "testfrontend", "mistype", "testui"));

    instance.addonManager().registerDefaultLoader(nullptr);

    fcitx::EventDispatcher dispatcher;
    dispatcher.schedule([&]() {
        auto *frontend = instance.testFrontend();
        if (!frontend) {
            FCITX_ERROR() << "No test frontend";
            std::exit(1);
        }

        // Create input context
        auto *ic = frontend->createInputContext();
        frontend->focusIn(ic);
        ic->setCapabilityFlags(fcitx::CapabilityFlag::Preedit);
        instance.setCurrentInputMethod(ic, "mistype", false);

        auto checkFiltered = [&](const char *desc, bool shouldFilter) {
            bool filtered = frontend->sendKeyEvent(fcitx::Key("a", {}, 38), false);
            if (filtered != shouldFilter) {
                FCITX_ERROR() << desc << ": expected filter=" << shouldFilter << " got " << filtered;
                std::exit(1);
            }
        };

        // C1: su3cl3 then Enter
        {
            sendKey(frontend, "s", {}, 31);
            sendKey(frontend, "u", {}, 30);
            sendKey(frontend, "3", {}, 4);
            sendKey(frontend, "c", {}, 46);
            sendKey(frontend, "l", {}, 37);
            sendKey(frontend, "3", {}, 4);

            checkPreedit(frontend, "你好");
            checkCaret(frontend, 6, 2);
            checkCandidates(frontend, 10, 0, false);

            expectCommit(frontend, "你好");
            sendKey(frontend, "Return", {}, 28);
            PASS("C1");
        }

        // C2: empty: Enter, Backspace, Left; then Space
        {
            frontend->reset();

            expectCommit(frontend, "");
            sendKey(frontend, "Return", {}, 28);
            checkFiltered("C2 enter pass", false);

            sendKey(frontend, "BackSpace", {}, 14);
            checkFiltered("C2 backspace pass", false);

            sendKey(frontend, "Left", {}, 105);
            checkFiltered("C2 left pass", false);

            expectCommit(frontend, " ");
            sendKey(frontend, "space", {}, 57);
            checkFiltered("C2 space commit", true);
            PASS("C2");
        }

        // C3: su3cl3, Backspace
        {
            frontend->reset();
            sendKey(frontend, "s", {}, 31);
            sendKey(frontend, "u", {}, 30);
            sendKey(frontend, "3", {}, 4);
            sendKey(frontend, "c", {}, 46);
            sendKey(frontend, "l", {}, 37);
            sendKey(frontend, "3", {}, 4);
            checkPreedit(frontend, "你好");

            sendKey(frontend, "BackSpace", {}, 14);
            checkPreedit(frontend, "你");
            PASS("C3");
        }

        // C4: su3, Tab, d, Enter
        {
            frontend->reset();
            sendKey(frontend, "s", {}, 31);
            sendKey(frontend, "u", {}, 30);
            sendKey(frontend, "3", {}, 4);

            checkCandidates(frontend, 5, 0, false);

            sendKey(frontend, "Tab", {}, 15);
            checkCandidates(frontend, 5, 1, true);

            // d selects row 2 (0-indexed: 1)
            sendKey(frontend, "d", {}, 32);
            checkPreedit(frontend, "尼");
            checkCandidates(frontend, 5, 1, false);

            expectCommit(frontend, "尼");
            sendKey(frontend, "Return", {}, 28);
            PASS("C4");
        }

        // C5: su3, Down, Esc, Esc
        {
            frontend->reset();
            sendKey(frontend, "s", {}, 31);
            sendKey(frontend, "u", {}, 30);
            sendKey(frontend, "3", {}, 4);

            sendKey(frontend, "Down", {}, 108);
            checkPreedit(frontend, "妳");

            sendKey(frontend, "Escape", {}, 1);
            checkPreedit(frontend, "妳");

            sendKey(frontend, "Escape", {}, 1);
            checkPreedit(frontend, "");
            PASS("C5");
        }

        // C6: su3, Shift+,, Shift+a, Enter
        {
            frontend->reset();
            sendKey(frontend, "s", {}, 31);
            sendKey(frontend, "u", {}, 30);
            sendKey(frontend, "3", {}, 4);
            checkPreedit(frontend, "你");

            sendKey(frontend, ",", {fcitx::KeyState::Shift}, 51);
            checkPreedit(frontend, "你，");

            sendKey(frontend, "a", {fcitx::KeyState::Shift}, 38);
            checkPreedit(frontend, "你，A");

            expectCommit(frontend, "你，A");
            sendKey(frontend, "Return", {}, 28);
            PASS("C6");
        }

        // C7: su3, backtick, h i
        {
            frontend->reset();
            sendKey(frontend, "s", {}, 31);
            sendKey(frontend, "u", {}, 30);
            sendKey(frontend, "3", {}, 4);
            checkPreedit(frontend, "你");

            sendKey(frontend, "`", {}, 49);
            sendKey(frontend, "h", {}, 35);
            sendKey(frontend, "i", {}, 23);
            checkPreedit(frontend, "你hi");
            PASS("C7");
        }

        // C8: su3cl3, Right, Left
        {
            frontend->reset();
            sendKey(frontend, "s", {}, 31);
            sendKey(frontend, "u", {}, 30);
            sendKey(frontend, "3", {}, 4);
            sendKey(frontend, "c", {}, 46);
            sendKey(frontend, "l", {}, 37);
            sendKey(frontend, "3", {}, 4);

            // Right beeps, no change
            sendKey(frontend, "Right", {}, 106);
            checkPreedit(frontend, "你好");

            // Left enters cursor mode
            sendKey(frontend, "Left", {}, 105);
            checkPreedit(frontend, "你好");
            checkCaret(frontend, 3, 1);
            checkCandidates(frontend, 10, 0, true);
            PASS("C8");
        }

        // C9: su3, Ctrl+C
        {
            frontend->reset();
            sendKey(frontend, "s", {}, 31);
            sendKey(frontend, "u", {}, 30);
            sendKey(frontend, "3", {}, 4);

            expectCommit(frontend, "你");
            // Ctrl+C: send 'c' with Control modifier
            sendKey(frontend, "c", {fcitx::KeyState::Ctrl}, 46);
            checkFiltered("C9 ctrl-c pass", false);
            PASS("C9");
        }

        // C10: su3, Shift+Space, s
        {
            frontend->reset();
            sendKey(frontend, "s", {}, 31);
            sendKey(frontend, "u", {}, 30);
            sendKey(frontend, "3", {}, 4);

            expectCommit(frontend, "你");
            sendKey(frontend, "space", {fcitx::KeyState::Shift}, 57);
            checkFiltered("C10 shift-space commit", true);

            // Check English mode
            // Send 's' - should pass through
            checkFiltered("C10 s pass", false);
            PASS("C10");
        }

        // C11: su3, focus out
        {
            frontend->reset();
            sendKey(frontend, "s", {}, 31);
            sendKey(frontend, "u", {}, 30);
            sendKey(frontend, "3", {}, 4);

            expectCommit(frontend, "你");
            ic->focusOut();
            PASS("C11");
        }

        // C12: su3, click row 3
        {
            frontend->reset();
            sendKey(frontend, "s", {}, 31);
            sendKey(frontend, "u", {}, 30);
            sendKey(frontend, "3", {}, 4);

            // Select candidate at index 3
            auto *list = ic->inputPanel().candidateList();
            if (list && list->candidateCount() > 3) {
                list->candidateAt(3)->select();
            }
            checkPreedit(frontend, "泥");
            PASS("C12");
        }

        // LR1: Key release never filtered
        {
            frontend->reset();
            sendKeyRelease(frontend, "a", {}, 38);
            checkFiltered("LR1 release not filtered", false);
            PASS("LR1");
        }

        // LR2: Bare Control_L press not filtered, preedit unchanged
        {
            frontend->reset();
            sendKey(frontend, "s", {}, 31);
            sendKey(frontend, "u", {}, 30);
            sendKey(frontend, "3", {}, 4);
            checkPreedit(frontend, "你");

            sendKey(frontend, "Control_L", {}, 29);
            checkFiltered("LR2 ctrl press not filtered", false);
            checkPreedit(frontend, "你");
            PASS("LR2");
        }

        // LR3: Without Preedit capability, preedit goes to panel
        {
            frontend->reset();
            ic->setCapabilityFlags(fcitx::CapabilityFlag::None);
            sendKey(frontend, "s", {}, 31);
            sendKey(frontend, "u", {}, 30);
            sendKey(frontend, "3", {}, 4);

            std::string panelPreedit = ic->inputPanel().preedit().toString();
            if (panelPreedit != "你") {
                FCITX_ERROR() << "LR3 panel preedit mismatch: expected '你' got '" << panelPreedit << "'";
                std::exit(1);
            }
            if (ic->inputPanel().preedit().toString() != "") {
                FCITX_ERROR() << "LR3 client preedit should be empty";
                std::exit(1);
            }
            PASS("LR3");
        }

        // LR4: Lone Shift_L tap switches to keyboard-us
        {
            frontend->reset();
            // Need to send press and release with pre-event states (X11 semantics)
            // Press: no modifiers before
            frontend->sendKeyEvent(fcitx::Key("Shift_L", {}, 50), false);
            // Release: Shift modifier before release
            frontend->sendKeyEvent(fcitx::Key("Shift_L", {fcitx::KeyState::Shift}, 50), true);

            // Check IC switched to keyboard-us
            std::string currentIM = instance.currentInputMethod();
            if (currentIM != "keyboard-us") {
                FCITX_ERROR() << "LR4: expected keyboard-us, got " << currentIM;
                std::exit(1);
            }
            PASS("LR4");
        }

        FCITX_INFO() << "All tests passed";
        instance.exit(0);
    });

    instance.exec();
    return 0;
}
// Headless conformance tests for the fcitx5 adapter: docs/cross-platform.md
// scenarios C1-C13 plus the Linux delivery rules LR1-LR4, driven through
// fcitx5's in-process test frontend. A wrong commit aborts inside
// pushCommitExpectation; every other check is FCITX_ASSERT.
#include <fcitx-utils/eventdispatcher.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/log.h>
#include <fcitx-utils/testing.h>
#include <fcitx/addonmanager.h>
#include <fcitx/candidatelist.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputmethodgroup.h>
#include <fcitx/inputmethodmanager.h>
#include <fcitx/inputpanel.h>
#include <fcitx/instance.h>
#include <testfrontend_public.h>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>

using namespace fcitx;

namespace {

struct PhysicalKey {
    KeySym sym;
    int evdev;
};

// US-ANSI physical keys by unshifted label; evdev codes from linux/input-event-codes.h.
PhysicalKey physical(char c) {
    static const std::string rows[] = {"qwertyuiop", "asdfghjkl", "zxcvbnm", "1234567890"};
    static const int starts[] = {16, 30, 44, 2};
    for (int r = 0; r < 4; ++r) {
        auto pos = rows[r].find(c);
        if (pos != std::string::npos) {
            return {static_cast<KeySym>(c), starts[r] + static_cast<int>(pos)};
        }
    }
    switch (c) {
    case ';': return {FcitxKey_semicolon, 39};
    case '`': return {FcitxKey_grave, 41};
    case ',': return {FcitxKey_comma, 51};
    }
    FCITX_ASSERT(false) << "no physical key for " << c;
    return {};
}

constexpr int kEnter = 28, kBackspace = 14, kTab = 15, kEsc = 1, kLeft = 105, kRight = 106, kDown = 108,
              kSpace = 57, kShiftL = 42, kCtrlL = 29;

class Session {
public:
    explicit Session(Instance &instance) : instance_(instance) {
        frontend_ = instance.addonManager().addon("testfrontend");
        FCITX_ASSERT(frontend_) << "testfrontend addon not loaded";
        auto &imm = instance.inputMethodManager();
        InputMethodGroup group("Default");
        group.inputMethodList().emplace_back("keyboard-us");
        group.inputMethodList().emplace_back("mistype");
        group.setDefaultInputMethod("mistype");
        imm.setGroup(std::move(group));
        uuid_ = frontend_->call<ITestFrontend::createInputContext>("testapp");
        ic_ = instance.inputContextManager().findByUUID(uuid_);
        FCITX_ASSERT(ic_);
        ic_->setCapabilityFlags(CapabilityFlag::Preedit);
        ic_->focusIn();
        instance.setCurrentInputMethod(ic_, "mistype", true);
        FCITX_ASSERT(instance.inputMethod(ic_) == "mistype") << "mistype input method not active";
    }

    InputContext *ic() { return ic_; }

    /// Returns whether fcitx5 considers the key filtered (swallowed by the IM).
    bool key(KeySym sym, int evdev, KeyStates states = KeyStates(), bool release = false) {
        return frontend_->call<ITestFrontend::sendKeyEvent>(uuid_, Key(sym, states, evdev + 8), release);
    }

    /// Types unshifted physical keys; every one must be swallowed.
    void type(const std::string &keys) {
        for (char c : keys) {
            auto k = physical(c);
            FCITX_ASSERT(key(k.sym, k.evdev)) << "key '" << c << "' should be swallowed";
        }
    }

    void expectCommit(const std::string &text) { frontend_->call<ITestFrontend::pushCommitExpectation>(text); }

    std::string preedit() { return ic_->inputPanel().clientPreedit().toString(); }
    int caretBytes() { return ic_->inputPanel().clientPreedit().cursor(); }
    std::string aux() { return ic_->inputPanel().auxUp().toString(); }

    CommonCandidateList *candidates() {
        return dynamic_cast<CommonCandidateList *>(ic_->inputPanel().candidateList().get());
    }

    /// Ends whatever composition is left (Escape leaves selection, then clears).
    void clear() {
        for (int i = 0; i < 3; ++i) {
            key(FcitxKey_Escape, kEsc);
        }
        FCITX_ASSERT(preedit().empty()) << "composition not cleared: " << preedit();
        FCITX_ASSERT(!candidates()) << "candidate list not cleared";
    }

private:
    Instance &instance_;
    AddonInstance *frontend_ = nullptr;
    ICUUID uuid_;
    InputContext *ic_ = nullptr;
};

void pass(const char *id) { FCITX_INFO() << "PASS " << id; }

void runAll(Instance &instance) {
    Session s(instance);
    auto &ic = *s.ic();
    const KeyStates shift(KeyState::Shift), ctrl(KeyState::Ctrl);

    // C1: su3cl3, then Enter commits the preview.
    s.type("su3cl3");
    FCITX_ASSERT(s.preedit() == "你好") << s.preedit();
    FCITX_ASSERT(s.caretBytes() == 6);
    {
        auto *list = s.candidates();
        FCITX_ASSERT(list);
        FCITX_ASSERT(list->totalSize() == 10);
        FCITX_ASSERT(list->pageSize() == 8 && list->totalPages() == 2) << "8 rows per page";
        FCITX_ASSERT(list->globalCursorIndex() == 0);
        FCITX_ASSERT(list->label(0).toString().empty()) << "selection keys type Zhuyin, so no labels";
    }
    s.expectCommit("你好");
    FCITX_ASSERT(s.key(FcitxKey_Return, kEnter));
    FCITX_ASSERT(s.preedit().empty() && !s.candidates());
    pass("C1");

    // C2: empty composition passes Enter/Backspace/Left; Space commits " ".
    FCITX_ASSERT(!s.key(FcitxKey_Return, kEnter));
    FCITX_ASSERT(!s.key(FcitxKey_BackSpace, kBackspace));
    FCITX_ASSERT(!s.key(FcitxKey_Left, kLeft));
    s.expectCommit(" ");
    FCITX_ASSERT(s.key(FcitxKey_space, kSpace));
    pass("C2");

    // C3: Backspace edits without committing.
    s.type("su3cl3");
    FCITX_ASSERT(s.key(FcitxKey_BackSpace, kBackspace));
    FCITX_ASSERT(s.preedit() == "你") << s.preedit();
    s.clear();
    pass("C3");

    // C5: Down selects 妳; first Esc leaves selection, second clears.
    s.type("su3");
    FCITX_ASSERT(s.key(FcitxKey_Down, kDown));
    FCITX_ASSERT(s.preedit() == "妳") << s.preedit();
    FCITX_ASSERT(s.key(FcitxKey_Escape, kEsc));
    FCITX_ASSERT(s.preedit() == "妳");
    FCITX_ASSERT(s.key(FcitxKey_Escape, kEsc));
    FCITX_ASSERT(s.preedit().empty());
    pass("C5");

    // C6: Shift+, and Shift+a stay inside the composition.
    s.type("su3");
    FCITX_ASSERT(s.key(FcitxKey_less, physical(',').evdev, shift));
    FCITX_ASSERT(s.preedit() == "你，") << s.preedit();
    FCITX_ASSERT(s.key(FcitxKey_A, physical('a').evdev, shift));
    FCITX_ASSERT(s.preedit() == "你，A") << s.preedit();
    s.expectCommit("你，A");
    FCITX_ASSERT(s.key(FcitxKey_Return, kEnter));
    pass("C6");

    // C7: backtick starts a Latin run.
    s.type("su3`hi");
    FCITX_ASSERT(s.preedit() == "你hi") << s.preedit();
    s.clear();
    pass("C7");

    // C8: Right at the end beeps (consumed, no change); Left focuses a word.
    s.type("su3cl3");
    FCITX_ASSERT(s.key(FcitxKey_Right, kRight));
    FCITX_ASSERT(s.preedit() == "你好");
    FCITX_ASSERT(s.key(FcitxKey_Left, kLeft));
    FCITX_ASSERT(s.preedit() == "你好" && s.caretBytes() == 3) << s.caretBytes();
    {
        auto *list = s.candidates();
        FCITX_ASSERT(list && list->candidateFromAll(0).text().toString() == "你好");
        FCITX_ASSERT(list->label(0).toString() == "a") << "selection keys active in cursor mode";
    }
    s.clear();
    pass("C8");

    // C9: Ctrl+c commits the preview, then the shortcut reaches the application.
    s.type("su3");
    s.expectCommit("你");
    FCITX_ASSERT(!s.key(FcitxKey_c, physical('c').evdev, ctrl));
    FCITX_ASSERT(s.preedit().empty());
    pass("C9");

    // C10: Shift+Space commits, flips to English (indicator), and letters pass.
    s.type("su3");
    s.expectCommit("你");
    FCITX_ASSERT(s.key(FcitxKey_space, kSpace, shift));
    FCITX_ASSERT(s.aux() == "英") << "mode indicator: " << s.aux();
    FCITX_ASSERT(!s.key(FcitxKey_s, physical('s').evdev)) << "English mode passes letters";
    FCITX_ASSERT(s.aux().empty()) << "next render clears the indicator";
    FCITX_ASSERT(s.key(FcitxKey_space, kSpace, shift));
    FCITX_ASSERT(s.aux() == "中");
    s.type("su3"); // Chinese again, as after the toggle above
    s.clear();
    pass("C10");

    // C11: focus out commits the composition exactly once. With client-side
    // preedit fcitx5 itself inserts the preedit; the engine must not add a
    // second copy but must still clear its session.
    s.clear();
    s.type("su3");
    s.expectCommit("你");
    ic.focusOut();
    ic.focusIn();
    FCITX_ASSERT(s.preedit().empty() && !s.candidates());
    FCITX_ASSERT(s.key(FcitxKey_Return, kEnter) == false) << "session must be empty after focus out";
    // Without client preedit nobody else inserts the text: the engine does.
    ic.setCapabilityFlags(CapabilityFlags());
    s.type("su3");
    s.expectCommit("你");
    ic.focusOut();
    ic.focusIn();
    ic.setCapabilityFlags(CapabilityFlag::Preedit);
    // Switching input method commits too (fcitx5 does not do it for us).
    s.type("su3");
    s.expectCommit("你");
    instance.setCurrentInputMethod(&ic, "keyboard-us", true);
    instance.setCurrentInputMethod(&ic, "mistype", true);
    FCITX_ASSERT(s.preedit().empty());
    pass("C11");

    // C12: picking row 3 (a click) replaces the preview with 泥.
    s.type("su3");
    {
        auto *list = s.candidates();
        FCITX_ASSERT(list && list->totalSize() == 5);
        list->candidateFromAll(3).select(&ic);
    }
    FCITX_ASSERT(s.preedit() == "泥") << s.preedit();
    s.clear();
    pass("C12");

    // LR1: a key release is never filtered and changes nothing.
    s.type("su3");
    FCITX_ASSERT(!s.key(FcitxKey_s, physical('s').evdev, KeyStates(), /*release=*/true));
    FCITX_ASSERT(s.preedit() == "你");
    pass("LR1");

    // LR2: a bare Control press is not filtered and leaves the preedit alone.
    FCITX_ASSERT(!s.key(FcitxKey_Control_L, kCtrlL));
    FCITX_ASSERT(s.preedit() == "你");
    FCITX_ASSERT(!s.key(FcitxKey_Control_L, kCtrlL, ctrl, /*release=*/true));
    FCITX_ASSERT(s.preedit() == "你");
    pass("LR2");

    // LR3: without client-side preedit the composition goes to the panel.
    s.clear();
    ic.setCapabilityFlags(CapabilityFlags());
    s.type("su3");
    FCITX_ASSERT(ic.inputPanel().preedit().toString() == "你") << ic.inputPanel().preedit().toString();
    FCITX_ASSERT(s.preedit().empty()) << "client preedit must stay empty";
    s.clear();
    ic.setCapabilityFlags(CapabilityFlag::Preedit);
    pass("LR3");

    // LR4: a lone Shift_L tap belongs to fcitx5 (AltTriggerKeys): it switches
    // input method and does not flip Mistype's own 中/英 state.
    FCITX_ASSERT(!s.key(FcitxKey_Shift_L, kShiftL));
    s.key(FcitxKey_Shift_L, kShiftL, shift, /*release=*/true);
    FCITX_ASSERT(instance.inputMethod(&ic) == "keyboard-us") << instance.inputMethod(&ic);
    instance.setCurrentInputMethod(&ic, "mistype", true);
    s.type("su3");
    FCITX_ASSERT(s.preedit() == "你") << "still Chinese after the fcitx5 Shift switch";
    s.expectCommit("你");
    ic.focusOut();
    pass("LR4");

    // C13: Shift+Left x2 marks 你好 (highlighted, hint under the preedit);
    // Enter files it in the user dictionary without committing.
    ic.focusIn();
    s.type("su3cl3");
    FCITX_ASSERT(s.key(FcitxKey_Left, kLeft, shift));
    FCITX_ASSERT(s.key(FcitxKey_Left, kLeft, shift));
    {
        const auto &text = ic.inputPanel().clientPreedit();
        FCITX_ASSERT(text.toString() == "你好") << text.toString();
        std::string highlighted;
        for (size_t i = 0; i < text.size(); ++i) {
            if (text.formatAt(i).test(TextFormatFlag::HighLight)) highlighted += text.stringAt(i);
        }
        FCITX_ASSERT(highlighted == "你好") << "marked span is highlighted: " << highlighted;
        FCITX_ASSERT(ic.inputPanel().auxDown().toString() == "⏎ add \"你好\"  ㄋㄧˇ-ㄏㄠˇ")
            << ic.inputPanel().auxDown().toString();
        FCITX_ASSERT(!s.candidates()) << "the hint replaces the candidate list";
    }
    FCITX_ASSERT(s.key(FcitxKey_Return, kEnter));
    FCITX_ASSERT(s.preedit() == "你好" && ic.inputPanel().auxDown().toString().empty());
    {
        std::ifstream file(std::string(TESTING_BINARY_DIR) + "/xdg-data/mistype/user_dictionary.tsv");
        std::string saved((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        FCITX_ASSERT(saved.find("ㄋㄧˇ-ㄏㄠˇ\t你好") != std::string::npos) << "dictionary not persisted: " << saved;
    }
    s.clear();
    pass("C13");

    // C4 runs last: committing 尼 teaches the user lexicon, which would
    // reorder the candidates every other scenario expects.
    // C4: Tab selects, a selection key picks row 2 (尼), Enter commits it.
    ic.focusIn();
    s.type("su3");
    {
        auto *list = s.candidates();
        FCITX_ASSERT(list && list->totalSize() == 5 && list->globalCursorIndex() == 0);
    }
    FCITX_ASSERT(s.key(FcitxKey_Tab, kTab));
    {
        auto *list = s.candidates();
        FCITX_ASSERT(list && list->globalCursorIndex() == 1);
        FCITX_ASSERT(list->label(0).toString() == "a" && list->label(1).toString() == "s")
            << "labels are the selection keys while they pick";
    }
    FCITX_ASSERT(s.key(FcitxKey_d, 32));
    FCITX_ASSERT(s.preedit() == "尼") << s.preedit();
    s.expectCommit("尼");
    FCITX_ASSERT(s.key(FcitxKey_Return, kEnter));
    pass("C4");
}

} // namespace

int main() {
    // Learned phrases (C4) must not touch the developer's home, and every run
    // must start from an empty user lexicon.
    const std::string xdg = TESTING_BINARY_DIR "/xdg-data";
    std::filesystem::remove_all(xdg);
    setenv("XDG_DATA_HOME", xdg.c_str(), 1);
    setupTestingEnvironment(TESTING_BINARY_DIR, {"src", FCITX_TESTING_ADDONDIR},
                            {TESTING_BINARY_DIR "/data", FCITX_TESTING_DATADIR});

    char arg0[] = "testmistype";
    char arg1[] = "--disable=all";
    char arg2[] = "--enable=testim,testfrontend,mistype,testui";
    char *argv[] = {arg0, arg1, arg2};
    Instance instance(3, argv);
    instance.addonManager().registerDefaultLoader(nullptr);

    EventDispatcher dispatcher;
    dispatcher.attach(&instance.eventLoop());
    dispatcher.schedule([&instance]() {
        runAll(instance);
        FCITX_INFO() << "All 17 scenarios passed";
        instance.exit();
    });
    instance.exec();
    return 0;
}

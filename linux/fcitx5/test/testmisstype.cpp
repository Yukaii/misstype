// Headless conformance tests for the fcitx5 adapter: docs/cross-platform.md
// scenarios C1-C15 plus the Linux delivery rules LR1-LR8, driven through
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

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <thread>

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
        group.inputMethodList().emplace_back("misstype");
        group.setDefaultInputMethod("misstype");
        imm.setGroup(std::move(group));
        uuid_ = frontend_->call<ITestFrontend::createInputContext>("testapp");
        ic_ = instance.inputContextManager().findByUUID(uuid_);
        FCITX_ASSERT(ic_);
        ic_->setCapabilityFlags(CapabilityFlag::Preedit);
        ic_->focusIn();
        instance.setCurrentInputMethod(ic_, "misstype", true);
        FCITX_ASSERT(instance.inputMethod(ic_) == "misstype") << "misstype input method not active";
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
    const KeyStates shift(KeyState::Shift), ctrl(KeyState::Ctrl), alt(KeyState::Alt);
    auto *addon = instance.addonManager().addon("misstype");
    FCITX_ASSERT(addon && addon->getConfig()) << "addon exposes a config";

    // LR6: the settings page defaults follow macOS (MisstypePrefs).
    {
        RawConfig defaults;
        addon->getConfig()->save(defaults);
        auto expect = [&](const char *key, const char *value) {
            const auto *stored = defaults.valueByPath(key);
            FCITX_ASSERT(stored && *stored == value) << key << " defaults to " << (stored ? *stored : "(none)");
        };
        expect("RepairStrength", "Standard");
        expect("ChannelLearning", "False");
        expect("MixedEnglish", "False");
        expect("AutoShowCandidates", "False");
        expect("ReturnConfirmsSelection", "True");
        expect("CandidatesPerPage", "8");
        expect("CursorCandidates", "Covering");
        pass("LR6");
    }
    // The conformance scenarios assume the core's defaults, not the page's.
    {
        RawConfig core;
        core.setValueByPath("MixedEnglish", "True");
        core.setValueByPath("AutoShowCandidates", "True");
        core.setValueByPath("ReturnConfirmsSelection", "False");
        addon->setConfig(core);
    }

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
    // Escape wipes the text but the run stays open (the user is still typing
    // English); the toggle closes it so the next scenario types Zhuyin.
    s.type("ok");
    FCITX_ASSERT(s.preedit() == "ok") << "run survives Escape: " << s.preedit();
    s.clear();
    s.type("`");
    pass("C7");

    // C8: Right at the end beeps (consumed, no change); Left focuses a word
    // without arming the selection keys (they type at the cursor); Tab arms.
    s.type("su3cl3");
    FCITX_ASSERT(s.key(FcitxKey_Right, kRight));
    FCITX_ASSERT(s.preedit() == "你好");
    FCITX_ASSERT(s.key(FcitxKey_Left, kLeft));
    FCITX_ASSERT(s.preedit() == "你好" && s.caretBytes() == 3) << s.caretBytes();
    {
        auto *list = s.candidates();
        FCITX_ASSERT(list && list->candidateFromAll(0).text().toString() == "你好");
        FCITX_ASSERT(list->label(0).toString().empty()) << "selection keys type at the cursor";
    }
    FCITX_ASSERT(s.key(FcitxKey_Tab, kTab));
    {
        auto *list = s.candidates();
        FCITX_ASSERT(list && list->label(0).toString() == "a") << "Tab arms the selection keys";
    }
    s.clear();
    pass("C8");

    // C14: typing at the syllable cursor inserts there.
    s.type("su3a87");
    FCITX_ASSERT(s.preedit() == "你嗎") << s.preedit();
    FCITX_ASSERT(s.key(FcitxKey_Left, kLeft));
    s.type("cl3");
    FCITX_ASSERT(s.preedit() == "你好嗎" && s.caretBytes() == 6) << s.preedit() << " " << s.caretBytes();
    s.clear();
    pass("C14");

    // C15: in a Latin run Alt+Backspace deletes a word, Alt+Left jumps one
    // and typing follows the caret.
    s.type("su3`hello");
    FCITX_ASSERT(s.key(FcitxKey_space, kSpace));
    s.type("world");
    FCITX_ASSERT(s.key(FcitxKey_BackSpace, kBackspace, alt));
    FCITX_ASSERT(s.preedit() == "你hello ") << s.preedit();
    s.type("world");
    FCITX_ASSERT(s.key(FcitxKey_Left, kLeft, alt));
    FCITX_ASSERT(s.caretBytes() == 9) << s.caretBytes();
    s.type("big");
    FCITX_ASSERT(s.key(FcitxKey_space, kSpace));
    FCITX_ASSERT(s.preedit() == "你hello big world" && s.caretBytes() == 13) << s.preedit();
    s.clear();
    s.type("`"); // close the run (it survives Escape)
    pass("C15");

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
    instance.setCurrentInputMethod(&ic, "misstype", true);
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
    // input method and does not flip Misstype's own 中/英 state.
    FCITX_ASSERT(!s.key(FcitxKey_Shift_L, kShiftL));
    s.key(FcitxKey_Shift_L, kShiftL, shift, /*release=*/true);
    FCITX_ASSERT(instance.inputMethod(&ic) == "keyboard-us") << instance.inputMethod(&ic);
    instance.setCurrentInputMethod(&ic, "misstype", true);
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
        std::ifstream file(std::string(TESTING_BINARY_DIR) + "/xdg-data/misstype/user_dictionary.tsv");
        std::string saved((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        FCITX_ASSERT(saved.find("你好 ㄋㄧˇ-ㄏㄠˇ") != std::string::npos) << "dictionary not persisted: " << saved;
    }
    s.clear();
    pass("C13");

    // LR5: the settings page (setConfig) reaches live sessions.
    // Showing candidates automatically off: the panel stays empty until Tab.
    {
        RawConfig raw;
        raw.setValueByPath("AutoShowCandidates", "False");
        addon->setConfig(raw);
        ic.focusIn();
        s.type("su3");
        FCITX_ASSERT(!s.candidates()) << "AutoShowCandidates=False hides the list";
        FCITX_ASSERT(s.key(FcitxKey_Tab, kTab));
        FCITX_ASSERT(s.candidates()) << "Tab opens it";
        s.clear();
        RawConfig current;
        addon->getConfig()->save(current);
        const auto *value = current.valueByPath("AutoShowCandidates");
        FCITX_ASSERT(value && *value == "False") << "getConfig reflects the page";
        raw.setValueByPath("AutoShowCandidates", "True");
        // Candidates per page reaches both the core and the fcitx5 list.
        raw.setValueByPath("CandidatesPerPage", "5");
        addon->setConfig(raw);
        s.type("su3cl3");
        {
            auto *list = s.candidates();
            FCITX_ASSERT(list && list->pageSize() == 5 && list->totalPages() == 2) << "5 rows per page";
        }
        FCITX_ASSERT(s.key(FcitxKey_Tab, kTab));
        FCITX_ASSERT(s.candidates()->label(4).toString() == "g") << "five selection keys";
        s.clear();
        raw.setValueByPath("CandidatesPerPage", "8");
        addon->setConfig(raw);
        pass("LR5");
    }

    // LR7: ShiftTogglesEnglish hands a lone Shift tap to the session (macOS
    // 中/英); fcitx5's AltTriggerKeys must be empty or it switches first.
    {
        RawConfig hotkeys;
        hotkeys.setValueByPath("Hotkey/AltTriggerKeys", "");
        instance.globalConfig().load(hotkeys, true);
        FCITX_ASSERT(instance.globalConfig().altTriggerKeys().empty());
        RawConfig raw;
        raw.setValueByPath("ShiftTogglesEnglish", "True");
        addon->setConfig(raw);
        // releaseSym: what the layout calls the key on release. With
        // shift:both_capslock_cancel (Omarchy) a Shift release is Caps_Lock.
        auto tapShift = [&](KeySym releaseSym = FcitxKey_Shift_L) {
            // Taps closer than ShiftTapTracker.retriggerGuard (50 ms) count as bounce.
            std::this_thread::sleep_for(std::chrono::milliseconds(60));
            FCITX_ASSERT(!s.key(FcitxKey_Shift_L, kShiftL));
            FCITX_ASSERT(!s.key(releaseSym, kShiftL, shift, /*release=*/true));
        };
        tapShift();
        FCITX_ASSERT(instance.inputMethod(&ic) == "misstype") << instance.inputMethod(&ic);
        FCITX_ASSERT(s.aux() == "英") << s.aux();
        FCITX_ASSERT(!s.key(FcitxKey_s, physical('s').evdev)) << "English passes keys through";
        tapShift();
        FCITX_ASSERT(s.aux() == "中") << s.aux();
        s.type("su3");
        FCITX_ASSERT(s.preedit() == "你") << s.preedit();
        s.clear();
        tapShift(FcitxKey_Caps_Lock);
        FCITX_ASSERT(s.aux() == "英") << "Shift release reported as Caps_Lock: " << s.aux();
        tapShift(FcitxKey_Caps_Lock);
        FCITX_ASSERT(s.aux() == "中") << s.aux();
        // LR8: mid-composition a lone Shift opens an English run: 英 stays up
        // while it is open (also as its letters are typed), 中 when it closes.
        s.type("su3");
        tapShift();
        FCITX_ASSERT(s.aux() == "英") << "English run open: " << s.aux();
        s.type("ok");
        FCITX_ASSERT(s.preedit() == "你ok") << s.preedit();
        FCITX_ASSERT(s.aux() == "英") << "still in the English run: " << s.aux();
        tapShift();
        FCITX_ASSERT(s.aux() == "中") << "English run closed: " << s.aux();
        s.type("cl3");
        FCITX_ASSERT(s.aux().empty()) << "the 中 flash clears on the next key: " << s.aux();
        s.clear();
        pass("LR8");
        raw.setValueByPath("ShiftTogglesEnglish", "False");
        addon->setConfig(raw);
        hotkeys.setValueByPath("Hotkey/AltTriggerKeys/0", "Shift_L");
        instance.globalConfig().load(hotkeys, true);
        pass("LR7");
    }

    // C4 runs last: committing 尼 teaches the user lexicon, which would
    // reorder the candidates every other scenario expects.
    // C4: Tab (one page: enters selection, highlight stays), a selection key
    // picks row 2 (尼), Enter commits it.
    ic.focusIn();
    s.type("su3");
    {
        auto *list = s.candidates();
        FCITX_ASSERT(list && list->totalSize() == 5 && list->globalCursorIndex() == 0);
    }
    FCITX_ASSERT(s.key(FcitxKey_Tab, kTab));
    {
        auto *list = s.candidates();
        FCITX_ASSERT(list && list->globalCursorIndex() == 0);
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

    char arg0[] = "testmisstype";
    char arg1[] = "--disable=all";
    char arg2[] = "--enable=testim,testfrontend,misstype,testui";
    char *argv[] = {arg0, arg1, arg2};
    Instance instance(3, argv);
    instance.addonManager().registerDefaultLoader(nullptr);

    EventDispatcher dispatcher;
    dispatcher.attach(&instance.eventLoop());
    dispatcher.schedule([&instance]() {
        runAll(instance);
        FCITX_INFO() << "All 19 scenarios passed";
        instance.exit();
    });
    instance.exec();
    return 0;
}

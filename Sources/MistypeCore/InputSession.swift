import Foundation

/// What a platform adapter provides to a session. Everything here is I/O the
/// core cannot do itself; the offline path never calls any of it.
public protocol InputSessionHost: AnyObject {
    /// Committed text before the caret. Called only when a remote (Jev)
    /// request is about to be attempted — never on the offline hot path
    /// (macOS clients have segfaulted inside surrounding-text calls).
    func surroundingContext() -> ClientContext
    /// Run `work` on the thread that drives the session (UI/event loop).
    func perform(_ work: @escaping () -> Void)
    /// State changed outside `handle` (a Jev pick moved the highlight):
    /// render `session.view` again.
    func sessionDidChange(_ session: InputSession)
}

/// One-shot effects of a key; persistent state is `InputSession.view`.
public struct KeyResult: Equatable, Sendable {
    /// False: the host passes the key on to the application, after
    /// inserting `commit`.
    public var consumed: Bool
    /// Text to insert into the client now, replacing the preedit.
    public var commit: String?
    /// The key did nothing in this state: the host signals it (beep).
    public var beep: Bool
    /// 中/英 mode flipped (`InputEngine.english`): the host shows its
    /// indicator, anchored at the preedit it drew before `commit`.
    public var modeChanged: Bool
    /// A latin run opened/closed mid-composition (Shift tap or backtick):
    /// the host flashes its indicator with `InputSession.latinActive`
    /// (英 while the run is open, 中 once closed). No commit, no global flip.
    public var latinToggled: Bool

    public init(consumed: Bool, commit: String? = nil, beep: Bool = false, modeChanged: Bool = false,
                latinToggled: Bool = false) {
        self.latinToggled = latinToggled
        self.consumed = consumed
        self.commit = commit
        self.beep = beep
        self.modeChanged = modeChanged
    }

    static let handled = KeyResult(consumed: true)
    static let beeped = KeyResult(consumed: true, beep: true)
}

/// Everything a host draws: marked text and the candidate list. Derived from
/// session state, so hosts render it idempotently (skip when unchanged).
public struct SessionView: Equatable, Sendable {
    /// Marked (preedit) text: converted candidate + raw Bopomofo tail.
    public var preedit: String
    /// Caret inside `preedit`, UTF-16 offset: the focused word start in
    /// cursor mode, else the end.
    public var caret: Int
    /// Full list (focused-word options in cursor mode, else sentences); the
    /// host pages it 8 at a time.
    public var candidates: [String]
    public var selected: Int
    /// Labels shown beside the visible rows.
    public var selectionKeys: [String]
    /// Selection mode: selection keys pick instead of typing Zhuyin.
    public var keysActive: Bool
    /// Cursor mode shows even a single option (the header carries the
    /// cursor); end mode shows the list only when there is a choice.
    public var showsCandidates: Bool
    /// Phrase marking in progress (Shift+Left/Right): what is selected and
    /// what Return would do. While set, `candidates` is empty and
    /// `showsCandidates` is true — hosts draw their panel with this as the
    /// hint instead of a list.
    public var mark: Mark?

    /// A marked span of the converted text, offered to the user dictionary.
    public struct Mark: Equatable, Sendable {
        /// What Return does with the mark.
        public enum Action: Equatable, Sendable {
            /// Add the phrase (also promotes a built-in word to the top).
            case add
            /// Already in the user dictionary: Return removes it.
            case remove
            /// Mark at least `UserDictionary.minSyllables` syllables.
            case tooShort
            /// Mark at most `UserDictionary.maxSyllables` syllables.
            case tooLong
            /// Spans punctuation/Latin, or text that is not dictionary words.
            case unavailable
        }
        /// Selected UTF-16 range inside `SessionView.preedit`.
        public var range: Range<Int>
        public var text: String
        /// Hyphen-joined toned readings (the user dictionary key); empty
        /// when `action == .unavailable`.
        public var reading: String
        public var action: Action
    }

    public static let empty = SessionView(preedit: "", caret: 0, candidates: [], selected: 0,
                                          selectionKeys: [], keysActive: false, showsCandidates: false)
}

/// One client's composition: every editing rule of the IME, platform-free.
/// Adapters feed `KeyEvent`s, apply `KeyResult`s, and draw `view`; they
/// hold no composition state of their own.
public final class InputSession {
    public let engine: InputEngine
    public weak var host: InputSessionHost?

    private var settings = SessionSettings()
    private var composition = Composition()
    private var candidates: [SentenceCandidate] = []
    private var selected = 0
    /// Latin-run mode (backtick toggles): letter keys append verbatim and
    /// keep composing — no Shift toggle, no pause. Tone/space/punct/digits
    /// and commit end the run; see the letter branch below.
    private var latinMode = false
    /// Explicitly picked text (Tab/arrows/digit/click). Survives continued
    /// typing by prefix match: longer candidates extending the pick keep it.
    /// Cleared on commit/clear/Escape or when no candidate extends it.
    /// `explicitPick` is the learning-grade subset: true only when the pick
    /// came from a deliberate selection gesture — separator/punctuation
    /// pinning sets pinnedPick without it, so routine commits never train.
    private var pinnedPick: String?
    private var explicitPick = false
    /// Syllable cursor (nil = end of the converted span). Plain Left/Right
    /// move it instead of flipping pages; the panel then shows options for
    /// the focused word span. Any composition edit resets it to end.
    /// Replaces the old Opt+Right segment lock (dead in practice: toneless
    /// input only beeped, fully toned input committed exactly like Return).
    private var cursor: Int?
    /// Focused options (nil = whole-span list): every word covering the
    /// cursor syllable, each with its own span. Picking pins that span into
    /// sessionPins and advances the cursor past it; pins hold until
    /// commit/clear/Escape and never touch disk.
    private var segmentTexts: [String]?
    private var segmentOptions: [CursorOption] = []
    private var segmentSelected = 0
    /// UTF-16 offset of the cursor syllable (caret for marked text/panel).
    private var segmentCaret: Int?
    private var sessionPins = UserLexicon()
    /// Automatic pins for accepted text (earlier runs, and words 3+
    /// syllables before the end): re-derived from top-1 every refresh, kept
    /// apart from explicit sessionPins so they never train, and dropped
    /// whenever an explicit pick lands (the next refresh re-derives them).
    private var settledPins = UserLexicon()
    private static let settleDistance = 3
    /// Pending keys shown raw after the live conversion: the syllable still
    /// being typed (`livePendingCut`). Empty = everything on screen converted.
    private var rawTail: [String] = []
    /// Selection mode (end-of-span list): entered with Down/Up/Tab. The
    /// cursor's focused list is selection mode too (`inSelection`). Only in
    /// it do the selection keys (`SessionSettings.candidateKeys`, home row by
    /// default) pick — they are Zhuyin keys everywhere else. Any other
    /// typing leaves the mode; Esc leaves it without touching the text.
    private var selecting = false
    private var inSelection: Bool { selecting || segmentTexts != nil }
    /// Symbol menu: the mark just typed, with its alternatives shown in the
    /// candidate list. Tab/arrows step (the mark is swapped live), selection
    /// keys pick once stepping began, Esc or any other key accepts what shows.
    private struct SymbolMenu {
        var choices: [String]
        var selected = 0
        var selecting = false
    }
    private var symbolMenu: SymbolMenu?
    /// Phrase marking: syllable-boundary positions (0…n, between syllables)
    /// of the anchor and the moving end. Started and moved by Shift+Left/
    /// Right from the cursor (or the end); Return files the marked span in
    /// the user dictionary, anything else drops it.
    private var mark: (anchor: Int, head: Int)?
    private var jevRequestID = 0
    private let jevLock = NSLock()

    public init(engine: InputEngine) {
        self.engine = engine
    }

    // MARK: - Host API

    /// Keys as typed (tone marks, 注音文) for the platform's "original
    /// string" query.
    public var rawPhonetic: String { composition.rawPhonetic }

    /// A latin run is open (backtick / Shift tap): letters append verbatim.
    public var latinActive: Bool { latinMode }

    public var view: SessionView {
        if let menu = symbolMenu {
            return SessionView(
                preedit: previewText, caret: caretOffset, candidates: menu.choices, selected: menu.selected,
                selectionKeys: SelectionKeys.labels(keys: settings.candidateKeys),
                keysActive: menu.selecting,
                showsCandidates: menu.selecting || settings.autoShowCandidates)
        }
        if let marked = markView() {
            return SessionView(
                preedit: previewText, caret: marked.caret, candidates: [], selected: 0,
                selectionKeys: [], keysActive: false, showsCandidates: true, mark: marked.mark)
        }
        let texts = segmentTexts ?? candidates.map(\.text)
        return SessionView(
            preedit: previewText,
            caret: caretOffset,
            candidates: texts,
            selected: segmentTexts != nil ? segmentSelected : selected,
            selectionKeys: SelectionKeys.labels(keys: settings.candidateKeys),
            keysActive: inSelection,
            showsCandidates: segmentTexts != nil ? !texts.isEmpty
                : texts.count > 1 && (selecting || settings.autoShowCandidates))
    }

    public func handle(_ event: KeyEvent) -> KeyResult {
        settings = engine.settings()
        let mods = event.modifiers
        let otherMods = !mods.isDisjoint(with: [.command, .control, .option, .capsLock])
        let now = event.timestamp ?? Date().timeIntervalSinceReferenceDate
        let shift = event.key.shiftSide
        switch event.phase {
        case .release:
            // Modifier-only signals: tap bookkeeping, then consume (no text).
            let tap = engine.shiftTap.feed(shift: shift, shiftHeld: mods.contains(.shift),
                                           isRealKeyDown: false, otherMods: otherMods, now: now)
            guard tap && settings.shiftToggle else { return .handled }
            // Mid-composition a lone Shift tap opens/closes a latin run (same
            // as backtick) instead of committing: English joins the phrase and
            // one Return decodes the whole thing. The global 中/英 flip only
            // happens with nothing being composed.
            if !engine.english && !composition.isEmpty {
                latinMode.toggle()
                engine.log("latin=\(latinMode ? 1 : 0) via=shift")
                return KeyResult(consumed: true, latinToggled: true)
            }
            return toggleEnglish()
        case .press:
            if shift != nil {
                // Bare-modifier press (press-as-keyDown delivery): arm only.
                _ = engine.shiftTap.feed(shift: shift, shiftHeld: mods.contains(.shift),
                                         isRealKeyDown: false, otherMods: otherMods, now: now)
                return .handled
            }
            _ = engine.shiftTap.feed(shift: nil, shiftHeld: mods.contains(.shift),
                                     isRealKeyDown: true, otherMods: otherMods, now: now)
            if composition.isEmpty { engine.reloadUserDictionaryIfChanged() }
            // Bare-modifier presses (Caps/Opt/Ctrl alone) carry no text:
            // consume silently instead of committing the composition first.
            if event.key == .modifier, event.text?.isEmpty ?? true { return .handled }
            var result = type(event)
            if result.consumed, !result.beep, result.commit == nil, let chunk = commitSettledHead() {
                result.commit = chunk
            }
            return result
        }
    }

    /// Chunked auto-commit: past `autoCommitSyllables`, the head of the
    /// shown sentence (whole words, all but the last `limit / 2` syllables)
    /// is committed while the tail keeps composing. Only when the head is
    /// exactly what the keys said — no repairs, no unresolved syllables —
    /// and the user holds no explicit picks or open list; otherwise it waits.
    /// Never trains learning (like every routine commit), and the raw keys
    /// of the head are consumed with it.
    private func commitSettledHead() -> String? {
        let limit = settings.autoCommitSyllables
        guard limit > 0, !composition.isEmpty, cursor == nil, !inSelection, symbolMenu == nil, sessionPins.isEmpty,
              !explicitPick, candidates.indices.contains(selected) else { return nil }
        let shown = candidates[selected]
        let total = shown.syllables.count
        guard total > limit, shown.unresolved == 0,
              let cut = shown.alignment.last(where: { $0.syllables.upperBound <= total - limit / 2 }),
              cut.syllables.upperBound > 0 else { return nil }
        let head = shown.syllables.prefix(cut.syllables.upperBound)
        // Raw keys the head consumed: walk symbol keys until the head's are
        // used up, then take the tone key that closes the last syllable.
        var wanted = head.flatMap(\.keys)[...]
        var cutIndex = 0
        for (index, key) in composition.rawKeys.enumerated() where ZhuyinKeyboard.symbols[key] != nil {
            guard key == wanted.first else { return nil }
            wanted.removeFirst()
            cutIndex = index + 1
            if wanted.isEmpty { break }
        }
        guard wanted.isEmpty else { return nil }
        if composition.rawKeys.indices.contains(cutIndex),
           ZhuyinKeyboard.tones[composition.rawKeys[cutIndex]] != nil { cutIndex += 1 }
        let units = Array(shown.text.utf16)
        guard cut.chars.upperBound <= units.count else { return nil }
        let chunk = String(decoding: units[0..<cut.chars.upperBound], as: UTF16.self)
        guard !chunk.isEmpty else { return nil }
        engine.log("autocommit syllables=\(head.count) keys=\(cutIndex) of=\(composition.rawKeys.count)")
        engine.recordCommit(chunk)
        _ = nextJevID()
        composition.dropHead(keys: cutIndex)
        candidates = []
        settledPins = UserLexicon()
        pinnedPick = nil
        selected = 0
        refresh()
        return chunk
    }

    /// Panel click (or any host-side pick) on row `index` of `view.candidates`.
    public func pick(at index: Int) {
        settings = engine.settings()
        if let menu = symbolMenu {
            if menu.choices.indices.contains(index) { applyMenuChoice(index) }
            symbolMenu = nil
            return
        }
        if let texts = segmentTexts, texts.indices.contains(index) {
            pinAdvance(at: index)
            return
        }
        guard candidates.indices.contains(index) else { return }
        selected = index
        pinnedPick = candidates[index].text
        explicitPick = true
        selecting = false
    }

    /// Commit what is shown (focus loss, client request). Nil = nothing to
    /// insert; the composition is then left as it was.
    @discardableResult
    public func commit() -> String? {
        settings = engine.settings()
        return commitText(raw: false)
    }

    /// Focus changed: a half-typed Shift tap never completes elsewhere.
    public func resetModifierState() {
        engine.shiftTap.reset()
    }

    // MARK: - Key handling

    private func pass(committing: Bool = true) -> KeyResult {
        KeyResult(consumed: false, commit: committing ? commitText(raw: false) : nil)
    }

    /// Shared 中/英 toggle (Shift-tap and Shift+Space): commit first so no
    /// composition is lost, then flip the global mode.
    private func toggleEnglish() -> KeyResult {
        let text = commitText(raw: false)
        engine.english.toggle()
        latinMode = false
        return KeyResult(consumed: true, commit: text, modeChanged: true)
    }

    private func type(_ event: KeyEvent) -> KeyResult {
        let key = event.key
        let mods = event.modifiers
        let shift = mods.contains(.shift)
        let chord = !mods.isDisjoint(with: [.command, .control, .option])
        // Key trace for routing diagnosis (codes only, never text content).
        engine.log("key=\(event.nativeCode ?? -1) flags=\(mods.rawValue) comp=\(composition.isEmpty ? 0 : 1) sel=\(selected) n=\(candidates.count) cur=\(cursor ?? -1) seg=\(segmentTexts == nil ? 0 : 1)")
        // A mark survives only its own gestures: Shift+arrows move it, Return
        // files it, Escape drops it. Any other key abandons it first.
        let markGesture = (shift && (key == .left || key == .right)) || key == .escape || (key == .enter && !shift)
        if mark != nil, !markGesture || chord { mark = nil }
        // Text-producing keys that produce no text (dead keys, …) are
        // swallowed: there is nothing to type or commit around.
        let text = event.text ?? ""
        switch key {
        case .character, .other:
            if text.isEmpty { return .handled }
        default:
            break
        }
        if key == .space && shift { return toggleEnglish() }
        if engine.english || mods.contains(.capsLock) { return pass() }
        // Latin mode ends on anything but letters, space (multi-word runs
        // stay latin: `hello world`), and the backtick toggle: tones,
        // punctuation, digits and commit keys resume Zhuyin. Backspace keeps
        // the run so a typo can be fixed without re-toggling; see below.
        let latinLetter = latinMode && !chord && key.letterLabel != nil
        if !latinLetter && key != .character("`") && key != .space && key != .backspace {
            latinMode = false
        }
        if var menu = symbolMenu {
            let count = menu.choices.count
            let label = key.zhuyinLabel
            func step(to index: Int) -> KeyResult {
                menu.selected = index
                menu.selecting = true
                symbolMenu = menu
                applyMenuChoice(index)
                return .handled
            }
            if !chord {
                switch key {
                case .tab, .down, .up:
                    let forward = key == .down || (key == .tab && !shift)
                    return step(to: (menu.selected + (forward ? 1 : count - 1)) % count)
                case .pageUp, .pageDown:
                    guard count > 8 else { return .beeped }
                    let pages = (count + 7) / 8
                    let next = (menu.selected / 8 + (key == .pageDown ? 1 : pages - 1)) % pages
                    return step(to: min(next * 8 + menu.selected % 8, count - 1))
                case .escape:
                    symbolMenu = nil // keep the mark that shows
                    return .handled
                case .enter where menu.selecting && !shift && settings.returnConfirmsSelection:
                    symbolMenu = nil // confirm the stepped mark; the next Return commits
                    return .handled
                default:
                    break
                }
                if menu.selecting, !shift, let label {
                    if (label == "-" || label == "="), count > 8 {
                        let pages = (count + 7) / 8
                        let next = (menu.selected / 8 + (label == "=" ? 1 : pages - 1)) % pages
                        return step(to: min(next * 8 + menu.selected % 8, count - 1))
                    }
                    if let slot = SelectionKeys.slot(forLabel: label, keys: settings.candidateKeys) {
                        let global = (menu.selected / 8) * 8 + slot
                        guard global < count else { return .beeped }
                        applyMenuChoice(global)
                        symbolMenu = nil
                        return .handled
                    }
                }
            }
            symbolMenu = nil // any other key accepts the mark and acts normally
        }
        // Destructive editing is handled before the generic modifier
        // commit-passthrough further below, so deleting phonetic evidence
        // never commits the composition first.
        if key == .backspace {
            guard !composition.isEmpty else {
                latinMode = false
                return pass(committing: false)
            }
            selected = 0
            // Separator/punctuation pinning (and the settled pins derived
            // from it) must not outlive the key that created it: erasing a
            // space would otherwise re-decode under the old pin, leaving a
            // one-item list that Up/Down cannot open.
            settledPins = UserLexicon()
            if !explicitPick { pinnedPick = nil }
            if mods.contains(.command) {
                clear()
            } else if mods.contains(.option) {
                composition.deleteLastSyllable()
                refresh()
            } else {
                // A tone closing a fused toneless body erases one decoded
                // syllable, not the whole run (which read as "Backspace ate
                // the sentence").
                if let last = candidates.indices.contains(selected) ? candidates[selected].syllables.last : nil,
                   composition.trailingBody.suffix(last.keys.count) == last.keys[...] {
                    composition.eraseTailSyllable(symbolCount: last.keys.count)
                    if composition.parsed.pending.isEmpty { composition.erase() }
                } else {
                    composition.erase()
                }
                refresh()
            }
            // Editing into a latin tail resumes that run; an open run stays
            // open even when the whole word is deleted (retyping it).
            if !composition.trailingLatin.isEmpty { latinMode = true }
            return .handled
        }
        if key == .forwardDelete { // caret sits after marked text
            guard !composition.isEmpty else { return pass(committing: false) }
            return pass()
        }
        if key == .down || key == .up { // step candidates
            guard !composition.isEmpty else { return pass(committing: false) }
            if let texts = segmentTexts, !texts.isEmpty {
                // Focused mode: move the segment highlight only — nothing
                // pins until Tab/digit/click/Return confirms. Consumed even
                // for a single option so the preview never jumps invisibly.
                segmentSelected = (segmentSelected + (key == .down ? 1 : texts.count - 1)) % texts.count
                return .handled
            }
            if candidates.count > 1 {
                selectCandidate((selected + (key == .down ? 1 : candidates.count - 1)) % candidates.count)
                selecting = true
                return .handled
            }
            return pass()
        }
        if key == .pageUp || key == .pageDown {
            guard !composition.isEmpty else { return pass(committing: false) }
            if chord { return pass() }
            return page(forward: key == .pageDown)
        }
        // Modified arrows never edit the composition: commit first, then let
        // the app move its caret (word jump, line start, selection). Plain
        // arrows below drive the syllable cursor / candidate list instead.
        if (key == .left || key == .right) && chord {
            return pass()
        }
        if (key == .left || key == .right) && shift { // mark a phrase
            guard !composition.isEmpty else { return pass(committing: false) }
            return extendMark(forward: key == .right) ? .handled : .beeped
        }
        if key == .left || key == .right { // syllable cursor only
            // Paging used to live here as a fallback, which made the arrows
            // unpredictable (cursor sometimes, page-flip others, so stepping
            // back usually paged instead). Paging is PageUp / PageDown (or - / =
            // in selection mode) or Tab / Down / Up (they walk the full list
            // across pages), so Left/Right never flip pages: failure beeps and stays put.
            guard !composition.isEmpty else { return pass(committing: false) }
            let moved = key == .left ? moveCursorBack() : moveCursorForward()
            return moved ? .handled : .beeped
        }
        if key == .escape {
            guard !composition.isEmpty else { return pass(committing: false) }
            if mark != nil {
                let visible = markView() != nil
                mark = nil
                if visible { return .handled } // a collapsed mark shows nothing: Esc goes on
            }
            if inSelection {
                // First Esc only leaves selection mode (and the cursor);
                // the text and any picks stay. A second Esc clears.
                selecting = false
                cursor = nil
                clearSegment()
                return .handled
            }
            clear()
            return .handled
        }
        if chord { return pass() }
        if key == .enter {
            guard !composition.isEmpty else { return pass(committing: false) }
            if mark != nil { return fileMark() }
            if shift {
                // Shift+Return sends the keys as typed: 注音文 even when every
                // syllable is valid (a lone ㄗ is 資 to the decoder).
                return KeyResult(consumed: true, commit: commitText(raw: true))
            }
            if settings.returnConfirmsSelection, inSelection {
                // Confirm only: the highlighted candidate is already the
                // pick (stepping pins it); a focused word pins and advances.
                if let texts = segmentTexts, texts.indices.contains(segmentSelected) {
                    pinAdvance(at: segmentSelected)
                } else {
                    selecting = false
                }
                return .handled
            }
            if let texts = segmentTexts, texts.indices.contains(segmentSelected) {
                // Focused Return pins the highlighted segment, re-decodes so
                // top-1 honors it, then commits everything at once.
                pinAdvance(at: segmentSelected)
                selected = 0
            }
            return KeyResult(consumed: true, commit: commitText(raw: false))
        }
        if key == .tab && !composition.isEmpty {
            if let texts = segmentTexts, texts.indices.contains(segmentSelected) {
                // Focused Tab pins without committing: Left…Tab,Tab,Return
                // fixes two mid-sentence words and sends the sentence.
                pinAdvance(at: segmentSelected)
                return .handled
            }
            if candidates.count > 1 {
                // Tab steps forward, Shift+Tab steps back (Tab reliably
                // reaches the IME; arrows are often eaten by the client app
                // or the panel before the key event ever arrives).
                selectCandidate((selected + (shift ? candidates.count - 1 : 1)) % candidates.count)
                selecting = true
            }
            return .handled
        }
        // Backtick toggles latin-run mode (no modifiers, either language
        // mode off): following letters append verbatim. Swallowed silently —
        // the letters themselves are the feedback. Shift+` is ～ (Punctuation).
        if key == .character("`") && !shift && !engine.english {
            latinMode.toggle()
            engine.log("latin=\(latinMode ? 1 : 0)")
            return KeyResult(consumed: true, latinToggled: true)
        }
        // `-` / `=` turn pages in selection mode (the Rime/Pinyin convention);
        // they are ㄦ / unmapped elsewhere, so outside it they still type.
        if inSelection, !composition.isEmpty, !shift,
           key == .character("-") || key == .character("=") {
            return page(forward: key == .character("="))
        }
        // Selection keys pick from the visible page, but only in selection
        // mode: they are Zhuyin keys (a=ㄇ, s=ㄋ, …), so outside it they type.
        // Shift+digit used to pick; that row is now the full-width symbol
        // layer (Punctuation), so picking and symbols never collide.
        if inSelection, !composition.isEmpty, !shift,
           let label = key.zhuyinLabel,
           let slot = SelectionKeys.slot(forLabel: label, keys: settings.candidateKeys) {
            if let texts = segmentTexts {
                let global = (segmentSelected / 8) * 8 + slot
                guard global < texts.count else { return .beeped }
                pinAdvance(at: global)
                return .handled
            }
            let global = (selected / 8) * 8 + slot
            guard global < candidates.count else { return .beeped }
            selectCandidate(global)
            selecting = false
            return .handled
        }
        // CJK punctuation locks the current pick and continues: pin the
        // selection, append the mark, refresh. Never commits — commit is
        // Return's job. Checked before the phonetic path. Chords never reach
        // here (passed through above), so the table's Ctrl+; entry is
        // unreachable — as it was in the pre-extraction controller.
        if case .character(let label) = key,
           let punct = Punctuation.smartQuote(label: label, shift: shift, ctrl: mods.contains(.control),
                                              in: composition.rawKeys)
                ?? Punctuation.output(label: label, shift: shift, ctrl: mods.contains(.control)) {
            if candidates.indices.contains(selected) {
                pinnedPick = candidates[selected].text
            }
            guard composition.appendLiteral(punct) else { return .beeped }
            refresh()
            let choices = Punctuation.choices(for: punct)
            symbolMenu = choices.count > 1 ? SymbolMenu(choices: choices) : nil
            return .handled
        }
        // Latin letters append verbatim (case from the event text) and keep
        // composing: the latin run (backtick), or Shift-hold — a fast-typing
        // Shift brush leaves a stray capital in marked text instead of
        // chopping the sentence. No commit, no mode toggle either way.
        if (latinLetter || (shift && key.letterLabel != nil)),
           text.count == 1, let char = text.first, char.isASCII, char.isLetter {
            guard composition.appendLatin(String(char)) else { return .beeped }
            refresh()
            return .handled
        }
        if shift && (key.zhuyinLabel == nil || composition.isEmpty) {
            return pass()
        }
        if let label = key.zhuyinLabel {
            if label == " " {
                // Space with pending keys is a tone mark (continue).
                // Otherwise Space pins the current pick and continues as a
                // literal separator — commit is Return's job. Empty
                // composition inserts the space itself.
                guard !composition.isEmpty else { return KeyResult(consumed: true, commit: " ") }
                if composition.parsed.pending.isEmpty, candidates.indices.contains(selected) {
                    pinnedPick = candidates[selected].text
                }
                guard composition.appendSpace() else { return .beeped }
                refresh()
                return .handled
            }
            if composition.append(label) {
                refresh()
                return .handled
            }
            // A tone with no pending syllable is a late or corrected tone:
            // attach it to the last boundary instead of swallowing it.
            if ZhuyinKeyboard.tones[label] != nil, composition.retoneLast(label) {
                refresh()
                return .handled
            }
            return .beeped
        }
        return pass()
    }

    private func applyMenuChoice(_ index: Int) {
        guard let menu = symbolMenu, menu.choices.indices.contains(index) else { return }
        _ = composition.replaceLastLiteral(menu.choices[index])
        refresh()
    }

    /// Flip one page of 8, keeping the row (clamped on a short last page) and
    /// wrapping at the ends. Moves the highlight only, like Down: nothing pins
    /// until a pick. Beeps when everything fits on one page.
    private func page(forward: Bool) -> KeyResult {
        func target(_ current: Int, _ count: Int) -> Int? {
            guard count > 8 else { return nil }
            let pages = (count + 7) / 8
            let next = (current / 8 + (forward ? 1 : pages - 1)) % pages
            return min(next * 8 + current % 8, count - 1)
        }
        if let texts = segmentTexts {
            guard let index = target(segmentSelected, texts.count) else { return .beeped }
            segmentSelected = index
            return .handled
        }
        guard let index = target(selected, candidates.count) else { return .beeped }
        selectCandidate(index)
        selecting = true
        return .handled
    }

    private func selectCandidate(_ index: Int) {
        selected = index
        pinnedPick = candidates[index].text
        explicitPick = true
    }

    // MARK: - Decode and commit

    private var previewText: String {
        let converted = candidates.indices.contains(selected) ? candidates[selected].text : ""
        return converted + rawTail.compactMap { ZhuyinKeyboard.symbols[$0] }.joined()
    }

    /// Caret shared by marked text and the panel header: focused word start,
    /// else after the last unit. UTF-16 offsets throughout.
    private var caretOffset: Int {
        let len = previewText.utf16.count
        if let focused = segmentCaret { return min(focused, len) }
        return len
    }

    private func refresh(keepCursor: Bool = false) {
        // Preview converts every run, the pending one live (below);
        // punctuation passes through in place.
        let previous = candidates.map(\.text)
        mark = nil
        // Jev gate threads through every decode entry point but changes
        // nothing while off (the default): the offline decode below is the
        // single source of candidates. Presence-only logging keeps remote
        // intent observable per repo policy without leaking key or text.
        engine.logJevGate(settings.jev)
        // Live conversion (RIME-style continuous typing): the pending run
        // converts as it is typed, except the syllable still in progress,
        // which stays raw (`livePendingCut`). Space is a first-tone key, not
        // a "convert" key, so nothing waits for it.
        // A whole-sentence pick becomes positional pins before re-decoding,
        // so re-segmentation of the live tail cannot drop it.
        if !keepCursor, pinnedPick != nil, selected != 0, candidates.indices.contains(selected) {
            sessionPins.pinDifferences(of: candidates[selected], from: candidates[0])
            settledPins = UserLexicon()
        }
        let live = engine.decoder.livePreview(composition, fuzzy: settings.fuzzyRepair,
                                              toneTolerance: settings.toneTolerance,
                                              userLexicon: engine.activeUserLexicon(settings),
                                              locked: sessionPins.isEmpty ? nil : sessionPins,
                                              settled: settledPins.isEmpty ? nil : settledPins)
        rawTail = live.rawTail
        candidates = live.candidates
        if let top = candidates.first {
            settledPins = UserLexicon.settled(from: top, keep: Self.settleDistance)
        }
        if let pin = pinnedPick, !pin.isEmpty {
            if let exact = candidates.firstIndex(where: { $0.text == pin }) {
                selected = exact
            } else if let extended = candidates.firstIndex(where: { $0.text.hasPrefix(pin) }) {
                selected = extended
            } else {
                selected = 0
                pinnedPick = nil
                explicitPick = false
            }
        } else if candidates.map(\.text) != previous || !candidates.indices.contains(selected) {
            selected = 0
        }
        // Composition edits return the cursor to end (pins survive — they
        // are reading-keyed, so tail typing keeps them); pin-advance passes
        // keepCursor to stay focused on the next span.
        if !keepCursor {
            cursor = nil
            selecting = false
        }
        if cursor != nil {
            focusSegment()
        } else {
            clearSegment()
        }
        scheduleJevEvaluation()
    }

    private func commitText(raw: Bool) -> String? {
        guard !composition.isEmpty else { return nil }
        // What you see is what commits: the converted text plus any raw
        // tail exactly as shown, so a trailing ㄉ (or a whole run typed as
        // 注音文) commits as Bopomofo instead of being "repaired" into a char
        // the preview never showed (user decision 2026-09-27).
        // Learning-grade: nothing left raw and an explicit pick. Anything
        // else — raw tail, separator pinning, raw fallback — never trains.
        let learnable = !raw && rawTail.isEmpty && candidates.indices.contains(selected)
        var text = raw ? composition.rawPhonetic : previewText
        if text.isEmpty {
            // Defensive: nothing rendered yet (no refresh since the last
            // edit). Offline recompute, Jev gate closed as in refresh.
            engine.logJevGate(settings.jev)
            text = engine.decoder.decodeSegments(composition.segments,
                                                 pendingKeys: composition.parsed.pending,
                                                 fuzzy: settings.fuzzyRepair,
                                                 toneTolerance: settings.toneTolerance,
                                                 userLexicon: engine.activeUserLexicon(settings),
                                                 locked: sessionPins.isEmpty ? nil : sessionPins).first?.text
                ?? composition.rawPhonetic
        }
        while text.last?.isWhitespace == true { text.removeLast() }
        guard !text.isEmpty else { return nil }
        // Success-rate verdict for any evaluation of exactly this state.
        engine.gradeJevEval(rawKeys: composition.rawKeys.joined(), committed: text)
        // Topic continuity for future Jev runs (in-memory ring, never disk).
        engine.recordCommit(text)
        if settings.userLearning && explicitPick && learnable {
            // Word-level: cursor picks still pinned, words changed by a
            // whole-sentence pick, or the input when it is one word.
            engine.learn(UserLexicon.learnedWords(committed: candidates[selected], pins: sessionPins,
                                                  baseline: selected == 0 ? nil : candidates[0]))
        }
        clear()
        return text
    }

    /// Drop the composition and every pick (commit, Esc, Cmd+Backspace).
    private func clear() {
        _ = nextJevID()
        composition.clear()
        candidates = []
        rawTail = []
        settledPins = UserLexicon()
        selecting = false
        symbolMenu = nil
        pinnedPick = nil
        explicitPick = false
        cursor = nil
        mark = nil
        clearSegment()
        sessionPins = UserLexicon()
        selected = 0
        latinMode = false
    }

    // MARK: - Syllable cursor (go back and pick a word, no modifiers)

    private struct FocusFrame {
        let syllables: [Syllable] // the top candidate's own decoded syllables
        let top: SentenceCandidate
    }

    /// The cursor indexes the syllables the top candidate was decoded from
    /// (`SentenceCandidate.syllables`), never a list rebuilt from the
    /// composition: repair and pending-run segmentation happen inside the
    /// decoder, so a toneless run is ONE fused syllable in the composition
    /// and the old rebuild-and-compare check rejected every toneless
    /// sentence (Left/Right only beeped). The live-converted pending run is
    /// included (it is in the alignment); only the raw tail is not.
    /// Works across separators: syllable indexes are global, and options
    /// stay inside the cursor's own run (`run(containing:)`).
    private func focusFrame() -> FocusFrame? {
        guard candidates.indices.contains(selected) else { return nil }
        let top = candidates[selected]
        // Unresolved (raw fallback) spans stay out: nothing to offer there.
        guard top.unresolved == 0,
              let end = top.alignment.last?.syllables.upperBound, end > 0,
              top.syllables.count == end else { return nil }
        return FocusFrame(syllables: top.syllables, top: top)
    }

    private func spanText(_ text: String, _ chars: Range<Int>) -> String? {
        let units = Array(text.utf16)
        guard chars.lowerBound >= 0, chars.upperBound <= units.count else { return nil }
        return String(decoding: units[chars], as: UTF16.self)
    }

    private func clearSegment() {
        segmentTexts = nil
        segmentOptions = []
        segmentSelected = 0
        segmentCaret = nil
    }

    /// Point the cursor at its syllable: list every word covering it
    /// (`cursorOptions`, longest first), so a fix needing a different word
    /// boundary (大|對 -> 打對) is one pick. The highlight starts on what is
    /// displayed now: the top path's word there, else the single character.
    /// Outcomes are traced by code (numbers only): ok, noframe, noword.
    private func focusSegment() {
        clearSegment()
        guard let c = cursor, let frame = focusFrame(),
              let word = frame.top.alignment.first(where: { $0.syllables.contains(c) }),
              let caret = frame.top.charOffset(ofSyllable: c) else {
            engine.log("focus noframe")
            cursor = nil
            return
        }
        var options = engine.decoder.cursorOptions(
            frame.syllables, at: c, within: frame.top.run(containing: c),
            fuzzy: settings.fuzzyRepair, toneTolerance: settings.toneTolerance)
        let shownWord = spanText(frame.top.text, word.chars)
        let shownChar = spanText(frame.top.text, caret..<caret + 1)
        // Multi-syllable spans keep only their best few words, so a word
        // shown thanks to learning can fall outside the list; highlighting
        // a single char instead would let Return re-pin (and rewrite) it.
        // Keep the displayed word listed, at the end of its length group.
        if let shownWord, !options.contains(where: { $0.span == word.syllables && $0.text == shownWord }) {
            let at = options.firstIndex(where: { $0.span.count < word.syllables.count }) ?? options.count
            options.insert(CursorOption(text: shownWord, span: word.syllables, score: -.infinity), at: at)
        }
        guard let current = options.firstIndex(where: { $0.span == word.syllables && $0.text == shownWord })
                ?? options.firstIndex(where: { $0.span == c..<c + 1 && $0.text == shownChar }) else {
            engine.log("focus noword")
            cursor = nil
            return
        }
        engine.log("focus ok s=\(c) n=\(options.count) cur=\(current)")
        segmentOptions = options
        segmentTexts = options.map(\.text)
        segmentSelected = current
        segmentCaret = caret
    }

    private func moveCursorBack() -> Bool {
        guard let frame = focusFrame(),
              let end = frame.top.alignment.last?.syllables.upperBound, end > 0 else { return false }
        cursor = max((cursor ?? end) - 1, 0)
        focusSegment()
        return true
    }

    private func moveCursorForward() -> Bool {
        guard let current = cursor, let frame = focusFrame(),
              let end = frame.top.alignment.last?.syllables.upperBound else { return false }
        cursor = current + 1 >= end ? nil : current + 1
        focusSegment()
        return true
    }

    /// Pin a focused option: session-scoped decisive bonus (never disk) that
    /// changes only the option's span — overlapping older picks keep their
    /// characters outside it (`UserLexicon.pin(_:over:)`). Whole-text pin is
    /// cleared so the two never fight; the pick counts as explicit for
    /// user-phrase learning at commit.
    private func pinAdvance(at index: Int) {
        guard segmentOptions.indices.contains(index), let frame = focusFrame() else { return }
        let option = segmentOptions[index]
        sessionPins.pin(option, over: frame.top)
        settledPins = UserLexicon()
        pinnedPick = nil
        explicitPick = true
        cursor = option.span.upperBound
        refresh(keepCursor: true)
    }

    // MARK: - Phrase marking (Shift+Left/Right, Return files it)

    /// Moves the marked end one syllable, starting a mark at the cursor (or
    /// the end of the converted text) the first time. The mark may collapse
    /// onto its anchor (nothing selected, `markView` is nil) and grow again
    /// on the other side. The focused-word list is hidden while
    /// marking (the panel shows the mark's hint instead).
    private func extendMark(forward: Bool) -> Bool {
        guard let frame = focusFrame(),
              let end = frame.top.alignment.last?.syllables.upperBound, end > 0 else { return false }
        var next = mark ?? { let start = cursor ?? end; return (start, start) }()
        let head = next.head + (forward ? 1 : -1)
        guard (0...end).contains(head) else { return false }
        next.head = head
        mark = next
        selecting = false
        cursor = nil
        clearSegment()
        return true
    }

    /// Everything the host needs to draw the mark; nil when not marking.
    private func markView() -> (mark: SessionView.Mark, caret: Int)? {
        guard let marked = mark, marked.anchor != marked.head, let frame = focusFrame() else { return nil }
        let span = min(marked.anchor, marked.head)..<max(marked.anchor, marked.head)
        func offset(_ boundary: Int) -> Int? {
            boundary >= frame.syllables.count
                ? frame.top.alignment.last?.chars.upperBound
                : frame.top.charOffset(ofSyllable: boundary)
        }
        guard let start = offset(span.lowerBound), let end = offset(span.upperBound),
              let caret = offset(marked.head), start <= end else { return nil }
        let phrase = markedPhrase(span, in: frame)
        let action: SessionView.Mark.Action
        if span.count > UserDictionary.maxSyllables {
            action = .tooLong
        } else if span.count < UserDictionary.minSyllables {
            action = .tooShort
        } else if let phrase {
            action = engine.userDictionary.contains(reading: phrase.reading, text: phrase.text) ? .remove : .add
        } else {
            action = .unavailable
        }
        return (SessionView.Mark(range: start..<end, text: phrase?.text ?? "",
                                 reading: phrase?.reading ?? "", action: action), caret)
    }

    /// Text and toned readings of a syllable span, read off the displayed
    /// sentence: each word it touches is looked up in the lexicon over its
    /// own syllables (a tone-exact trie path), then sliced to the span. Nil
    /// when the span crosses a run break or touches text that is not a
    /// dictionary word (raw Zhuyin fallback, 1:many alignments).
    private func markedPhrase(_ span: Range<Int>, in frame: FocusFrame) -> (text: String, reading: String)? {
        guard !span.isEmpty, let run = frame.top.run(containing: span.lowerBound),
              span.upperBound <= run.upperBound else { return nil }
        var chars: [String] = []
        var readings: [String] = []
        for word in frame.top.alignment where word.syllables.overlaps(span) {
            guard let text = spanText(frame.top.text, word.chars), text.count == word.syllables.count,
                  let path = engine.decoder.readings(
                      of: text, syllables: frame.syllables, span: word.syllables,
                      fuzzy: settings.fuzzyRepair, toneTolerance: settings.toneTolerance) else { return nil }
            let parts = path.split(separator: "-").map(String.init), letters = Array(text)
            for index in word.syllables where span.contains(index) {
                chars.append(String(letters[index - word.syllables.lowerBound]))
                readings.append(parts[index - word.syllables.lowerBound])
            }
        }
        guard chars.count == span.count else { return nil }
        return (chars.joined(), readings.joined(separator: "-"))
    }

    /// Return on a mark: add the phrase to the user dictionary (or remove it
    /// when it is already there) and re-decode so the effect shows at once.
    /// Never commits — the composition goes on with the new word in it.
    private func fileMark() -> KeyResult {
        guard let marked = markView()?.mark else {
            mark = nil
            return .beeped
        }
        var dictionary = engine.userDictionary
        switch marked.action {
        case .add: dictionary.add(reading: marked.reading, text: marked.text)
        case .remove: dictionary.remove(reading: marked.reading, text: marked.text)
        case .tooShort, .tooLong, .unavailable: return .beeped
        }
        engine.setUserDictionary(dictionary)
        // The edit changes what the span decodes to: drop the automatic pins
        // that froze the old text and the whole-sentence pick, then redecode.
        settledPins = UserLexicon()
        pinnedPick = nil
        refresh()
        return .handled
    }

    // MARK: - Jev (explicit opt-in remote assistance)

    private func nextJevID() -> Int {
        jevLock.lock()
        defer { jevLock.unlock() }
        jevRequestID += 1
        return jevRequestID
    }

    private func currentJevID() -> Int {
        jevLock.lock()
        defer { jevLock.unlock() }
        return jevRequestID
    }

    private func scheduleJevEvaluation() {
        let requestID = nextJevID()
        let config = settings.jev
        // Never while the pending run is still growing: live conversion
        // re-decodes it every keystroke, and asking then would send a request
        // per typing pause (Jev saw only terminated runs before live
        // conversion; this keeps that request rate).
        guard config.canAttempt,
              !composition.isEmpty,
              composition.parsed.pending.isEmpty, rawTail.isEmpty,
              candidates.count > 1,
              pinnedPick == nil,
              !explicitPick,
              segmentTexts == nil,
              let host else { return }
        // Decisive-offline filter first: a top-1 lead past repair scale
        // means the phonetic evidence already decided — skip before asking
        // the host for surrounding text (an XPC round-trip on macOS, run
        // ONLY here, after the gates above, when Jev will genuinely attempt).
        let margin = candidates[0].score - candidates[1].score
        let context = host.surroundingContext()
        engine.log("context chars=\(context.precedingText.count) app=\(context.bundleIdentifier ?? "none")")
        // Span counts complete syllables plus the segmented pending tail:
        // toneless typing never terminates pending, but its multi-syllable
        // runs are still worth asking about.
        let parsed = composition.parsed
        var syllableCount = parsed.complete.count
        if !parsed.pending.isEmpty,
           let tail = engine.decoder.segmentKeys(
               parsed.pending, fuzzy: settings.fuzzyRepair,
               toneTolerance: settings.toneTolerance).first {
            syllableCount += tail.count
        }
        let hasContext = !context.precedingText.isEmpty
        guard JevTrigger.shouldAttempt(syllableCount: syllableCount, topMargin: margin,
                                       hasContext: hasContext) else {
            engine.log("jev skip=\(JevTrigger.skipCode(syllableCount: syllableCount, topMargin: margin, hasContext: hasContext))")
            return
        }

        let rawKeys = composition.rawKeys.joined()
        // Evidence = the syllables the candidates were decoded from; the
        // composition's segments hold a toneless run as ONE fused syllable.
        let evidence = candidates[0].syllables.map { JevState.Evidence(base: $0.base, tone: $0.tone) }
        let candTuples = Array(candidates.prefix(8)).map {
            (text: $0.text, score: $0.score, repairs: $0.repairs, unresolved: $0.unresolved)
        }
        let userCtx = context.precedingText
        // Learned picks for exactly these readings (harness parity), plus
        // recent commits for topic continuity. Both ride the same explicit
        // opt-in as the request itself; learning-off means no preferences.
        let prefs = engine.activeUserLexicon(settings)?.matchingPreferences(
            forBases: evidence.map(\.base)) ?? []
        let recent = engine.recentCommits
        let log = engine.log
        log("jev prefs=\(prefs.count) recent=\(recent.count)")

        Task.detached { [weak self, weak host] in
            // Debounce 120ms: fast typing supersedes this request without hitting the network
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, self.currentJevID() == requestID else { return }

            log("[jev-api] start model=\(config.model) cands=\(candTuples.count) ctxChars=\(userCtx.count)")
            let t0 = DispatchTime.now()
            func elapsedMs() -> Int {
                Int(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000)
            }
            do {
                let result = try await JevClient.evaluate(
                    config: config,
                    rawKeys: rawKeys,
                    evidence: evidence,
                    candidates: candTuples,
                    userContext: userCtx,
                    userPreferences: prefs,
                    recentCommits: recent,
                    richContext: config.allowRichContext,
                    timeoutInterval: 1.2
                )
                let ms = elapsedMs()
                host?.perform {
                    self.applyJev(result, requestID: requestID, rawKeys: rawKeys, elapsedMs: ms)
                }
            } catch {
                log("[jev-api] err ms=\(elapsedMs())ms \(error.localizedDescription)")
            }
        }
    }

    private func applyJev(_ result: JevEvaluationResult, requestID: Int, rawKeys: String, elapsedMs: Int) {
        guard let host,
              currentJevID() == requestID,
              !composition.isEmpty,
              pinnedPick == nil,
              !explicitPick,
              segmentTexts == nil else {
            engine.log("[jev-api] stale ms=\(elapsedMs)ms (superseded)")
            return
        }
        let targetIndex = result.pickedIndex - 1
        let flip = targetIndex != selected
        engine.log("[jev-api] ok ms=\(elapsedMs)ms pick=\(result.pickedIndex):\(result.pickedText) conf=\(String(format: "%.2f", result.confidence)) flip=\(flip ? 1 : 0)")
        engine.noteJevEval(rawKeys: rawKeys, pickedText: result.pickedText, flip: flip, confidence: result.confidence)
        if flip && candidates.indices.contains(targetIndex) {
            selected = targetIndex
            host.sessionDidChange(self)
        }
    }
}

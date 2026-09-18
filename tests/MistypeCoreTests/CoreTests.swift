import XCTest
@testable import MistypeCore

final class CoreTests: XCTestCase {
    private func composition(_ keys: String) -> Composition {
        var result = Composition()
        for key in keys { _ = result.append(String(key)) }
        return result
    }
    private var decoder: LexiconDecoder {
        LexiconDecoder(tsv: """
        ㄋㄧˇ\t你\t-5
        ㄋㄧˇ\t妳\t-6
        ㄋㄧˇ\t尼\t-7
        ㄋㄧˇ\t泥\t-8
        ㄏㄠˇ\t好\t-5
        ㄋㄧˇ-ㄏㄠˇ\t你好\t-3
        ㄇㄚ˙\t嗎\t-4
        ㄒㄧㄝˋ-ㄒㄧㄝ˙\t謝謝\t-3
        ㄒㄩㄝˊ-ㄕㄥ\t學生\t-3
        """)
    }
    func testHardwareMapCoversEverySymbolOnce() {
        let mapped = ZhuyinKeyboard.labels.values.filter { ZhuyinKeyboard.symbols[$0] != nil }
        XCTAssertEqual(mapped.count, 37)
        XCTAssertEqual(Set(mapped), Set(ZhuyinKeyboard.symbols.keys))
        XCTAssertEqual(ZhuyinKeyboard.labels[45], "n")
        XCTAssertEqual(ZhuyinKeyboard.labels[28], "8")
        XCTAssertEqual(ZhuyinKeyboard.labels[27], "-")
    }
    func testToneKeysAndSpaceEndSyllables() {
        let input = composition("su3cl3a87")
        XCTAssertEqual(input.parsed.complete.map(\.reading), ["ㄋㄧˇ", "ㄏㄠˇ", "ㄇㄚ˙"])
        XCTAssertEqual(composition("vm,6g/ ").parsed.complete.map(\.reading), ["ㄒㄩㄝˊ", "ㄕㄥ"])
    }
    func testBackspaceRestoresPendingPhoneticEvidence() {
        var input = composition("su3")
        input.backspace()
        XCTAssertEqual(input.rawKeys, ["s", "u"])
        XCTAssertEqual(input.pendingText, "ㄋㄧ")
        XCTAssertTrue(input.parsed.complete.isEmpty)
    }
    func testPendingSyllableWaitsForToneOrCommit() {
        let input = composition("su3cl")
        XCTAssertEqual(input.syllables(finishing: false).count, 1)
        XCTAssertEqual(input.syllables(finishing: true).count, 2)
        XCTAssertEqual(decoder.decode(input.syllables(finishing: true)).first?.text, "你好")
    }
    func testComposesAnUnlistedSentenceFromMultipleWords() {
        let input = composition("su3cl3a87vu,4vu,7")
        let result = decoder.decode(input.syllables(finishing: true))
        XCTAssertEqual(result.first?.text, "你好嗎謝謝")
        XCTAssertEqual(result.first?.unresolved, 0)
        XCTAssertLessThanOrEqual(result.count, 16)
    }
    func testFuzzyRescuesInvalidSyllableWithoutTone() {
        let input = composition("du") // ㄎㄧ has adjacent ㄋㄧ as a hypothesis
        let result = decoder.decode(input.syllables(finishing: true))
        XCTAssertEqual(result.first?.text, "你")
        XCTAssertEqual(result.first?.repairs, 1)
        XCTAssertEqual(decoder.decode(input.syllables(finishing: true), fuzzy: false).first?.text, "ㄎㄧ")
    }
    func testValidSyllablesRemainExact() {
        let result = decoder.decode(composition("su3").syllables(finishing: true))
        XCTAssertEqual(result.first?.text, "你")
        XCTAssertEqual(result.first?.repairs, 0)
    }
    func testUnknownInputIsPreserved() {
        let result = decoder.decode(composition("zzzz3").syllables(finishing: true))
        XCTAssertEqual(result.first?.text, "ㄈㄈㄈㄈˇ")
        XCTAssertEqual(result.first?.unresolved, 1)
    }
    func testSpaceTerminatedSyllableLeavesToneToEngine() {
        let input = composition("su cl ")
        let parsed = input.parsed
        XCTAssertEqual(parsed.complete.map(\.reading), ["ㄋㄧ", "ㄏㄠ"])
        let result = decoder.decodeComposition(complete: parsed.complete, pendingKeys: parsed.pending)
        XCTAssertEqual(result.first?.text, "你好")
        XCTAssertEqual(result.first?.unresolved, 0)
    }
    func testContinuousTonelessInputSegmentsWithoutSpaces() {
        let input = composition("sucl")
        XCTAssertTrue(input.parsed.complete.isEmpty)
        let parsed = input.parsed
        let result = decoder.decodeComposition(complete: parsed.complete, pendingKeys: parsed.pending)
        XCTAssertEqual(result.first?.text, "你好")
        XCTAssertEqual(result.first?.unresolved, 0)
    }
    func testTonedInputStillMatchesExactly() {
        let input = composition("su3cl3")
        let parsed = input.parsed
        let result = decoder.decodeComposition(complete: parsed.complete, pendingKeys: parsed.pending)
        XCTAssertEqual(result.first?.text, "你好")
        XCTAssertEqual(result.first?.repairs, 0)
    }
    func testDeleteLastSyllableRemovesOneBoundaryChunk() {
        var input = composition("su3cl3")
        input.deleteLastSyllable()
        XCTAssertEqual(input.rawKeys, ["s", "u", "3"])
        input.deleteLastSyllable()
        XCTAssertTrue(input.isEmpty)
    }
    func testCjkPunctuationTable() {        XCTAssertEqual(Punctuation.output(keyCode: 43, shift: true), "，")
        XCTAssertEqual(Punctuation.output(keyCode: 47, shift: true), "。")
        XCTAssertEqual(Punctuation.output(keyCode: 44, shift: true), "？")
        XCTAssertEqual(Punctuation.output(keyCode: 18, shift: true), "！")
        XCTAssertEqual(Punctuation.output(keyCode: 41, shift: true), "：")
        XCTAssertEqual(Punctuation.output(keyCode: 39, shift: false), "「")
        XCTAssertEqual(Punctuation.output(keyCode: 39, shift: true), "」")
        XCTAssertEqual(Punctuation.output(keyCode: 33, shift: false), "『")
        XCTAssertEqual(Punctuation.output(keyCode: 30, shift: false), "』")
        XCTAssertEqual(Punctuation.output(keyCode: 42, shift: false), "、")
        XCTAssertEqual(Punctuation.output(keyCode: 42, shift: true), "·")
        XCTAssertEqual(Punctuation.output(keyCode: 27, shift: true), "——")
        XCTAssertEqual(Punctuation.output(keyCode: 41, shift: false, ctrl: true), "；")
        // Ctrl/Cmd must not hijack anything else; plain letters untouched.
        XCTAssertNil(Punctuation.output(keyCode: 0, shift: false, ctrl: true))
        XCTAssertNil(Punctuation.output(keyCode: 27, shift: false))
        // Zhuyin-position keys stay phonetic: no mapping unshifted, and
        // plain letters are untouched so Shift-hold Latin still passes through.
        XCTAssertNil(Punctuation.output(keyCode: 43, shift: false))
        XCTAssertNil(Punctuation.output(keyCode: 44, shift: false))
        XCTAssertNil(Punctuation.output(keyCode: 41, shift: false))
        XCTAssertNil(Punctuation.output(keyCode: 0, shift: false))
        XCTAssertNil(Punctuation.output(keyCode: 0, shift: true))
    }
    func testEraseRemovesWholeConvertedSyllable() {
        // Completed characters go one char per press; mid-syllable pending
        // still deletes one key (see next test).
        var input = composition("su3cl3")
        input.erase()
        XCTAssertEqual(input.rawKeys, ["s", "u", "3"])
        XCTAssertEqual(input.parsed.complete.map(\.reading), ["ㄋㄧˇ"])
    }
    func testEraseRemovesOneKeyWhilePending() {
        // Mid-syllable: erase edits keys, preserving the converted prefix.
        var input = composition("su3cl")
        input.erase()
        XCTAssertEqual(input.rawKeys, ["s", "u", "3", "c"])
        XCTAssertEqual(input.parsed.complete.map(\.reading), ["ㄋㄧˇ"])
    }
    func testDeleteLastSyllableOnIncompleteTail() {
        var input = composition("su3cl")
        input.deleteLastSyllable()
        XCTAssertEqual(input.rawKeys, ["s", "u", "3"])
    }
    func testFusedTonelessRunRepairsToneOntoTrailingPiece() {
        // "sucl" fused by one mid-sentence ˇ must still read 你好.
        let result = decoder.decodeComposition(
            complete: [Syllable(keys: ["s", "u", "c", "l"], tone: "ˇ")], pendingKeys: [])
        XCTAssertEqual(result.first?.text, "你好")
        XCTAssertEqual(result.first?.unresolved, 0)
    }
    func testWrongToneStillResolvesWithRepairPenalty() {
        // su4 is ㄋㄧˋ, but the fixture lexicon only knows 你 (ㄋㄧˇ):
        // tone mismatch must stay viable instead of falling back to raw.
        let result = decoder.decodeComposition(
            complete: [Syllable(keys: ["s", "u"], tone: "ˋ")], pendingKeys: [])
        XCTAssertEqual(result.first?.text, "你")
        XCTAssertEqual(result.first?.repairs, 1)
    }
    func testLateToneAttachesToLastBoundary() {
        var input = composition("su cl ")
        XCTAssertTrue(input.retoneLast("3"))
        XCTAssertEqual(input.parsed.complete.map(\.reading), ["ㄋㄧ", "ㄏㄠˇ"])
        var corrected = composition("su3")
        XCTAssertTrue(corrected.retoneLast("4"))
        XCTAssertEqual(corrected.parsed.complete.map(\.reading), ["ㄋㄧˋ"])
        var empty = Composition()
        XCTAssertFalse(empty.retoneLast("3"))
    }
    func testTransposedKeysRepairToValidReading() {
        // "us3" is ㄧㄋˇ (invalid); swapping back gives 你 (ㄋㄧˇ).
        let result = decoder.decodeComposition(
            complete: [Syllable(keys: ["u", "s"], tone: "ˇ")], pendingKeys: [])
        XCTAssertEqual(result.first?.text, "你")
        XCTAssertEqual(result.first?.repairs, 1)
    }
    func testExtraKeyDeletionRepair() {
        // "gsu3" has a stray ㄕ key; dropping it gives 你.
        let result = decoder.decodeComposition(
            complete: [Syllable(keys: ["g", "s", "u"], tone: "ˇ")], pendingKeys: [])
        XCTAssertEqual(result.first?.text, "你")
        XCTAssertEqual(result.first?.repairs, 1)
    }
        func testMissingKeyInsertionRepair() {        // "s3" is bare ㄋˇ (invalid); inserting ㄧ gives 你.
        let result = decoder.decodeComposition(
            complete: [Syllable(keys: ["s"], tone: "ˇ")], pendingKeys: [])
        XCTAssertEqual(result.first?.text, "你")
        XCTAssertEqual(result.first?.repairs, 1)
    }
    func testPunctuationStaysInsideComposition() {
        // 你好，謝謝：words never span ，, punctuation passes through.
        let segments: [Composition.Segment] = [
            .syllable(Syllable(keys: ["s", "u"], tone: "ˇ")),
            .punct("，"),
            .syllable(Syllable(keys: ["v", "u", ","], tone: "ˋ")),
            .syllable(Syllable(keys: ["v", "u", ","], tone: "˙")),
        ]
        let result = decoder.decodeSegments(segments, pendingKeys: [])
        XCTAssertEqual(result.first?.text, "你，謝謝")
        XCTAssertEqual(result.first?.unresolved, 0)
    }
    func testEraseAcrossPunctuationBoundary() {
        var input = composition("su3")
        input.appendLiteral("，")
        XCTAssertEqual(input.segments.count, 2)
        input.erase() // trailing punct deletes alone…
        XCTAssertEqual(input.rawKeys, ["s", "u", "3"])
        input.erase() // …then the whole converted syllable goes.
        XCTAssertTrue(input.isEmpty)
    }
    func testDeleteLastSyllableStopsAtPunctuation() {        var input = composition("su3cl3")
        input.appendLiteral("，")
        input.deleteLastSyllable()
        XCTAssertEqual(input.rawKeys, ["s", "u", "3", "c", "l", "3"])
    }
    func testDecodeSegmentsRepairsFusedToneRun() {
        // Regression: decodeSegments once bypassed repairComplete, so a
        // toneless head fused onto a toned tail (太無調+好ˇ) fell back to raw.
        // Fixture-phrased: su fused onto cl3 must still read 你好.
        let segments: [Composition.Segment] = [
            .syllable(Syllable(keys: ["s", "u", "c", "l"], tone: "ˇ")),
        ]
        let result = decoder.decodeSegments(segments, pendingKeys: [])
        XCTAssertEqual(result.first?.text, "你好")
        XCTAssertEqual(result.first?.unresolved, 0)
    }
    func testDecodeSegmentsRepairsOneToneForTwoSyllables() {
        // Same fused shape but the lone tone belongs to neither syllable
        // exactly (ˋ on 好): tolerance still yields 你好 with a repair.
        let segments: [Composition.Segment] = [
            .syllable(Syllable(keys: ["s", "u", "c", "l"], tone: "ˋ")),
        ]
        let result = decoder.decodeSegments(segments, pendingKeys: [])
        XCTAssertEqual(result.first?.text, "你好")
        XCTAssertEqual(result.first?.repairs, 1)
    }
    func testSpaceSeparatesWithoutCommitting() {
        // "su3 cl" keeps one composition: 你 + literal space + pending ㄏㄠ.
        var input = composition("su3")
        XCTAssertTrue(input.appendSpace())
        XCTAssertTrue(input.append("c"))
        XCTAssertTrue(input.append("l"))
        XCTAssertEqual(input.parsed.complete.map(\.reading), ["ㄋㄧˇ"])
        XCTAssertEqual(input.parsed.pending, ["c", "l"])
        let result = decoder.decodeSegments(input.segments, pendingKeys: input.parsed.pending)
        XCTAssertEqual(result.first?.text, "你 好")
    }
    func testPhoneticConfusionRepairsMedialSlip() {
        // "sm3" is ㄋㄩˇ (m=ㄩ for u=ㄧ slip — far apart on QWERTY, so
        // neighbor rescue cannot see it); the ㄧㄨㄩ group must yield 你.
        let result = decoder.decodeComposition(
            complete: [Syllable(keys: ["s", "m"], tone: "ˇ")], pendingKeys: [])
        XCTAssertEqual(result.first?.text, "你")
        XCTAssertEqual(result.first?.repairs, 1)
    }
    func testDropThroughLastBoundaryKeepsTrailingRun() {
        // Digit-select commits the pick and keeps typing the rest: su3cl
        // drops su3 (with its tone), keeping pending cl.
        var input = composition("su3cl")
        input.dropThroughLastBoundary()
        XCTAssertEqual(input.rawKeys, ["c", "l"])
        // All converted: everything goes.
        var done = composition("su3cl3")
        done.dropThroughLastBoundary()
        XCTAssertTrue(done.isEmpty)
        // Punctuation boundary drops with the committed part.
        var punct = composition("su3")
        punct.appendLiteral("，")
        punct.append("c")
        punct.dropThroughLastBoundary()
        XCTAssertEqual(punct.rawKeys, ["c"])
    }
    func testMultiWordLatinRunSurvivesSpaces() {
        // `hello world su3cl3: spaces stay inside the latin run; the whole
        // span still commits once.
        var input = Composition()
        for key in ["h", "e", "l", "l", "o"] { _ = input.appendLatin(String(key)) }
        _ = input.appendSpace()
        for key in ["w", "o", "r", "l", "d"] { _ = input.appendLatin(String(key)) }
        _ = input.appendSpace()
        for key in ["s", "u", "3", "c", "l", "3"] { _ = input.append(String(key)) }
        let result = decoder.decodeSegments(input.segments, pendingKeys: input.parsed.pending)
        XCTAssertEqual(result.first?.text, "hello world 你好")
        XCTAssertEqual(result.first?.unresolved, 0)
    }
    func testMixedLatinRunPassesThrough() {        // `hello toneless 你好: latin seps join, Zhuyin runs decode.
        var input = Composition()
        for key in ["h", "e", "l", "l", "o"] { _ = input.appendLatin(String(key)) }
        _ = input.appendSpace()
        for key in ["s", "u", "c", "l"] { _ = input.append(String(key)) }
        let result = decoder.decodeSegments(input.segments, pendingKeys: input.parsed.pending)
        XCTAssertEqual(result.first?.text, "hello 你好")
        XCTAssertEqual(input.pendingText, "ㄋㄧㄏㄠ")
    }
    func testLatinBackspaceAndEraseStayCharwise() {
        var input = Composition()
        _ = input.appendLatin("A")
        _ = input.appendLatin("I")
        input.erase() // trailing latin deletes one char…
        XCTAssertEqual(input.rawKeys, ["L:A"])
        XCTAssertEqual(input.pendingText, "") // latin shows via converted
        input.deleteLastSyllable() // …never drags previous runs.
        XCTAssertTrue(input.isEmpty)
        var mixed = composition("su3")
        _ = mixed.appendLatin("x")
        mixed.deleteLastSyllable()
        XCTAssertEqual(mixed.rawKeys, ["s", "u", "3"])
    }
    func testHasUnfinishedTail() {
        XCTAssertFalse(composition("su3cl3").hasUnfinishedTail)
        XCTAssertTrue(composition("su3cl").hasUnfinishedTail)
        var latin = composition("su3")
        _ = latin.appendLatin("x")
        XCTAssertTrue(latin.hasUnfinishedTail)
        var punct = composition("su3")
        punct.appendLiteral("，")
        XCTAssertFalse(punct.hasUnfinishedTail)
        XCTAssertFalse(Composition().hasUnfinishedTail)
    }
    func testSpaceTerminatedFirstToneRanksExactFirst() {
        // "vm, g/ " (space-terminated): exact ㄕㄥ scores 0 while ㄒㄩㄝ has
        // no first-tone form (0.5), so 學生 lands at -3.5; the toneless-nil
        // twin pays 0.5+0.5 and lands at -4.0. Either way top-1 holds.
        let spaced = decoder.decode([Syllable(keys: ["v", "m", ","], tone: ""),
                                     Syllable(keys: ["g", "/"], tone: "")])
        XCTAssertEqual(spaced.first?.text, "學生")
        XCTAssertEqual(spaced.first?.score ?? 0, -3.5, accuracy: 1e-9)
        let bare = decoder.decode([Syllable(keys: ["v", "m", ","], tone: nil),
                                   Syllable(keys: ["g", "/"], tone: nil)])
        XCTAssertEqual(bare.first?.text, "學生")
        XCTAssertEqual(bare.first?.score ?? 0, -4.0, accuracy: 1e-9)
        let tonelessSpace = decoder.decodeComposition(
            complete: [Syllable(keys: ["s", "u"], tone: ""),
                       Syllable(keys: ["c", "l"], tone: "")], pendingKeys: [])
        XCTAssertEqual(tonelessSpace.first?.text, "你好")
    }
    func testStrictToneRejectsMismatch() {
        // toneTolerance:false — su4 (ㄋㄧˋ) must NOT resolve to 你; with
        // tolerance it does (repairs 1). Ultra-strict falls back to raw.
        let strict = decoder.decode([Syllable(keys: ["s", "u"], tone: "ˋ")],
                                    fuzzy: true, toneTolerance: false)
        XCTAssertEqual(strict.first?.text, "ㄋㄧˋ")
        XCTAssertEqual(strict.first?.unresolved, 1)
        let tolerant = decoder.decode([Syllable(keys: ["s", "u"], tone: "ˋ")],
                                      fuzzy: true, toneTolerance: true)
        XCTAssertEqual(tolerant.first?.text, "你")
        XCTAssertEqual(tolerant.first?.repairs, 1)
    }
    func testFuzzyRepairOffKeepsToneless() {
        // fuzzyRepair:false — du (ㄎㄧ) cannot rescue to 你, but toneless
        // lookup still works (policy gates rescue, not toneless decoding).
        let off = decoder.decode(composition("du").syllables(finishing: true),
                                 fuzzy: false, toneTolerance: true)
        XCTAssertEqual(off.first?.text, "ㄎㄧ")
        XCTAssertEqual(off.first?.unresolved, 1)
        let toneless = decoder.decode(composition("sucl").syllables(finishing: true),
                                      fuzzy: false, toneTolerance: true)
        XCTAssertEqual(toneless.first?.text, "ㄋㄧㄏㄠ")
    }
    func testDropHeadKeepingTail() {
        var input = composition("su3cl")
        input.dropHeadKeepingTail()
        XCTAssertEqual(input.rawKeys, ["c", "l"])
        var done = composition("su3cl3")
        done.dropHeadKeepingTail()
        XCTAssertTrue(done.isEmpty)
        var latin = composition("su3")
        _ = latin.appendLatin("x")
        _ = latin.appendLatin("y")
        latin.dropHeadKeepingTail()
        XCTAssertEqual(latin.rawKeys, ["L:x", "L:y"])
        XCTAssertEqual(latin.trailingLatin, "xy")
        XCTAssertEqual(composition("su3").trailingLatin, "")
    }
    func testCaptureIsBoundedAndClearRemovesActiveInput() {
        var input = composition(String(repeating: "a", count: 300))
        XCTAssertEqual(input.rawKeys.count, 256)
        input.clear()
        XCTAssertTrue(input.isEmpty)
        XCTAssertFalse(input.append("3"))
    }
    // MARK: - User phrase learning (explicit opt-in overlay)
    func testUserLexiconFlipsTopOneAfterOneExplicitPick() {
        // Fixture prefers 你 (-5) over 妳 (-6); one explicit record (+6)
        // must flip the tie deterministically.
        var learned = UserLexicon()
        learned.record(key: UserLexicon.key(for: [Syllable(keys: ["s", "u"], tone: "ˇ")]),
                       text: "妳", at: Date(timeIntervalSince1970: 1))
        let result = decoder.decode(composition("su3").syllables(finishing: true),
                                    userLexicon: learned)
        XCTAssertEqual(result.first?.text, "妳")
        XCTAssertEqual(result.first?.score ?? 0, 0, accuracy: 1e-9) // -6 + 6
    }
    func testUserLexiconTonelessRetypeHitsTonedLearn() {
        // Toneless-continuous retype must hit the toned learn: the key is
        // toneless-concatenated on both sides.
        var learned = UserLexicon()
        learned.record(key: UserLexicon.key(for: [Syllable(keys: ["s", "u"], tone: "ˇ")]),
                       text: "妳", at: Date(timeIntervalSince1970: 1))
        let parsed = composition("su").parsed
        let result = decoder.decodeComposition(complete: parsed.complete,
                                               pendingKeys: parsed.pending,
                                               userLexicon: learned)
        XCTAssertEqual(result.first?.text, "妳")
    }
    func testUserLexiconBonusCapsWithRepeats() {
        var learned = UserLexicon()
        let key = UserLexicon.key(for: [Syllable(keys: ["s", "u"], tone: "ˇ")])
        for second in 1...6 {
            learned.record(key: key, text: "妳", at: Date(timeIntervalSince1970: Double(second)))
        }
        XCTAssertEqual(learned.bonus(key: key, text: "妳"), 10.0, accuracy: 1e-9)
        let result = decoder.decode(composition("su3").syllables(finishing: true),
                                    userLexicon: learned)
        XCTAssertEqual(result.first?.score ?? 0, 4.0, accuracy: 1e-9) // -6 + 10
    }
    func testUserLexiconLeavesUnrelatedInputAlone() {
        // Empty overlay and unrelated learns must be byte-identical.
        var learned = UserLexicon()
        learned.record(key: UserLexicon.key(for: [Syllable(keys: ["s", "u"], tone: "ˇ")]),
                       text: "妳", at: Date(timeIntervalSince1970: 1))
        let plain = decoder.decodeComposition(
            complete: [Syllable(keys: ["s", "u"], tone: "ˇ"),
                       Syllable(keys: ["c", "l"], tone: "ˇ")], pendingKeys: [])
        let empty = decoder.decodeComposition(
            complete: [Syllable(keys: ["s", "u"], tone: "ˇ"),
                       Syllable(keys: ["c", "l"], tone: "ˇ")], pendingKeys: [],
            userLexicon: UserLexicon())
        XCTAssertEqual(plain.map(\.text), empty.map(\.text))
        XCTAssertEqual(plain.map(\.score), empty.map(\.score))
        let boosted = decoder.decodeComposition(
            complete: [Syllable(keys: ["s", "u"], tone: "ˇ"),
                       Syllable(keys: ["c", "l"], tone: "ˇ")], pendingKeys: [],
            userLexicon: learned)
        XCTAssertEqual(boosted.first?.text, "你好") // 妳-learn does not leak here
        XCTAssertEqual(boosted.first?.score ?? 0, plain.first?.score ?? 0, accuracy: 1e-9)
    }
    func testUserLexiconBoostsMultiSyllableSpan() {
        var learned = UserLexicon()
        learned.record(key: "ㄋㄧㄏㄠ", text: "你好", at: Date(timeIntervalSince1970: 1))
        let parsed = composition("su3cl3").parsed
        let result = decoder.decodeComposition(complete: parsed.complete,
                                               pendingKeys: parsed.pending,
                                               userLexicon: learned)
        XCTAssertEqual(result.first?.text, "你好")
        XCTAssertEqual(result.first?.score ?? 0, 3.0, accuracy: 1e-9) // -3 + 6
    }
    func testLearnableKeyGatesMixedSpans() {
        XCTAssertEqual(composition("su3cl3").learnableKey, "ㄋㄧㄏㄠ")
        // Pending tail blob joins the key (toneless-continuous learns).
        XCTAssertEqual(composition("su3cl").learnableKey, "ㄋㄧㄏㄠ")
        // Punctuation, latin, and separator spaces veto v1 learning.
        var punct = composition("su3")
        punct.appendLiteral("，")
        XCTAssertNil(punct.learnableKey)
        var latin = composition("su3")
        _ = latin.appendLatin("x")
        XCTAssertNil(latin.learnableKey)
        var spaced = composition("su3")
        _ = spaced.appendSpace()
        _ = spaced.append("c")
        XCTAssertNil(spaced.learnableKey)
        XCTAssertNil(Composition().learnableKey)
    }
    func testUserLexiconStoreRoundTripAndEviction() throws {        var learned = UserLexicon()
        learned.record(key: "ㄋㄧ", text: "妳", at: Date(timeIntervalSince1970: 7))
        let restored = try UserLexicon.decoded(from: learned.encoded())
        XCTAssertEqual(restored, learned)
        XCTAssertEqual(restored.bonus(key: "ㄋㄧ", text: "妳"), 6.0, accuracy: 1e-9)
        // Cap is enforced deterministically: oldest lowest-count entry goes.
        var full = UserLexicon()
        for index in 0...UserLexicon.entryCap {
            full.record(key: "k\(index)", text: "文",
                        at: Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertEqual(full.count, UserLexicon.entryCap)
        XCTAssertNil(full.entries["k0"])
        XCTAssertNotNil(full.entries["k\(UserLexicon.entryCap)"])
    }
    // MARK: - Syllable cursor groundwork (alignment, locks, segments)
    func testDecodeFillsWordAlignment() {
        let result = decoder.decode(composition("su3cl3").syllables(finishing: true))
        XCTAssertEqual(result.first?.text, "你好")
        XCTAssertEqual(result.first?.alignment,
                       [WordSpan(syllables: 0..<2, chars: 0..<2)])
    }
    func testAlignmentCoversUnresolvedInput() {
        // "zzzz3" parses as ONE fused syllable (tone-terminated), so the raw
        // fallback covers a single span — contiguity over 0..<1.
        let result = decoder.decode(composition("zzzz3").syllables(finishing: true))
        let top = result.first
        XCTAssertEqual(top?.unresolved, 1)
        let covered = top?.alignment.map(\.syllables) ?? []
        XCTAssertEqual(covered.first?.lowerBound, 0)
        XCTAssertEqual(covered.last?.upperBound, 1)
        for pair in zip(covered, covered.dropFirst()) {
            XCTAssertEqual(pair.0.upperBound, pair.1.lowerBound)
        }
    }
    func testHardLockForcesPinnedWord() {
        // 妳 (-6) loses to 你 (-5) without help; a session pin on the span
        // must force it, while other spans stay free.
        var pins = UserLexicon()
        pins.entries[UserLexicon.key(for: [Syllable(keys: ["s", "u"], tone: "ˇ")])] = [
            "妳": UserLexicon.Record(count: 1, updatedAt: 1)]
        let result = decoder.decode(composition("su3cl3").syllables(finishing: true),
                                    locked: pins)
        XCTAssertEqual(result.first?.text, "妳好")
        // No starvation: the unpinned rival stays available below the pin.
        XCTAssertTrue(result.contains(where: { $0.text == "你好" }))
    }
    func testHardLockLeavesUnpinnedSpansAlone() {
        var pins = UserLexicon()
        pins.entries["ㄅㄨ"] = ["不": UserLexicon.Record(count: 1, updatedAt: 1)]
        let plain = decoder.decode(composition("su3cl3").syllables(finishing: true))
        let locked = decoder.decode(composition("su3cl3").syllables(finishing: true),
                                    locked: pins)
        XCTAssertEqual(locked.map(\.text), plain.map(\.text))
        XCTAssertEqual(locked.map(\.score), plain.map(\.score))
    }
    func testSegmentOptionsCoverFocusedSpan() {
        let syllables = composition("su3cl3").syllables(finishing: true)
        let head = decoder.segmentOptions(syllables, span: 0..<1)
        XCTAssertTrue(head.contains(where: { $0.text == "你" }))
        XCTAssertTrue(head.contains(where: { $0.text == "妳" }))
        XCTAssertEqual(head.map(\.score), head.map(\.score).sorted(by: >))
        let whole = decoder.segmentOptions(syllables, span: 0..<2)
        XCTAssertEqual(whole.first?.text, "你好")
        XCTAssertTrue(whole.count <= 16)
        XCTAssertTrue(decoder.segmentOptions(syllables, span: 1..<1).isEmpty)
        XCTAssertTrue(decoder.segmentOptions(syllables, span: 0..<9).isEmpty)
    }
    func testSegmentKeysSplitsPendingRun() {
        let segmentations = decoder.segmentKeys(["s", "u", "c", "l"], fuzzy: false)
        XCTAssertEqual(segmentations.first?.map(\.reading), ["ㄋㄧ", "ㄏㄠ"])
    }
    func testNodeCapKeepsBeyondTopThree() {
        // Regression: per-node cap 3 hid daily chars (鍵 sat at #22 under
        // ㄐㄧㄢˋ, unreachable by paging or learning). Fixture 尼/泥 are 4th/
        // 5th under ㄋㄧˇ and must be reachable; top-1 must not move.
        let syllables = composition("su3").syllables(finishing: true)
        let options = decoder.segmentOptions(syllables, span: 0..<1)
        XCTAssertTrue(options.contains(where: { $0.text == "尼" }))
        XCTAssertTrue(options.contains(where: { $0.text == "泥" }))
        let decoded = decoder.decode(syllables)
        XCTAssertTrue(decoded.contains(where: { $0.text == "尼" }))
        XCTAssertEqual(decoded.first?.text, "你")
    }
    func testPreeditWithCursorMarksPosition() {
        XCTAssertEqual(preeditWithCursor("你好嗎", caretUTF16: 0), "|你好嗎")
        XCTAssertEqual(preeditWithCursor("你好嗎", caretUTF16: 1), "你|好嗎")
        XCTAssertEqual(preeditWithCursor("你好嗎", caretUTF16: 3), "你好嗎|")
        // Out-of-range clamps instead of trapping.
        XCTAssertEqual(preeditWithCursor("你好", caretUTF16: 99), "你好|")
        XCTAssertEqual(preeditWithCursor("你好", caretUTF16: -2), "|你好")
        XCTAssertEqual(preeditWithCursor("", caretUTF16: 0), "|")
    }
    // MARK: - Jev gateway policy (explicit opt-in, offline default)
    func testJevDefaultsStayOffline() {
        let config = JevConfig()
        XCTAssertFalse(config.enabled)
        XCTAssertFalse(config.allowRichContext)
        XCTAssertFalse(config.hasKey)
        XCTAssertFalse(config.canAttempt)
        XCTAssertEqual(config.model, JevConfig.defaultModel)
    }
    func testJevRequiresExplicitEnableAndKey() {
        XCTAssertFalse(JevConfig(enabled: true).canAttempt) // no key
        XCTAssertFalse(JevConfig(apiKey: "k").canAttempt) // not enabled
        XCTAssertFalse(JevConfig(enabled: true, apiKey: "   ").canAttempt)
        XCTAssertTrue(JevConfig(enabled: true, apiKey: "k").canAttempt)
    }
    func testJevResolveApiKeyPrefersPrefsOverEnv() {
        XCTAssertEqual(JevConfig.resolveApiKey(preferencesKey: "pref",
                                               environment: ["AI_GATEWAY_API_KEY": "env"]), "pref")
        XCTAssertEqual(JevConfig.resolveApiKey(preferencesKey: "  ",
                                               environment: ["AI_GATEWAY_API_KEY": "env"]), "env")
        XCTAssertEqual(JevConfig.resolveApiKey(preferencesKey: "",
                                               environment: [:]), "")
    }
    func testJevMinimalStateOmitsRichFields() {
        let evidence = [JevState.Evidence(base: "ㄋㄧ", tone: "ˇ")]
        let candidates = [(text: "你", score: -5.0, repairs: 0, unresolved: 0)]
        let minimal = JevState.build(rawKeys: "su3", evidence: evidence,
                                     candidates: candidates, richContext: false)
        XCTAssertNotNil((minimal["phonetic_input"] as? [String: Any])?["raw_keys"])
        XCTAssertNil(minimal["decoder_contract"])
        let rows = minimal["candidates"] as? [[String: Any]]
        XCTAssertEqual(rows?.first?["text"] as? String, "你")
        XCTAssertNil(rows?.first?["phonetic_alignment"])
        XCTAssertNil(rows?.first?["diff_from_candidate_1"])
    }
    func testJevRichStateAddsGatedMetadata() {
        let evidence = [JevState.Evidence(base: "ㄋㄧ", tone: "ˇ")]
        let candidates = [(text: "你", score: -5.0, repairs: 0, unresolved: 0),
                          (text: "妳", score: -6.0, repairs: 0, unresolved: 0)]
        let rich = JevState.build(rawKeys: "su3", evidence: evidence,
                                  candidates: candidates, richContext: true)
        XCTAssertNotNil(rich["decoder_contract"])
        let rows = rich["candidates"] as? [[String: Any]]
        XCTAssertEqual(rows?.count, 2)
        XCTAssertNotNil(rows?.first?["phonetic_alignment"])
        XCTAssertNotNil(rows?.first?["diff_from_candidate_1"])
    }
    func testJevGateLeavesOfflineDecodeUntouched() {
        // The gate is policy-only: an enabled+keyed config must still decode
        // byte-identically through the offline engine (no rerank wired).
        let syllables = composition("su3cl3").syllables(finishing: true)
        let plain = decoder.decode(syllables)
        let gated = decoder.decode(syllables) // JevConfig.canAttempt gates the caller, never decode()
        XCTAssertTrue(JevConfig(enabled: true, apiKey: "k").canAttempt)
        XCTAssertEqual(gated.map(\.text), plain.map(\.text))
        XCTAssertEqual(gated.map(\.score), plain.map(\.score))
    }

    // MARK: - Surrounding context extraction
    final class MockTextInputContextClient: TextInputContextClient {
        var marked: NSRange
        var selected: NSRange
        var text: String
        var bundleID: String?

        init(text: String = "",
             marked: NSRange = NSRange(location: NSNotFound, length: 0),
             selected: NSRange = NSRange(location: NSNotFound, length: 0),
             bundleID: String? = nil) {
            self.text = text
            self.marked = marked
            self.selected = selected
            self.bundleID = bundleID
        }

        func markedRange() -> NSRange { marked }
        func selectedRange() -> NSRange { selected }
        func substring(in range: NSRange) -> String? {
            let utf16 = Array(text.utf16)
            guard range.location != NSNotFound,
                  range.location >= 0,
                  range.location + range.length <= utf16.count else {
                return nil
            }
            return String(decoding: utf16[range.location..<(range.location + range.length)], as: UTF16.self)
        }
        func bundleIdentifier() -> String? { bundleID }
    }

    func testSurroundingContextNilClientReturnsEmpty() {
        XCTAssertEqual(SurroundingContext.extractPrecedingText(from: nil), "")
        let context = SurroundingContext.extract(from: nil)
        XCTAssertTrue(context.isEmpty)
        XCTAssertNil(context.bundleIdentifier)
    }

    func testSurroundingContextFromSelectedRange() {
        let client = MockTextInputContextClient(
            text: "Hello world",
            selected: NSRange(location: 11, length: 0)
        )
        let extracted = SurroundingContext.extractPrecedingText(from: client, maxCharacters: 5)
        XCTAssertEqual(extracted, "world")
    }

    func testSurroundingContextFromMarkedRangePrecedesSelectedRange() {
        // Active composition at (10, 4), cursor at (14, 0).
        // The preceding text must anchor at 10, not 14.
        let client = MockTextInputContextClient(
            text: "Preceding 1234 tail",
            marked: NSRange(location: 10, length: 4),
            selected: NSRange(location: 14, length: 0)
        )
        let extracted = SurroundingContext.extractPrecedingText(from: client, maxCharacters: 5)
        XCTAssertEqual(extracted, "ding ")
    }

    func testSurroundingContextClampAtDocumentStart() {
        let client = MockTextInputContextClient(
            text: "abc",
            selected: NSRange(location: 3, length: 0)
        )
        let extracted = SurroundingContext.extractPrecedingText(from: client, maxCharacters: 50)
        XCTAssertEqual(extracted, "abc")
    }

    func testSurroundingContextCursorAtStartReturnsEmpty() {
        let client = MockTextInputContextClient(
            text: "abc",
            selected: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(SurroundingContext.extractPrecedingText(from: client), "")
    }

    func testSurroundingContextNotFoundRangesReturnEmpty() {
        let client = MockTextInputContextClient(
            text: "abc",
            marked: NSRange(location: NSNotFound, length: 0),
            selected: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertEqual(SurroundingContext.extractPrecedingText(from: client), "")
    }

    func testSurroundingContextSanitizesControlChars() {
        let textWithControl = "\u{0000}Hello\u{0007}\tworld\n"
        let sanitized = SurroundingContext.sanitize(textWithControl)
        XCTAssertEqual(sanitized, "Hello\tworld\n")
    }

    func testSurroundingContextChineseUtf16() {
        let chinese = "這是一個輸入法測試，"
        let client = MockTextInputContextClient(
            text: chinese,
            selected: NSRange(location: (chinese as NSString).length, length: 0)
        )
        let extracted = SurroundingContext.extractPrecedingText(from: client, maxCharacters: 5)
        XCTAssertEqual(extracted, "入法測試，")
    }

    func testSurroundingContextExtractsBundleIdentifier() {
        let client = MockTextInputContextClient(
            text: "context",
            selected: NSRange(location: 7, length: 0),
            bundleID: "com.apple.dt.Xcode"
        )
        let context = SurroundingContext.extract(from: client)
        XCTAssertEqual(context.precedingText, "context")
        XCTAssertEqual(context.bundleIdentifier, "com.apple.dt.Xcode")
    }
}


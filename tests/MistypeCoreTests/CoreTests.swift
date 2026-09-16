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
        XCTAssertLessThanOrEqual(result.count, 8)
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
    func testCaptureIsBoundedAndClearRemovesActiveInput() {
        var input = composition(String(repeating: "a", count: 300))
        XCTAssertEqual(input.rawKeys.count, 256)
        input.clear()
        XCTAssertTrue(input.isEmpty)
        XCTAssertFalse(input.append("3"))
    }
}

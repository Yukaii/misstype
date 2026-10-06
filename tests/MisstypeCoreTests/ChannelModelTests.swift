import XCTest
@testable import MisstypeCore

final class ChannelModelTests: XCTestCase {
    // g = ㄕ, p = ㄣ, / = ㄥ; Space = first tone.
    private func top(_ decoder: LexiconDecoder, _ keys: String) -> SentenceCandidate? {
        var composition = Composition()
        for key in keys { _ = key == " " ? composition.appendSpace() : composition.append(String(key)) }
        return decoder.decodeSegments(composition.segments, pendingKeys: composition.parsed.pending).first
    }

    func testPersonalPairCheapensOnlyThatRepair() {
        let decoder = LexiconDecoder(tsv: "ㄕㄣ\t深\t-5\nㄕㄥ\t升\t-9\n")
        // Generic: 深 via ㄥ→ㄣ pays 5.0 (-10) and loses to the exact 升 (-9).
        XCTAssertEqual(top(decoder, "g/ ")?.text, "升")
        decoder.channel = ChannelModel(substitutions: ["/": ["p": 1.2]])
        let personal = top(decoder, "g/ ")
        XCTAssertEqual(personal?.text, "深")
        XCTAssertEqual(personal?.repairs, 1)
        // Directional: typing ㄣ gains nothing toward ㄥ.
        let reverse = LexiconDecoder(tsv: "ㄕㄣ\t深\t-9\nㄕㄥ\t升\t-5\n")
        reverse.channel = ChannelModel(substitutions: ["/": ["p": 1.2]])
        XCTAssertEqual(top(reverse, "gp ")?.text, "深")
    }

    func testFloorKeepsExactInputAhead() {
        let decoder = LexiconDecoder(tsv: "ㄕㄣ\t深\t-9\nㄕㄥ\t升\t-9\n")
        decoder.channel = ChannelModel(substitutions: ["/": ["p": 0]])
        XCTAssertEqual(top(decoder, "g/ ")?.text, "升")
    }

    func testEmptyChannelDecodesLikeNone() {
        let decoder = LexiconDecoder(tsv: "ㄕㄣ\t深\t-5\nㄕㄥ\t升\t-9\nㄕㄥ-ㄧㄣ\t聲音\t-6\n")
        let inputs = ["g/ ", "g/up", "gp ", "g/", "gpu/"]
        let plain = inputs.map { top(decoder, $0) }
        decoder.channel = ChannelModel()
        XCTAssertEqual(inputs.map { top(decoder, $0) }, plain)
    }

    // MARK: - Learning

    private func retype(_ typed: String, _ intended: String, opportunities: [String]) -> ChannelEvidence {
        var evidence = ChannelEvidence()
        evidence.intended = opportunities
        evidence.retypes = [(typed, intended)]
        return evidence
    }

    func testSteadySlipsWalkDownSlowlyToTheLearnedFloor() {
        var learner = ChannelLearner()
        var costs: [Double] = []
        // Every other ㄣ is typed ㄥ and re-typed: a 50% slip rate.
        for round in 0..<200 {
            var evidence = ChannelEvidence()
            evidence.intended = ["g", "p"]
            if round % 2 == 0 { evidence.retypes = [("/", "p")] }
            learner.observe(evidence)
            costs.append(learner.model?.substitutions["/"]?["p"] ?? ChannelLearner.genericCost)
        }
        // Bounded step: never more than stepDown per commit.
        for (a, b) in zip([ChannelLearner.genericCost] + costs, costs) {
            XCTAssertLessThanOrEqual(a - b, ChannelLearner.stepDown + 1e-9)
        }
        XCTAssertEqual(costs.last!, ChannelLearner.learnedFloor, accuracy: 1e-9)
        // Only the learned pair, and only in that direction.
        XCTAssertEqual(learner.model?.substitutions.keys.sorted(), ["/"])
    }

    func testNoSlipsKeepsGenericCosts() {
        var learner = ChannelLearner()
        for _ in 0..<500 {
            var evidence = ChannelEvidence()
            evidence.intended = ["g", "p", "/"]
            learner.observe(evidence)
        }
        XCTAssertNil(learner.model)
        // A rare slip against a large history stays near generic.
        learner.observe(retype("/", "p", opportunities: ["p"]))
        XCTAssertGreaterThan(learner.model?.substitutions["/"]?["p"] ?? 5, 4.7)
    }

    func testRevertsPushBackFasterThanSlipsPull() {
        var learner = ChannelLearner()
        for _ in 0..<60 { learner.observe(retype("/", "p", opportunities: ["p"])) }
        XCTAssertEqual(learner.model?.substitutions["/"]?["p"] ?? 5, ChannelLearner.learnedFloor, accuracy: 1e-9)
        var revert = ChannelEvidence()
        revert.intended = ["g", "/"]
        revert.reverts = [("/", "p")]
        var steps = 0
        while learner.model?.substitutions["/"]?["p"] != nil && steps < 100 {
            learner.observe(revert)
            steps += 1
        }
        // 60 slips undone by 20 reverts, at stepUp per commit.
        XCTAssertLessThanOrEqual(steps, 25)
    }

    func testDroppedHabitDecaysBackToGeneric() {
        var learner = ChannelLearner()
        for _ in 0..<60 { learner.observe(retype("/", "p", opportunities: ["p"])) }
        XCTAssertNotNil(learner.model)
        var clean = ChannelEvidence()
        clean.intended = Array(repeating: "p", count: 20)
        for _ in 0..<2000 { learner.observe(clean) }
        XCTAssertNil(learner.model)
    }

    func testLearnerRoundTripsThroughDisk() throws {
        var learner = ChannelLearner()
        for _ in 0..<10 { learner.observe(retype("/", "p", opportunities: ["p"])) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("channel-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        learner.save(to: url)
        XCTAssertEqual(ChannelLearner.load(from: url), learner)
    }

    // MARK: - Evidence

    func testEvidenceReadsRepairsAndReverts() {
        let decoder = LexiconDecoder(tsv: "ㄕㄣ\t深\t-5\nㄕㄥ\t升\t-9\n")
        decoder.channel = ChannelModel(substitutions: ["/": ["p": 1.2]])
        var composition = Composition()
        for key in ["g", "/"] { _ = composition.append(key) }
        _ = composition.appendSpace()
        let list = decoder.decodeSegments(composition.segments, pendingKeys: composition.parsed.pending)
        let repaired = try! XCTUnwrap(list.first)
        let exact = try! XCTUnwrap(list.first { $0.text == "升" })
        XCTAssertEqual(repaired.text, "深")
        // Unchallenged repair: one weak slip, ㄕㄣ as the opportunity.
        let accepted = decoder.channelEvidence(committed: repaired, unpicked: nil, explicit: false, retypes: [])
        XCTAssertEqual(accepted.intended, ["g", "p"])
        XCTAssertEqual(accepted.repaired.map { $0.typed + $0.intended }, ["/p"])
        XCTAssertTrue(accepted.reverts.isEmpty)
        // The user picked the exact text over the repair: a revert.
        let undone = decoder.channelEvidence(committed: exact, unpicked: repaired, explicit: true, retypes: [])
        XCTAssertEqual(undone.intended, ["g", "/"])
        XCTAssertTrue(undone.repaired.isEmpty)
        XCTAssertEqual(undone.reverts.map { $0.typed + $0.intended }, ["/p"])
    }

    private final class Host: InputSessionHost {
        func surroundingContext() -> ClientContext { ClientContext() }
        func perform(_ work: @escaping () -> Void) { work() }
        func sessionDidChange(_ session: InputSession) {}
    }

    func testSessionRecordsBackspaceRetypeOnCommit() {
        let decoder = LexiconDecoder(tsv: "ㄕㄣ\t深\t-5\nㄕㄥ\t升\t-9\n")
        var settings = SessionSettings(channelLearning: true)
        let engine = InputEngine(decoder: decoder, settings: { settings })
        let session = InputSession(engine: engine)
        let host = Host()
        session.host = host
        func press(_ keys: String) {
            for char in keys {
                let label = String(char)
                _ = session.handle(label == " " ? KeyEvent(.space, text: " ") : KeyEvent(.character(label), text: label))
            }
        }
        press("g/")
        _ = session.handle(KeyEvent(.backspace))
        press("p ")
        XCTAssertEqual(session.handle(KeyEvent(.enter, text: "\r")).commit, "深")
        XCTAssertEqual(engine.channelLearner.slips["/"]?["p"] ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(engine.channelLearner.opportunities["p"] ?? 0, 1, accuracy: 1e-9)
        // A rewrite of more than one key is not a slip.
        press("g/")
        _ = session.handle(KeyEvent(.backspace))
        _ = session.handle(KeyEvent(.backspace))
        press("ap ")
        _ = session.handle(KeyEvent(.enter, text: "\r"))
        XCTAssertEqual(engine.channelLearner.slips["/"]?["p"] ?? 0, 1, accuracy: 0.01)
        // Off: nothing learned, decoder overlay cleared.
        settings.channelLearning = false
        let before = engine.channelLearner
        press("g/")
        _ = session.handle(KeyEvent(.backspace))
        press("p ")
        _ = session.handle(KeyEvent(.enter, text: "\r"))
        XCTAssertEqual(engine.channelLearner, before)
        XCTAssertNil(decoder.channel)
    }
}

import Foundation
import XCTest
import MisstypeCore
@testable import MisstypeCtl

final class CtlTests: XCTestCase {
    private var dir: URL!
    private var lines: [String] = []
    private var errors: [String] = []
    private var ran: [(String, [String])] = []
    private var runStatus: Int32? = 0

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lines = []; errors = []; ran = []; runStatus = 0
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func ctl(_ args: String..., vars: [String: String] = [:]) -> Int32 {
        MisstypeCtl.run(args, environment: CtlEnvironment(
            variables: vars, out: { self.lines.append($0) }, err: { self.errors.append($0) },
            run: { program, arguments, _ in self.ran.append((program, arguments)); return self.runStatus }))
    }

    private var dict: String { dir.appendingPathComponent("user_dictionary.tsv").path }
    private var conf: String { dir.appendingPathComponent("misstype.conf").path }
    private func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    func testDictAddKeepsCommentsAndListsTsv() {
        try! "# mine\nㄋㄧˇ-ㄏㄠˇ\t你好\n".write(toFile: dict, atomically: true, encoding: .utf8)
        XCTAssertEqual(ctl("dict", "add", "ㄏㄨㄤˊ-ㄩˋ-ㄎㄞˇ", "黃昱愷", "--file", dict), 0)
        XCTAssertEqual(read(dict), "# mine\nㄋㄧˇ-ㄏㄠˇ\t你好\nㄏㄨㄤˊ-ㄩˋ-ㄎㄞˇ\t黃昱愷\n")
        lines = []
        XCTAssertEqual(ctl("dict", "list", "--tsv", "--file", dict), 0)
        XCTAssertEqual(lines, ["ㄋㄧˇ-ㄏㄠˇ\t你好", "ㄏㄨㄤˊ-ㄩˋ-ㄎㄞˇ\t黃昱愷"])
    }

    func testDictAddRejectsMismatchedLengthWithoutWriting() {
        XCTAssertEqual(ctl("dict", "add", "ㄋㄧˇ-ㄏㄠˇ", "你", "--file", dict), 1)
        XCTAssertTrue(errors.last?.contains("1 character for 2 syllables") == true, "\(errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dict))
    }

    func testAddReweightsAndLiftsExclusion() {
        _ = ctl("dict", "exclude", "ㄉㄚˇ-ㄉㄨㄟˋ", "打對", "--file", dict)
        XCTAssertTrue(read(dict).contains("!ㄉㄚˇ-ㄉㄨㄟˋ\t打對"))
        _ = ctl("dict", "add", "ㄉㄚˇ-ㄉㄨㄟˋ", "打對", "--weight", "-2", "--file", dict)
        XCTAssertEqual(read(dict), "ㄉㄚˇ-ㄉㄨㄟˋ\t打對\t-2.0\n")
    }

    func testRemoveAndUnexclude() {
        _ = ctl("dict", "add", "ㄋㄧˇ-ㄏㄠˇ", "你好", "--file", dict)
        XCTAssertEqual(ctl("dict", "remove", "ㄋㄧˇ-ㄏㄠˇ", "你好", "--file", dict), 0)
        XCTAssertEqual(ctl("dict", "remove", "ㄋㄧˇ-ㄏㄠˇ", "你好", "--file", dict), 1, "second remove: not there")
        XCTAssertEqual(ctl("dict", "unexclude", "ㄋㄧˇ-ㄏㄠˇ", "你好", "--file", dict), 1)
        XCTAssertTrue(UserDictionary.parse(read(dict)).dictionary.isEmpty)
    }

    func testCheckReportsBadLines() {
        try! "ㄋㄧˇ-ㄏㄠˇ\t你\n".write(toFile: dict, atomically: true, encoding: .utf8)
        XCTAssertEqual(ctl("dict", "check", "--file", dict), 1)
        XCTAssertTrue(errors.first?.contains(":1:") == true, "\(errors)")
    }

    func testEditRunsEditorThenChecks() {
        XCTAssertEqual(ctl("dict", "edit", "--file", dict, vars: ["EDITOR": "nano"]), 0)
        XCTAssertEqual(ran.first?.0, "nano")
        XCTAssertEqual(ran.first?.1, [dict])
        runStatus = nil
        XCTAssertEqual(ctl("dict", "edit", "--file", dict, vars: ["EDITOR": "nope"]), 1)
    }

    func testConfigSetGetResetKeepsOtherLinesAndReloads() {
        try! "# keep\nOther=1\nAutoShowCandidates=True\n".write(toFile: conf, atomically: true, encoding: .utf8)
        XCTAssertEqual(ctl("config", "set", "autoshowcandidates", "off", "--file", conf), 0)
        XCTAssertEqual(read(conf), "# keep\nOther=1\nAutoShowCandidates=False\n")
        XCTAssertEqual(ran.last?.0, "fcitx5-remote")
        XCTAssertEqual(ctl("config", "set", "AutoCommitSyllables", "12", "--file", conf, "--no-reload"), 0)
        XCTAssertEqual(ran.count, 1, "--no-reload does not call fcitx5-remote")
        lines = []
        XCTAssertEqual(ctl("config", "get", "AutoCommitSyllables", "--file", conf), 0)
        XCTAssertEqual(lines, ["12"])
        XCTAssertEqual(ctl("config", "reset", "AutoCommitSyllables", "--file", conf), 0)
        XCTAssertEqual(read(conf), "# keep\nOther=1\nAutoShowCandidates=False\n")
    }

    func testConfigChoicesStoreTheCanonicalName() {
        XCTAssertEqual(ctl("config", "set", "repairstrength", "light", "--file", conf, "--no-reload"), 0)
        XCTAssertEqual(ctl("config", "set", "CursorCandidates", "endingat", "--file", conf, "--no-reload"), 0)
        XCTAssertEqual(read(conf), "RepairStrength=Light\nCursorCandidates=EndingAt\n")
        lines = []
        XCTAssertEqual(ctl("config", "list", "--file", conf), 0)
        XCTAssertTrue(lines.contains("MixedEnglish=False  (default)"), "defaults follow macOS")
        XCTAssertTrue(lines.contains("CandidatesPerPage=8  (default)"))
    }

    func testConfigRejectsBadValues() {
        XCTAssertEqual(ctl("config", "set", "ToneTolerance", "maybe", "--file", conf), 1)
        XCTAssertEqual(ctl("config", "set", "RepairStrength", "max", "--file", conf), 1)
        XCTAssertEqual(ctl("config", "set", "CandidatesPerPage", "3", "--file", conf), 1)
        XCTAssertEqual(ctl("config", "set", "FuzzyRepair", "on", "--file", conf), 2, "replaced by RepairStrength")
        XCTAssertEqual(ctl("config", "set", "AutoCommitSyllables", "999", "--file", conf), 1)
        XCTAssertEqual(ctl("config", "set", "CandidateKeys", "aab", "--file", conf), 1)
        XCTAssertEqual(ctl("config", "set", "Nope", "1", "--file", conf), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: conf))
    }

    func testConfigPathFollowsXdg() {
        XCTAssertEqual(ctl("config", "path", vars: ["XDG_CONFIG_HOME": "/tmp/xc"]), 0)
        XCTAssertEqual(lines, ["/tmp/xc/fcitx5/conf/misstype.conf"])
    }
}

import Foundation
import MisstypeZigBridge

let probe = ZigEngineProbe()
print("abi=\(probe.abiVersion)")
guard CommandLine.arguments.count > 1 else { exit(0) }
let resources = CommandLine.arguments[1]
let text = probe.preedit(resourceDirectory: resources) ?? ""
print("preedit=\(text)")

// The calls the macOS Settings panes and key handling make through the bridge.
var failures = 0
func check(_ ok: Bool, _ what: String) {
    if !ok { print("FAIL \(what)"); failures += 1 }
}
check(text == "你", "synthetic composition")
guard let engine = ZigEngine(resourceDirectory: URL(fileURLWithPath: resources), userLexiconPath: "") else {
    print("FAIL engine creation")
    exit(1)
}
engine.setUserDictionaryPath("")
engine.setChannelPath("")
engine.setRepairStrength(3)
engine.setChannelLearning(true)
check(engine.learnedPhraseCount == 0, "no learned phrases in memory-only mode")
check(engine.channelPairs.isEmpty, "no learned slips")
check(!engine.isEnglish, "starts in Chinese mode")
engine.clearLearnedPhrases()
engine.clearChannel()

let check1 = ZigEngine.checkUserDictionary("你好 ㄋㄧˇ-ㄏㄠˇ\nbad row\n")
check(check1.added == 1 && check1.hidden == 0, "dictionary counts")
check(check1.problems.map(\.line) == [2], "dictionary problem lines")
let merged = ZigEngine.importUserDictionary("你好 ㄋㄧˇ-ㄏㄠˇ\n", into: "")
check(merged.added == 1 && merged.text.contains("你好 ㄋㄧˇ-ㄏㄠˇ"), "dictionary import")
check(ZigEngine.importUserDictionary("你好 ㄋㄧˇ-ㄏㄠˇ\n", into: merged.text).duplicates == 1, "import duplicates")

let a = ZigEngine.macKey(0)
check(a.kind.rawValue == 0 && a.label == "a", "mac keycode 0 is the key a")
check(ZigEngine.macKey(49).kind.rawValue == 1, "mac keycode 49 is space")
check(ZigEngine.macKey(121).kind.rawValue == 16, "mac keycode 121 is page down")
check(ZigEngine.macKey(56).kind.rawValue == 11, "mac keycode 56 is left shift")
print(failures == 0 ? "bridge ok" : "bridge FAILED (\(failures))")
exit(failures == 0 ? 0 : 1)

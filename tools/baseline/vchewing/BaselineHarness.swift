// Misstype baseline harness (NOT part of upstream vChewing). Drives the real
// InputHandler with keystroke strings read from a TSV and prints what a user
// would get on Enter. Used only for offline measurement; see
// tools/baseline/README.md in the Misstype repo.

import Foundation
import Shared
@testable import LexiconAssembly
import Testing

@testable import LibVanguard

extension LibVanguardTestsRoot.InputHandlerTests {
  @Test("[BASELINE] drive probes from VC_PROBES_IN to VC_PROBES_OUT")
  func test_BASELINE_Drive() throws {
    let env = ProcessInfo.processInfo.environment
    guard let inPath = env["VC_PROBES_IN"], let outPath = env["VC_PROBES_OUT"],
          let lexPath = env["VC_LEXICON"]
    else { return }  // not a measurement run
    guard let testHandler, let testSession else {
      Issue.record("handler/session missing")
      return
    }
    LXAssembly.LXFacade.asyncLoadingUserData = false  // load synchronously: the test thread never yields to the main queue
    LXAssembly.LXFacade.connectFactoryDictionary(textMapPath: lexPath)
    let configs = (env["VC_CONFIGS"] ?? "default").split(separator: ",").map(String.init)
    let lines = try String(contentsOfFile: inPath, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: true)
    var out = "config\tid\tcommitted\tms\tdisplayed\n"
    for config in configs {
      testHandler.prefs.cassetteEnabled = false
      testHandler.prefs.useSCPCTypingMode = false
      testHandler.prefs.furiousTypingEnabled4Pinyin = false
      testHandler.prefs.furiousTypingEnabled4Zhuyin = (config == "furious")
      testHandler.prefs.mixedAlphanumericalEnabled = (config == "mixed")
      for line in lines {
        let cells = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard cells.count == 2 else { continue }
        testHandler.composer.ensureParser(arrange: .ofDachen)
        testSession.resetInputHandler(forceComposerCleanup: true)
        testSession.recentCommissions.removeAll()
        let started = DispatchTime.now().uptimeNanoseconds
        typeSentence(String(cells[1]))
        let displayed = testHandler.assembler.assembledSentence.values.joined()
        _ = testHandler.triageInput(event: KBEvent.KeyEventData.dataEnterReturn.asEvent)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let committed = testSession.recentCommissions.joined()
        out += "\(config)\t\(cells[0])\t\(committed)\t\(String(format: "%.2f", ms))\t\(displayed)\n"
        testSession.resetInputHandler(forceComposerCleanup: true)
      }
    }
    try out.write(toFile: outPath, atomically: true, encoding: .utf8)
  }
}

extension LibVanguardTestsRoot.InputHandlerTests {
  @Test("[BASELINE-DEBUG] query LM")
  func test_BASELINE_Debug() throws {
    let env = ProcessInfo.processInfo.environment
    guard let lexPath = env["VC_LEXICON"], env["VC_DEBUG"] != nil else { return }
    guard let testHandler else { return }
    LXAssembly.LXFacade.asyncLoadingUserData = false  // load synchronously: the test thread never yields to the main queue
    LXAssembly.LXFacade.connectFactoryDictionary(textMapPath: lexPath)
    var dbg = "availability(before)=\(ResourceProvision.availabilityReport())\n"
    ResourceProvision.specifyBPMFVSTable(URL(fileURLWithPath: env["VC_BPMFVS"] ?? "/src/Sources/BPMFVS/Resources/phonic_table_Z.txt"))
    dbg += "availability(after)=\(ResourceProvision.availabilityReport())\n"
    if let trie = LXAssembly.LXFacade.factoryTrie {
      for ka in [["ㄊㄧㄢ", "ㄑㄧˋ"], ["ㄕˋ"]] {
        let nodes = trie.getNodes(keyArray: ka, filterType: [], partiallyMatch: false, longerSegment: false)
        let ents = nodes.flatMap(\.entries)
        dbg += "trie \(ka): nodes=\(nodes.count) entries=\(ents.count) sample=\(ents.prefix(4).map { "\($0.value)|\($0.typeID)|\($0.probability)" })\n"
      }
    } else { dbg += "factoryTrie nil\n" }
    dbg += "isCHS=\(testHandler.currentLM.isCHS)\n"
    for key in [["ㄊㄧㄢ", "ㄑㄧˋ"], ["ㄑㄧˋ"], ["ㄨㄛˇ", "ㄕˋ"], ["ㄕˋ"]] {
      let grams = testHandler.currentLM.unigramsFor(keyArray: key)
      dbg += "\(key) -> \(grams.count): \(grams.prefix(6).map { "\($0.current)(\($0.probability))" })\n"
    }
    dbg += "maxSegLength=\(testHandler.assembler.maxSegLength) isCHS=\(testHandler.currentLM.isCHS)\n"
    try? dbg.write(toFile: "/work/dbg.txt", atomically: true, encoding: .utf8)
  }
}

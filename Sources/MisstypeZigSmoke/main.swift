import Foundation
import MisstypeZigBridge

let probe = ZigEngineProbe()
print("abi=\(probe.abiVersion)")
if CommandLine.arguments.count > 1 {
    let text = probe.preedit(resourceDirectory: CommandLine.arguments[1]) ?? ""
    print("preedit=\(text)")
}

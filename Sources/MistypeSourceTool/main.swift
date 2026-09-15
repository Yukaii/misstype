import Carbon
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let prefix = "org.mistype.inputmethod.Mistype"
if args.first == "register", args.count == 2 {
    let status = TISRegisterInputSource(URL(fileURLWithPath: args[1]) as CFURL)
    guard status == noErr else { fputs("Registration failed: \(status)\n", stderr); exit(1) }
}
guard let result = TISCreateInputSourceList(nil, true)?.takeRetainedValue() else { exit(1) }
let sources = result as! [TISInputSource]
var count = 0
for source in sources {
    guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
    let identifier = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    guard identifier == prefix || identifier.hasPrefix(prefix + ".") else { continue }
    count += 1
    if args.first == "register" {
        let status = TISEnableInputSource(source)
        if status != noErr { fputs("Enable failed for \(identifier): \(status)\n", stderr); exit(1) }
    }
    if args.first == "disable" {
        let status = TISDisableInputSource(source)
        if status != noErr { fputs("Disable failed: \(status)\n", stderr); exit(1) }
    }
    let enabled = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled).map {
        CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue())
    } ?? false
    print("\(identifier) enabled=\(enabled)")
}
if count == 0 {
    fputs("Mistype is not visible to Text Input Services yet. Log out/in, then register again.\n", stderr)
    exit(2)
}

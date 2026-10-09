import Foundation
import MisstypeCtl

exit(MisstypeCtl.run(Array(CommandLine.arguments.dropFirst()), environment: .live))

#!/bin/zsh
set -euo pipefail
swift -e '
import Foundation

DistributedNotificationCenter.default().postNotificationName(
    NSNotification.Name("org.mistype.openPreferences"),
    object: nil,
    userInfo: nil,
    deliverImmediately: true
)
'
echo "Sent openPreferences notification to MistypeIME."

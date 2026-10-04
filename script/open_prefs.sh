#!/bin/zsh
set -euo pipefail
swift -e '
import Foundation

DistributedNotificationCenter.default().postNotificationName(
    NSNotification.Name("org.misstype.openPreferences"),
    object: nil,
    userInfo: nil,
    deliverImmediately: true
)
'
echo "Sent openPreferences notification to MisstypeIME."

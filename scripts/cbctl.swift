// Sends one automation command to a ComfyBar launched with `-ComfyBarAutomation YES`.
//   swiftc -O scripts/cbctl.swift -o <somewhere>/cbctl && cbctl state /tmp/s.json
import Foundation
let line = CommandLine.arguments.dropFirst().joined(separator: " ")
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.amritus.comfybar.automation"), object: line, userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.1))

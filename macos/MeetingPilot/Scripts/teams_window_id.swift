#!/usr/bin/env swift

import CoreGraphics
import Foundation

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windowInfos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    fputs("Could not list windows\n", stderr)
    exit(1)
}

let teamsWindows = windowInfos.compactMap { info -> (id: UInt32, area: Double, title: String, owner: String)? in
    let owner = info[kCGWindowOwnerName as String] as? String ?? ""
    let title = info[kCGWindowName as String] as? String ?? ""
    let layer = info[kCGWindowLayer as String] as? Int ?? -1
    guard owner.localizedCaseInsensitiveContains("Teams") || owner.localizedCaseInsensitiveContains("MSTeams") else {
        return nil
    }
    guard layer == 0 else {
        return nil
    }
    guard let windowID = info[kCGWindowNumber as String] as? UInt32,
          let bounds = info[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double,
          let height = bounds["Height"] as? Double else {
        return nil
    }
    guard width >= 300 && height >= 250 else {
        return nil
    }
    return (windowID, width * height, title, owner)
}

guard let target = teamsWindows.sorted(by: { $0.area > $1.area }).first else {
    fputs("No visible Teams window found\n", stderr)
    exit(1)
}

print(target.id)

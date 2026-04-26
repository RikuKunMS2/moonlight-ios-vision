//
//  MoonlightStreamActivity.swift
//  Moonlight Vision
//

import Foundation
import GroupActivities

struct MoonlightStreamActivity: GroupActivity {
    // Activity metadata
    var metadata: GroupActivityMetadata {
        var meta = GroupActivityMetadata()
        meta.title = NSLocalizedString("activity_title", value: "Watching Moonlight Stream", comment: "SharePlay activity title")
        meta.type = .watchTogether
        return meta
    }
}

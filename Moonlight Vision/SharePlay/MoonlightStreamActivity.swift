//
//  MoonlightStreamActivity.swift
//  Moonlight Vision
//
//  Created by Lumanaire (RikuKunMS2).
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
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

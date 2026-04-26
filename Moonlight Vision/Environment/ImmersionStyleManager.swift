//
//  ImmersionStyleManager.swift
//  Moonlight Vision
//
//  Created by Linggan-ua on 2025/12/03.
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI
import Combine

@MainActor
class ImmersionStyleManager: ObservableObject {
    static let shared = ImmersionStyleManager()
    
    @Published var currentStyle: ImmersionStyle = .mixed
    
    private init() {}
}


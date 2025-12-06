//
//  ImmersionStyleManager.swift
//  Moonlight Vision
//
//  Created by Linggan-ua on 2025/12/03.
//

import SwiftUI
import Combine

@MainActor
class ImmersionStyleManager: ObservableObject {
    static let shared = ImmersionStyleManager()
    
    @Published var currentStyle: ImmersionStyle = .mixed
    
    private init() {}
}


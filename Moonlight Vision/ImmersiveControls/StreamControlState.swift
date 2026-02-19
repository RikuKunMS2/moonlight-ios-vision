//
//  StreamControlState.swift
//  Moonlight Vision
//
//  Shared stream control state - for communication between control panel window and main view
//  Created by Linggan-ua on 2025/12/03.

import SwiftUI
import RealityKit
import Combine

/// Stream control state manager
/// Used to share state between independent control panel window and immersive space
@MainActor
class StreamControlState: ObservableObject {
    static let shared = StreamControlState()
    
    // MARK: - Control Panel State
    @Published var isControlPanelVisible: Bool = false
    
    // MARK: - Screen Control
    @Published var immersiveScale: Float = 1.8
    @Published var immersivePositionX: Float = 0
    @Published var immersivePositionY: Float = 1.5
    @Published var immersivePositionZ: Float = -2.0
    @Published var immersionAmount: Float = 0.0
    @Published var isInteractive: Bool = false
    
    // MARK: - Environment Control
    @Published var selectedEnvironmentState: EnvironmentStateType = .none
    @Published var isSemiImmersionEnabled: Bool = false
    @Published var isUpdatingImmersion: Bool = false
    
    // MARK: - Display Control
    @Published var isKeyboardActive: Bool = false
    @Published var videoMode: VideoMode = .standard2D
    
    // MARK: - Pin to Stage Control
    @Published var isPinnedToStage: Bool = false
    @Published var isPinningTransitioning: Bool = false
    @Published var canPinToStage: Bool = false
    @Published var pinnedStageScale: Float = 1.0 // Screen scale when pinned
    @Published var pinnedStageHeight: Float = 0.0 // Vertical offset when pinned (meters)
    
    // MARK: - Action Callbacks
    var closeAction: (() -> Void)?
    var toggleKeyboardAction: (() -> Void)?
    var onEnvironmentChange: ((EnvironmentStateType) -> Void)?
    var onSemiImmersionToggle: ((Bool) -> Void)?
    var onPinToggle: (() -> Void)?
    var saveSettings: (() -> Void)?
    var toggle3DMode: (() -> Void)?
    
    // MARK: - Controller Support
    weak var controllerSupport: ControllerSupport?
    
    // MARK: - HDR State
    var needsHdr: Bool = false
    
    private init() {
        // Load saved immersive screen settings
        let defaults = UserDefaults.standard
        if let savedScale = defaults.object(forKey: "realitykitImmersiveScale") as? Float {
            immersiveScale = savedScale
        }
        if let savedPosX = defaults.object(forKey: "realitykitImmersivePosX") as? Float,
           let savedPosY = defaults.object(forKey: "realitykitImmersivePosY") as? Float,
           let savedPosZ = defaults.object(forKey: "realitykitImmersivePosZ") as? Float {
            immersivePositionX = savedPosX
            immersivePositionY = savedPosY
            immersivePositionZ = savedPosZ
        }
        if let savedImmersion = defaults.object(forKey: "realitykitImmersionAmount") as? Float {
            immersionAmount = savedImmersion
        }
        // Load pinned screen settings
        if let savedPinnedScale = defaults.object(forKey: "realitykitPinnedStageScale") as? Float {
            pinnedStageScale = savedPinnedScale
        }
        if let savedPinnedHeight = defaults.object(forKey: "realitykitPinnedStageHeight") as? Float {
            pinnedStageHeight = savedPinnedHeight
        }
    }
    
    // MARK: - Computed Properties
    var immersivePosition: SIMD3<Float> {
        get { SIMD3<Float>(immersivePositionX, immersivePositionY, immersivePositionZ) }
        set {
            immersivePositionX = newValue.x
            immersivePositionY = newValue.y
            immersivePositionZ = newValue.z
        }
    }
}


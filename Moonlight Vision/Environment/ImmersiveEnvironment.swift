
//  Created by Linggan-ua on 2025/12/03.

import SwiftUI
import RealityKit
import RealityKitContent
import os

///  The model that manages the environment.
@MainActor @Observable class ImmersiveEnvironment {

    /// A Boolean value that indicates whether the app is presenting an immersive space.
    public var immersiveSpaceIsShown: Bool = false

    /// A Boolean value that indicates whether to open an immersive space.
    public var showImmersiveSpace: Bool = false

    /// An object that handles the state of an environment opened in an immersive space.
    public var environmentStateHandler = EnvironmentStateHandler()

    /// The state to set an environment to after it finishes loading.
    private var requestedEnvironmentState: EnvironmentStateType = .none
    
    /// Cached docking anchor used for pinning the stream to the Studio screen.
    public private(set) var dockingAnchor: Entity?
    
    /// Loading state tracking
    public private(set) var isLoading: Bool = false
    public private(set) var isLoaded: Bool = false
    
    // We will omit ImmersiveContentBrightness for now as it might be specific to the sample or newer SDK.
    // We can handle dimming via standard modifiers in the View.
    
    // Expose activeState directly to be Observable
    public var activeState: EnvironmentStateType {
        environmentStateHandler.activeState
    }
    
    /// Tracks whether the user prefers semi-immersion (Digital Crown active) in Studio mode.
    public var isSemiImmersionEnabled: Bool = false

    public var surroundingsEffect: SurroundingsEffect? {
        switch environmentStateHandler.activeState {
        case .light: .colorMultiply(Color(red: 1.15, green: 1.2, blue: 1.4))
        case .dark: .colorMultiply(Color(red: 0.13, green: 0.12, blue: 0.09))
        case .none: nil
        }
    }

    public private(set) var rootEntity: Entity?

    public func loadEnvironment() {
        guard !isLoading && !isLoaded else { 
            print("Environment already loading or loaded")
            return 
        }
        
        isLoading = true
        print("🔄 Starting environment load...")
        
        Task {
            do {
                // "AAA_MainScene" is the name in Studio.rkassets
                let entity = try await Entity(named: "AAA_MainScene", in: studioBundle)
                
                // Initially hide the environment to ensure passthrough until state is applied
                entity.isEnabled = false
                
                environmentStateHandler.gatherEntities(from: entity)
                
                // Initial State Handling
                if requestedEnvironmentState == .none {
                    entity.isEnabled = false
                    environmentStateHandler.setActiveState(.none)
                    print("Environment loaded in None state (passthrough)")
                } else {
                    entity.isEnabled = true
                    setEnvironmentState(requestedEnvironmentState)
                    print("Environment loaded in \(requestedEnvironmentState) state")
                }

                showImmersiveSpace = true
                rootEntity = entity
                dockingAnchor = locateDockingAnchor(in: entity)
                if dockingAnchor == nil {
                    print("Docking anchor not found in Studio scene")
                } else {
                    print("Docking anchor located: \(dockingAnchor?.name ?? "unknown")")
                }
                isLoading = false
                isLoaded = true
                print("Environment loaded successfully")
            } catch {
                print("Failed to load Studio bundle: \(error.localizedDescription)")
                isLoading = false
                isLoaded = false
                showImmersiveSpace = false
                rootEntity = nil
            }
        }
    }

    public func clearEnvironment() {
        environmentStateHandler.clear()
        rootEntity = nil
        dockingAnchor = nil
        isLoading = false
        isLoaded = false
    }

    public func requestEnvironmentState(_ state: EnvironmentStateType) {
        print("requestEnvironmentState called with: \(state)")
        requestedEnvironmentState = state
        
        if state == .none {
            // CRITICAL: Completely hide and disable the root entity for full passthrough
            if let entity = rootEntity {
                entity.isEnabled = false
                // Force remove from scene hierarchy if present
                // (This will be handled in RealityView's content.remove)
            }
            environmentStateHandler.setActiveState(.none)
            print("Environment state set to None - PASSTHROUGH mode, activeState: \(environmentStateHandler.activeState)")
        } else {
            // Show and enable the root entity for Studio environment
            if let entity = rootEntity {
                entity.isEnabled = true
                setEnvironmentState(state)
                print("Environment state set to \(state), activeState: \(environmentStateHandler.activeState)")
            } else {
                // If entity not loaded yet, trigger loading
                if !isLoading {
                    print("Environment entity not loaded yet, triggering load...")
                    loadEnvironment()
                } else {
                    print("Environment is currently loading, state will be applied on completion")
                }
            }
        }
    }

    private func setEnvironmentState(_ state: EnvironmentStateType) {
        guard state != .none else { return }
        environmentStateHandler.setActiveState(state)

        switch state {
        case .light:
            setVirtualEnvironmentProbeComponent(blendParam: EnvironmentStateHandler.lightStateBlendParam)
        case .dark:
            setVirtualEnvironmentProbeComponent(blendParam: EnvironmentStateHandler.darkStateBlendParam)
        default:
            break
        }
    }

    private func findCommonEntityByName(_ name: String) -> Entity? {
        environmentStateHandler.commonEntity?.children.first(where: { $0.name == name })
    }

    private func setVirtualEnvironmentProbeComponent(blendParam: Float) {
        let virtualEnvironmentProbeEntityName = "EnvironmentProbe"

        guard let virtualEnvironmentProbeEntity = findCommonEntityByName(virtualEnvironmentProbeEntityName) else {
            print("\(virtualEnvironmentProbeEntityName) not found")
            return
        }

        if var probeComponent = virtualEnvironmentProbeEntity.components[VirtualEnvironmentProbeComponent.self] {
            if case VirtualEnvironmentProbeComponent.Source.blend(let firstProbe, let secondProbe, _) = probeComponent.source {
                probeComponent.source = .blend(from: firstProbe, to: secondProbe, t: blendParam)
                virtualEnvironmentProbeEntity.components[VirtualEnvironmentProbeComponent.self] = probeComponent
            }
        }
    }
    
    private func locateDockingAnchor(in entity: Entity) -> Entity? {
        if let dockingRegion = entity.findEntity(named: "DockingRegion") {
            if let player = dockingRegion.findEntity(named: "Player") {
                return player
            }
            return dockingRegion
        }
        return entity.findEntity(named: "Player")
    }
}


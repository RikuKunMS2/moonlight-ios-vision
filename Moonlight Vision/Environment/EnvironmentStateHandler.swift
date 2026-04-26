//
//  EnvironmentStateHandler.swift
//  Moonlight Vision
//
//  Created by Linggan-ua on 2025/12/03.
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI
import RealityKit

/// Describes the environment state.
enum EnvironmentStateType: String, Hashable {
    case light
    case dark
    case none

    var displayName: String {
        return switch self {
        case .light:
            "Light"
        case .dark:
            "Dark"
        case .none:
            "None"
        }
    }

    var name: String {
        [self.rawValue.capitalized, "State"].joined()
    }
}

///  A utility class that manages the State of the Environment presented in the immersive space.
@MainActor @Observable class EnvironmentStateHandler {
    static let commonEntityName = "Common"
    static let visualEntityName = "Visual"

    static let lightStateBlendParam: Float = 0.0
    static let darkStateBlendParam: Float = 1.0

    weak public private(set) var commonEntity: Entity?
    weak public private(set) var lightStateEntity: Entity?
    weak public private(set) var darkStateEntity: Entity?
    
    // New: Track the screen entity
    weak public private(set) var screenEntity: Entity?

    public private(set) var activeState: EnvironmentStateType = .none

    public func gatherEntities(from rootEntity: Entity?) {
        clear()
        guard var entity = rootEntity else { return }

        // Traverse the hierarchy until multiple children are found.
        while entity.children.count == 1 {
            entity = entity.children.first!
        }

        for childEntity in entity.children {
            let entityName = childEntity.name.lowercased()

            if entityName.contains(EnvironmentStateType.light.name.lowercased()) {
                lightStateEntity = childEntity
            } else if entityName.contains(EnvironmentStateType.dark.name.lowercased()) {
                darkStateEntity = childEntity
            } else if entityName.contains(Self.commonEntityName.lowercased()) {
                commonEntity = childEntity
            }
            
            // Try to find where the screen should go.
            // In the Studio environment, there might be a specific node.
            // Based on common structure, it might be under "Common" or just in the root.
            // Let's recursively search for "Screen" or similar if we knew the name.
            // For now, we will assume we need to find a placeholder or we attach to a known location.
        }
    }

    public func setActiveState(_ state: EnvironmentStateType) {
        guard state != activeState else { return }

        if state == .none {
            // Explicitly handle none to update activeState tracking
            activeState = .none
            return
        }

        switch state {
        case .light:
            guard lightStateEntity != nil else {
                print("Entity for light state not found, active state not changed")
                return
            }
            lightStateVisualEntity?.isEnabled = true
            darkStateVisualEntity?.isEnabled = false
            activeState = .light
        case .dark:
            guard darkStateEntity != nil else {
                print("Entity for dark state not found, active state not changed")
                return
            }
            lightStateVisualEntity?.isEnabled = false
            darkStateVisualEntity?.isEnabled = true
            activeState = .dark
        default:
            break
        }
    }

    public func clear() {
        lightStateEntity = nil
        darkStateEntity = nil
        commonEntity = nil
        activeState = .none
    }

    private func getFirstChildByName(entity: Entity?, name: String) -> Entity? {
        entity?.children.first(where: { $0.name == name })
    }

    public var lightStateVisualEntity: Entity? {
        getFirstChildByName(entity: lightStateEntity, name: Self.visualEntityName)
    }

    public var darkStateVisualEntity: Entity? {
        getFirstChildByName(entity: darkStateEntity, name: Self.visualEntityName)
    }
}


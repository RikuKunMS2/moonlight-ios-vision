//
//  MoonlightAppEntity.swift
//  Moonlight Vision
//
//  Created by tht7 on 06/02/2025.
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  AppEntity.swift
//  Moonlight
// Ugh Im a little upset by how unoptimized everything in the storage is
// it's not like CoreData is bad it\s that we dont use any of it's nice (and essential) features >:(
// Also this file is not optimized at all but it only get's called by the shortcuts app so I don't mind
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation
import OSLog
import AppIntents


extension TemporaryApp: AppEntity {
    public typealias DefaultQuery = MoonlightAppQuery
    
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = .init(name: "Moonlight Streamable App")
    
    public var displayRepresentation: DisplayRepresentation {
        .init(stringLiteral: self.name)
    }
    
    public static var defaultQuery = MoonlightAppQuery()
}

@MainActor
public struct MoonlightAppQuery: EntityQuery {
    public typealias Entity = TemporaryApp
    
    @IntentParameterDependency<OpenMoonlightApp>(
            \.$host
        )
    var intent
    
    public init() {}
    
    public func entities(for identifiers: [String]) async throws -> [TemporaryApp] {
        var matches: [TemporaryApp] = []
        let hostApps = intent?.host.appList ?? []
        
        for id in identifiers {
            if let match = hostApps.first(where: { $0.id == id }) {
                matches.append(match)
            } else if id == "Steam" {
                matches.append(TemporaryApp(id: "Steam", name: "Steam Big Picture"))
            } else {
                // Return exact match for defaults or custom typed inputs
                matches.append(TemporaryApp(id: id, name: id))
            }
        }
        return matches
    }
    
    public func entities(matching string: String) async throws -> [TemporaryApp] {
        var matches: [TemporaryApp] = []
        let hostApps = intent?.host.appList ?? []
        
        matches = hostApps.filter { $0.name.localizedCaseInsensitiveContains(string) }
        
        let defaults = [
            TemporaryApp(id: "Desktop", name: "Desktop"),
            TemporaryApp(id: "Steam", name: "Steam Big Picture"),
            TemporaryApp(id: "Virtual Display", name: "Virtual Display")
        ]
        
        for app in defaults {
            if app.name.localizedCaseInsensitiveContains(string) && !matches.contains(where: { $0.name == app.name }) {
                matches.append(app)
            }
        }
        
        // Allow exact custom match
        if !matches.contains(where: { $0.name.lowercased() == string.lowercased() }) && !string.isEmpty {
            matches.append(TemporaryApp(id: string, name: string))
        }
        
        return matches
    }
    
    public func suggestedEntities() async throws -> [TemporaryApp] {
        var entities = [
            TemporaryApp(id: "Desktop", name: "Desktop"),
            TemporaryApp(id: "Steam", name: "Steam Big Picture"),
            TemporaryApp(id: "Virtual Display", name: "Virtual Display")
        ]
        
        if let intent = intent {
            for app in intent.host.appList {
                if !entities.contains(where: { $0.name == app.name }) {
                    entities.append(app as! TemporaryApp)
                }
            }
        }
        
        return entities
    }
}

//
//  AppEntity.swift
//  Moonlight
//
//  Created by tht7 on 06/02/2025.
//  Copyright © 2025 Moonlight Game Streaming Project. All rights reserved.\
// Ugh Im a little upset by how unoptimized everything in the storage is
// it's not like CoreData is bad it\s that we dont use any of it's nice (and essential) features >:(
//
// Also this file is not optimized at all but it only get's called by the shortcuts app so I don't mind

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
        [TemporaryApp](intent?.host.appList ?? [])
    }
    
    public func entities(matching string: String) async throws -> [TemporaryApp] {
        [TemporaryApp](intent?.host.appList ?? []).filter {
            $0.name.contains(string)
        }
    }
    
    public func suggestedEntities() async throws -> [TemporaryApp] {
        guard let intent = intent else {
            print("Missing intent")
            return []
        }
        
        print("Fetching apps for \(String(describing: intent.host.name)) (\(intent.host.appList.count))")
        return [TemporaryApp](intent.host.appList)
    }
}

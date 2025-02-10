//
//  MoonlightHostAppEntity.swift
//  Moonlight
//
//  Created by tht7 on 06/02/2025.
//  Copyright © 2025 Moonlight Game Streaming Project. All rights reserved.
//
import Foundation
import AppIntents

@MainActor
extension TemporaryHost: AppEntity {
    public typealias DefaultQuery = MoonlightHostQuery
    
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = .init(name: "Moonlight Streaming Host")
    
    public var displayRepresentation: DisplayRepresentation {
        .init(stringLiteral: self.name)
    }
    
    public static var defaultQuery = MoonlightHostQuery()
}

@MainActor
public struct MoonlightHostQuery: EntityStringQuery {
    public typealias Entity = TemporaryHost
    
    public init() {}
    
    @MainActor
    public func entities(for identifiers: [String]) async throws -> [TemporaryHost] {
        return DataManager().getHosts().filter {
            if identifiers.contains($0.id) {
                print("FOR QUERY \(identifiers) FOUND HOST \(String(describing: $0))")
            }
            return identifiers.contains($0.id)
        }
    }
    
    public func entities(matching string: String) async throws -> [TemporaryHost] {
        return DataManager().getHosts().filter { $0.name.contains(string) }
    }
    
    public func suggestedEntities() async throws -> [TemporaryHost] {
        return DataManager().getHosts()
    }
}


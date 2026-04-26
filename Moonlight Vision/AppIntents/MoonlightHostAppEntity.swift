//
//  MoonlightHostAppEntity.swift
//  Moonlight Vision
//
//  Created by tht7 on 06/02/2025.
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Moonlight
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
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
        var liveHosts = MainViewModel.shared.hosts
        if liveHosts.isEmpty {
            MainViewModel.shared.loadSavedHosts()
            MainViewModel.shared.beginRefresh()
            // Give mDNS a brief moment to resolve addresses if the app just woke up
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            liveHosts = MainViewModel.shared.hosts
        }
        
        return liveHosts.filter { identifiers.contains($0.id) && $0.pairState == .paired }
    }
    
    public func entities(matching string: String) async throws -> [TemporaryHost] {
        var liveHosts = MainViewModel.shared.hosts
        if liveHosts.isEmpty { MainViewModel.shared.loadSavedHosts() }
        return liveHosts.filter { $0.name.localizedCaseInsensitiveContains(string) && $0.pairState == .paired }
    }
    
    public func suggestedEntities() async throws -> [TemporaryHost] {
        var liveHosts = MainViewModel.shared.hosts
        if liveHosts.isEmpty { MainViewModel.shared.loadSavedHosts() }
        return liveHosts.filter { $0.pairState == .paired }
    }
}


//
//  MainViewModel.swift
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/22/24.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation

@MainActor
class MainViewModel: NSObject, ObservableObject, DiscoveryCallback {
    @Published var hosts: [TemporaryHost] = []
    
    @Published var pairingInProgress = false;
    
    private var dataManager: DataManager
    private var discoveryManager: DiscoveryManager? = nil
    
    override init() {
        dataManager = DataManager()
        super.init()
        discoveryManager = DiscoveryManager(hosts: hosts, andCallback: self)
    }
    
    func setHosts(newHosts: [TemporaryHost]) {
        hosts = newHosts
    }
    
    func addHost(newHost: TemporaryHost) {
        hosts.append(newHost)
    }
    
    func tryPairHost(_ host: TemporaryHost) {
        pairingInProgress = true;
    }
    
    // MARK: Host discovery

    func loadSavedHosts() {
        if let savedHosts = dataManager.getHosts() as? [TemporaryHost] {
            hosts.append(contentsOf: savedHosts)
        } else {
            print("Unable to fetch saved hosts")
        }
        
        for host in hosts {
            if host.activeAddress == nil {
                host.activeAddress = host.localAddress
            }
            if host.activeAddress == nil {
                host.activeAddress = host.externalAddress
            }
            if host.activeAddress == nil {
                host.activeAddress = host.address
            }
            if host.activeAddress == nil {
                host.activeAddress = host.ipv6Address
            }
        }
    }
    
    // Callback from DiscoveryManager
    nonisolated func updateAllHosts(_ newHosts: [Any]!) {
        if let newHosts = newHosts as? [TemporaryHost] {
            Task {
                await setHosts(newHosts: newHosts)
            }
        }
    }
    
    @objc func beginRefresh() {
        discoveryManager?.resetDiscoveryState()
        discoveryManager?.startDiscovery()
    }
    
    func stopRefresh() {
        discoveryManager?.stopDiscovery()
    }
}

extension TemporaryHost: Identifiable {
    public var id: String {
        uuid
    }
}

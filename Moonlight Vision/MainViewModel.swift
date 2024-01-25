//
//  MainViewModel.swift
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/22/24.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation

@MainActor
class MainViewModel: NSObject, ObservableObject, DiscoveryCallback, PairCallback {
    @Published var hosts: [TemporaryHost] = []
    
    @Published var pairingInProgress = false
    @Published var currentPin = ""
    
    private var dataManager: DataManager
    private var discoveryManager: DiscoveryManager? = nil
    private var clientCert: Data
    
    private var opQueue = OperationQueue()
    
    override init() {
        dataManager = DataManager()
        // should this be in viewDidLoad and not init?
        clientCert = CryptoManager.readCertFromFile()
        super.init()
        discoveryManager = DiscoveryManager(hosts: hosts, andCallback: self)
    }
    
    func setHosts(newHosts: [TemporaryHost]) {
        hosts.removeAll()
        hosts.append(contentsOf: newHosts)
    }
    
    func addHost(newHost: TemporaryHost) {
        hosts.append(newHost)
    }
    
    // MARK: Pairing

    func tryPairHost(_ host: TemporaryHost) {
        discoveryManager?.stopDiscoveryBlocking()
        let httpManager = HttpManager(host: host)
        // do we need to retain this? probably?
        let pairManager = PairManager(manager: httpManager, clientCert: clientCert, callback: self)
        opQueue.addOperation(pairManager!)
        print("trying to pair")
    }
    
    nonisolated func startPairing(_ PIN: String!) {
        Task { @MainActor in
            pairingInProgress = true
            currentPin = PIN
        }
        print("pairing started")
    }
    
    nonisolated func pairSuccessful(_ serverCert: Data!) {
        endPairing()
    }
    
    nonisolated func pairFailed(_ message: String!) {
        endPairing()
    }
    
    nonisolated func alreadyPaired() {
        endPairing()
    }
    
    nonisolated func endPairing() {
        Task { @MainActor in
            pairingInProgress = false
            discoveryManager?.startDiscovery()
        }
    }
    
    func updateHost(host: TemporaryHost) {
        Task {
            let httpManager = HttpManager(host: host)
            discoveryManager?.pauseDiscovery(for: host)
            
            let serverInfoResponse = ServerInfoResponse()
            let request = HttpRequest(for: serverInfoResponse, with: httpManager?.newServerInfoRequest(false), fallbackError: 401, fallbackRequest: httpManager?.newHttpServerInfoRequest())
            httpManager?.executeRequestSynchronously(request)
            discoveryManager?.resumeDiscovery(for: host)
            
            if !serverInfoResponse.isStatusOk() {
                print("Failed to get server info: \(serverInfoResponse.statusMessage ?? "unknown error")")
                // populate state with bad
            } else {
                serverInfoResponse.populateHost(host)
            }
        }
    }

    // MARK: Host discovery

    func loadSavedHosts() {
        if let savedHosts = dataManager.getHosts() as? [TemporaryHost] {
            for host in savedHosts {
                hosts.append(host)
            }
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


//
//  MainViewModel.swift
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/22/24.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation
import OrderedCollections
import VideoToolbox

@MainActor
class MainViewModel: NSObject, ObservableObject, DiscoveryCallback, PairCallback, AppAssetCallback {
    @Published var hosts: [TemporaryHost] = []
    
    @Published var pairingInProgress = false
    @Published var currentPin = ""
    
    @Published var errorAddingHost = false
    @Published var addHostErrorMessage = ""
    
    @Published var currentStreamConfig = StreamConfiguration()
    @Published var activelyStreaming = false
    @Published var streamSettings: TemporarySettings
    
    private var dataManager: DataManager
    private var discoveryManager: DiscoveryManager? = nil
    private var appManager: AppAssetManager?
    private var boxArtCache: NSCache<TemporaryApp, UIImage>
    private var clientCert: Data
    private var uniqueId: String
    
    private var opQueue = OperationQueue()
    private var currentlyPairingHost: TemporaryHost?
    
    override init() {
        boxArtCache = NSCache<TemporaryApp, UIImage>()
        dataManager = DataManager()
        // should this be in viewDidLoad and not init?
        CryptoManager.generateKeyPairUsingSSL()
        clientCert = CryptoManager.readCertFromFile()
        uniqueId = IdManager.getUniqueId()
        streamSettings = dataManager.getSettings()
        
        super.init()
        appManager = AppAssetManager(callback: self)
        discoveryManager = DiscoveryManager(hosts: hosts, andCallback: self)
    }
    
    func setHosts(newHosts: [TemporaryHost]) {
        hosts.removeAll()
        hosts.append(contentsOf: newHosts)
    }
    
    func addHost(newHost: TemporaryHost) {
        if !hosts.contains(newHost) {
            hosts.append(newHost)
        }
    }

    func removeHost(_ host: TemporaryHost) {
        if hosts.contains(host) {
            discoveryManager?.removeHost(fromDiscovery: host)
            dataManager.remove(host)
            hosts.removeAll(where: { $0 == host })
        }
    }
    
    func wakeHost(_ host: TemporaryHost) {
        WakeOnLanManager.wake(host)
    }
    
    // MARK: App Icons

    nonisolated func receivedAsset(for app: TemporaryApp!) {
        // pass
    }
    
    // MARK: Pairing

    func manuallyDiscoverHost(hostOrIp: String) {
        discoveryManager?.discoverHost(hostOrIp, withCallback: hostMaybeFound)
    }
    
    nonisolated func hostMaybeFound(host: TemporaryHost?, error: String?) {
        Task { @MainActor in
            if let host {
                self.addHost(newHost: host)
                await self.updateHost(host: host)
                
            } else {
                self.errorAddingHost = true
                self.addHostErrorMessage = error ?? "Unknown Error"
            }
        }
    }
    
    func tryPairHost(_ host: TemporaryHost) {
        discoveryManager?.stopDiscoveryBlocking()
        let httpManager = HttpManager(host: host)
        // do we need to retain this? probably?
        let pairManager = PairManager(manager: httpManager, clientCert: clientCert, callback: self)
        opQueue.addOperation(pairManager!)
        currentlyPairingHost = host
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
        Task { @MainActor in
            currentlyPairingHost?.serverCert = serverCert
        }
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
            if let currentlyPairingHost { await updateHost(host: currentlyPairingHost) }
            currentlyPairingHost = nil
        }
    }
    
    func updateHost(host: TemporaryHost) async {
        // Potentially skip this if it's recent?
        // Populate online/offline correctly?
        
        Task {
            let httpManager = HttpManager(host: host)
            discoveryManager?.pauseDiscovery(for: host)
            host.updatePending = true
            let serverInfoResponse = ServerInfoResponse()
            let request = HttpRequest(for: serverInfoResponse, with: httpManager?.newServerInfoRequest(false), fallbackError: 401, fallbackRequest: httpManager?.newHttpServerInfoRequest())
            httpManager?.executeRequestSynchronously(request)
            discoveryManager?.resumeDiscovery(for: host)
            
            host.updatePending = false
            if !serverInfoResponse.isStatusOk() {
                print("Failed to get server info: \(serverInfoResponse.statusMessage ?? "unknown error")")
                // populate state with bad
            } else {
                serverInfoResponse.populateHost(host)
            }
        }
    }
    
    func refreshAppsFor(host: TemporaryHost) {
        // possibly put loading stuff somewhere?
        discoveryManager?.pauseDiscovery(for: host)
        let appListResponse = ConnectionHelper.getAppList(for: host)
        discoveryManager?.resumeDiscovery(for: host)
        if appListResponse?.isStatusOk() == true {
            let serverApps = (appListResponse!.getAppList() as! Set<TemporaryApp>)
            
            var newAppList = OrderedSet<TemporaryApp>()
            // Only new apps we have received are valid, but keep the old object and state if it exists.
            for serverApp in serverApps {
                var matchFound = false
                for oldApp in host.appList {
                    if serverApp.id == oldApp.id {
                        oldApp.name = serverApp.name
                        oldApp.hdrSupported = serverApp.hdrSupported
                        oldApp.setHost(host)
                        // Ignore hidden, we want to respect the saved state.
                        matchFound = true
                        newAppList.append(oldApp)
                        break
                    }
                }
                if !matchFound {
                    serverApp.setHost(host)
                    newAppList.append(serverApp)
                }
            }
            
            let removedApps = host.appList.subtracting(newAppList)
            let database = DataManager()
            for removedApp in removedApps {
                database.remove(removedApp)
            }
            
            database.updateApps(forExisting: host)
            
            // self.updateHostShortcuts
            host.appList = newAppList
        }
    }

    // MARK: Host discovery

    func loadSavedHosts() {
        if let savedHosts = dataManager.getHosts() as? [TemporaryHost] {
            for host in savedHosts {
                addHost(newHost: host)
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
    
    // MARK: Stream Control
    
    func stream(app: TemporaryApp) {
        let config = StreamConfiguration()
        
        guard let host = app.host() else {
            return
        }
        
        config.host = host.activeAddress
        config.httpsPort = host.httpsPort
        config.appID = app.id
        config.appName = app.name
        config.serverCert = host.serverCert
                
        config.frameRate = streamSettings.framerate
        
        #if os(visionOS)
        // leave framerate as is
        #else
        // clamp framerate to maximum
        #endif
        
        config.height = streamSettings.height
        config.width = streamSettings.width
        
        config.bitRate = streamSettings.bitrate
        config.optimizeGameSettings = streamSettings.optimizeGames
        config.playAudioOnPC = streamSettings.playAudioOnPC
        config.useFramePacing = streamSettings.useFramePacing
        config.swapABXYButtons = streamSettings.swapABXYButtons
        config.multiController = streamSettings.multiController
        config.gamepadMask = ControllerSupport.getConnectedGamepadMask(config)
        
        // 7.1, always
        config.audioConfiguration = (0x63f << 16) | (8 << 8) | 0xca
        
        // all of them? i guess? this forces hdr on
        config.serverCodecModeSupport = host.serverCodecModeSupport
        
        // figure out how to nicely import the c++ headers
        
        let AV1_MAIN8: Int32 = 0x1000
        let AV1_MAIN10: Int32 = 0x2000
        let H265: Int32 = 0x0100
        let H264: Int32 = 0x0001
        let H265_MAIN10: Int32 = 0x0200
        
        let av1_supported = VideoToolbox.VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        let hdr10_supported = AVPlayer.availableHDRModes.contains(AVPlayer.HDRMode.hdr10)
        switch streamSettings.preferredCodec {
        case .av1:
            if av1_supported {
                config.supportedVideoFormats |= AV1_MAIN8
            }
        case .auto:
            fallthrough
        case .hevc:
            if VideoToolbox.VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
                config.supportedVideoFormats |= H265
            }
        case .h264:
            config.supportedVideoFormats |= H264
        }
        
        if config.width > 4096 || config.height > 4096 || streamSettings.enableHdr {
            if VideoToolbox.VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
                config.supportedVideoFormats |= H265
            }
            
            if streamSettings.enableHdr && hdr10_supported {
                config.supportedVideoFormats |= H265_MAIN10
            }
            
            let av1_enabled = config.supportedVideoFormats & 0xf000 != 0
            if av1_enabled && streamSettings.enableHdr && av1_supported && hdr10_supported {
                config.supportedVideoFormats |= AV1_MAIN10
            }
        }
        
        currentStreamConfig = config
        activelyStreaming = true
    }
}

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
import AVFoundation

@MainActor
class MainViewModel: NSObject, ObservableObject, DiscoveryCallback, PairCallback, AppAssetCallback {
    private let languagePromptDefaultsKey = "didCompleteLanguagePrompt"
    @objc
    static let shared = MainViewModel()

    @Published var hosts: [TemporaryHost] = []

    @Published var pairingInProgress = false
    @Published var currentPin = ""

    @Published var errorAddingHost = false
    @Published var addHostErrorMessage = ""

    @Published var currentStreamConfig = StreamConfiguration()
    @Published var activelyStreaming = false
    @Published var showActiveStreamAlert = false
    @Published var pendingAppToStream: TemporaryApp?
    @Published var showLanguagePrompt = false
    
    // Store saved window size for aspect ratio lock restoration
    @Published var savedStreamWindowSize: CGSize? = nil
    @Published var classicWindowNeedsManualClose = false
    @Published var realityWindowNeedsManualClose = false
    @Published var showClassicWindowCloseAlert = false
    @Published var showRealityWindowCloseAlert = false
    @Published var streamSettings: TemporarySettings

    @Published var volumeSliderValue: Float = 1.0


    @Published var vol: Float = 127
    @Published var mute: Bool = false

    private var dataManager: DataManager
    private var discoveryManager: DiscoveryManager? = nil
    private var appManager: AppAssetManager?
    private var boxArtCache: NSCache<TemporaryApp, UIImage>
    private var clientCert: Data
    private var uniqueId: String

    private var opQueue = OperationQueue()
    private var currentlyPairingHost: TemporaryHost?

    override init() {
        print("INITING MAIN MODEL")
        boxArtCache = NSCache<TemporaryApp, UIImage>()
        dataManager = DataManager()
        CryptoManager.generateKeyPairUsingSSL()
        clientCert = CryptoManager.readCertFromFile()
        uniqueId = IdManager.getUniqueId()
        streamSettings = dataManager.getSettings()
        showLanguagePrompt = !UserDefaults.standard.bool(forKey: languagePromptDefaultsKey)

        super.init()
        appManager = AppAssetManager(callback: self)
        discoveryManager = DiscoveryManager(hosts: hosts, andCallback: self)
    }

    // Computed property to filter hosts based on pairState and remove duplicates
    var hostsWithPairState: [TemporaryHost] {
        // Since the upsert logic now prevents duplicates in the `hosts` array,
        // this computed property can be simplified to just filter by state.
        let filteredHosts = hosts.filter { host in
            let isPaired = host.pairState == .paired
            let isUnpaired = host.pairState == .unpaired
            return isPaired || isUnpaired
        }
        return filteredHosts
    }
    
    // MARK: - Host Management Logic
    
    /// Updates existing hosts or inserts new ones discovered on the network.
    /// This prevents duplicate entries in the `hosts` array.
    func upsertDiscoveredHosts(_ discoveredHosts: [TemporaryHost]) {
        for discoveredHost in discoveredHosts {
            // Find if a host with the same unique ID already exists in our main list
            if let existingHost = hosts.first(where: { $0.uuid == discoveredHost.uuid }) {
                // It exists. Update its volatile properties from the newly discovered one.
                // We don't want to overwrite important persisted data like the certificate here,
                // just things that change during discovery.
                existingHost.state = discoveredHost.state
                existingHost.name = discoveredHost.name
                existingHost.address = discoveredHost.address // Update with the latest address
                existingHost.localAddress = discoveredHost.localAddress
                existingHost.externalAddress = discoveredHost.externalAddress
                existingHost.ipv6Address = discoveredHost.ipv6Address

                // Trigger an update to get full server details if one isn't already pending
                if !existingHost.updatePending {
                    Task {
                        await updateHost(host: existingHost)
                    }
                }
            } else {
                // It's a new host. Add it to the array.
                print("Discovered a new host, adding to list: \(discoveredHost.name)")
                hosts.append(discoveredHost)
                // Now trigger a full update to check its pairing status and get all details.
                Task {
                    await updateHost(host: discoveredHost, force: true)
                }
            }
        }
    }

    func removeHost(_ hostToRemove: TemporaryHost) {
        print("removeHost - START - Attempting to remove host: \(hostToRemove.name), UUID: \(hostToRemove.uuid), Current hosts count: \(hosts.count)")
        if hosts.contains(hostToRemove) {
            print("removeHost - Host found. Removing...")
            discoveryManager?.removeHost(fromDiscovery: hostToRemove)
            dataManager.remove(hostToRemove)
            hosts.removeAll(where: { $0 == hostToRemove })
            print("removeHost - Host removed. Current hosts count: \(hosts.count)")
            print("removeHost - END - Host removed successfully")
        } else {
            print("removeHost - Warning: Attempted to remove host \(hostToRemove.name) (UUID: \(hostToRemove.uuid)) but it was NOT found in the hosts list.")
            print("removeHost - END - Host not found, not removed")
        }
    }


    func wakeHost(_ host: TemporaryHost) {
        WakeOnLanManager.wake(host)
    }

    // MARK: - App Icons

    nonisolated func receivedAsset(for app: TemporaryApp!) {
        // pass
    }

    // MARK: - Pairing

    func manuallyDiscoverHost(hostOrIp: String) {
        discoveryManager?.discoverHost(hostOrIp, withCallback: hostMaybeFound)
    }

    nonisolated func hostMaybeFound(host: TemporaryHost?, error: String?) {
        Task { @MainActor in
            if let host {
                print("Discovered host: \(host.name)")
                // Use the upsert logic to correctly add or update the manually found host
                self.upsertDiscoveredHosts([host])
            } else {
                print("Error discovering host: \(error ?? "Unknown error")")
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
        print("startPairing - Pairing started with PIN: \(PIN ?? "N/A")")
    }

    nonisolated func pairSuccessful(_ serverCert: Data!) {
        Task { @MainActor in
            if let pairingHost = currentlyPairingHost {
                 print("pairSuccessful - Pairing successful for host: \(pairingHost.name)")
                 pairingHost.serverCert = serverCert
                 // Update host state after successful pairing
                 await updateHost(host: pairingHost, force: true) // Force update to refresh state and persist
            } else {
                 print("pairSuccessful - Warning: currentlyPairingHost is nil.")
            }
            endPairing()
        }
    }

    nonisolated func pairFailed(_ message: String!) {
        Task { @MainActor in
            print("pairFailed - Pairing failed for host: \(currentlyPairingHost?.name ?? "Unknown"). Reason: \(message ?? "Unknown error")")
            endPairing()
        }
    }

    nonisolated func alreadyPaired() {
        Task { @MainActor in
            print("alreadyPaired - Host \(currentlyPairingHost?.name ?? "Unknown") is already paired.")
            if let host = currentlyPairingHost {
                // Ensure pair state is correct if discovery missed it somehow
                if host.pairState != .paired {
                    host.pairState = .paired
                    print("alreadyPaired - Corrected host pairState to paired.")
                }
                // Update to get latest info and persist the corrected state
                await updateHost(host: host, force: true)
            }
            endPairing()
        }
    }

    // Simplified endPairing - called from the specific result handlers
    nonisolated func endPairing() {
        Task { @MainActor in
            pairingInProgress = false
            currentPin = "" // Clear PIN
            currentlyPairingHost = nil // Clear the host being paired

            // 1. Start discovery
            discoveryManager?.startDiscovery()
            print("endPairing - Pairing process finished, discovery starting.")

            // 2. Wait for 5 seconds asynchronously
            do {
                try await Task.sleep(for: .seconds(5))

                // 3. Stop discovery after the delay
                discoveryManager?.stopDiscovery()
                print("endPairing - Discovery stopped after 5 seconds.")

            } catch {
                // Handle the possibility that the Task was cancelled while sleeping
                print("endPairing - Sleep task cancelled, discovery stop might have been skipped.")
            }
        }
    }

    // MARK: - Host & App Data Sync

    func updateHost(host: TemporaryHost, force: Bool = false) async {
        await MainActor.run {
            guard force || host.state != .offline else {
                print("updateHost: Host \(host.name) is marked offline and force is false. Skipping request.")
                if host.updatePending { host.updatePending = false }
                return
            }

            print("updateHost: Proceeding with server info request for \(host.name). State: \(host.state), Force: \(force)")

            let httpManager = HttpManager(host: host)
            discoveryManager?.pauseDiscovery(for: host)
            host.updatePending = true // Mark as pending

            let serverInfoResponse = ServerInfoResponse()

            print("Executing server info request for host: \(host.name) at \(host.activeAddress ?? host.address ?? "N/A")")
            let request = HttpRequest(for: serverInfoResponse, with: httpManager?.newServerInfoRequest(false), fallbackError: 401, fallbackRequest: httpManager?.newHttpServerInfoRequest())
            httpManager?.executeRequestSynchronously(request) // BLOCKING CALL

            // --- Process Result ---
            host.updatePending = false // Clear pending flag regardless of outcome

            guard hosts.contains(where: { $0.uuid == host.uuid }) else {
                 print("updateHost: Host \(host.name) (UUID: \(host.uuid)) no longer in list after request. Discarding result.")
                 discoveryManager?.resumeDiscovery(for: host) // Still need to resume discovery
                 return
            }

            if serverInfoResponse.isStatusOk() {
                print("Successfully updated host: \(host.name). Populating host data.")
                if host.state != .online {
                     print("updateHost: Host \(host.name) was previously \(host.state), setting to Online after successful update.")
                     host.state = .online // Ensure state reflects reachability
                }
                serverInfoResponse.populateHost(host) // Populate details (like pairState, etc.)
                
                // ------------------- FIX -------------------
                // Save the updated host to persistent storage (Core Data).
                // This is the critical step to "remember" the pairing.
                dataManager.update(host)
                // -------------------------------------------
                
            } else {
                print("Failed to update host: \(host.name) during server info request. Error: \(serverInfoResponse.statusMessage ?? "unknown error"). Setting state to offline.")
                if host.state != .offline {
                    host.state = .offline
                }
            }

            discoveryManager?.resumeDiscovery(for: host)
        }
    }

    func refreshAppsFor(host: TemporaryHost) {
        // possibly put loading stuff somewhere?
        print("refreshAppsFor - Refreshing apps for host: \(host.name)")
        discoveryManager?.pauseDiscovery(for: host)
        let appListResponse = ConnectionHelper.getAppList(for: host)
        discoveryManager?.resumeDiscovery(for: host)
        if appListResponse?.isStatusOk() == true {
            let serverApps = (appListResponse!.getAppList() as! Set<TemporaryApp>)
            print("refreshAppsFor - Received \(serverApps.count) apps from server.")

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
            if !removedApps.isEmpty {
                print("refreshAppsFor - Removing \(removedApps.count) apps no longer present on server.")
                let database = DataManager()
                for removedApp in removedApps {
                    database.remove(removedApp)
                }
                database.updateApps(forExisting: host) // Persist removals
            }

            if host.appList != newAppList {
                 print("refreshAppsFor - App list changed. Updating host.")
                 host.appList = newAppList // Update the host's app list
            } else {
                 print("refreshAppsFor - App list unchanged.")
            }

        } else {
             print("refreshAppsFor - Failed to retrieve app list for host: \(host.name). Status: \(appListResponse?.statusMessage ?? "Unknown error")")
            host.state = .offline
        }
    }

    // MARK: - Host Discovery

    func loadSavedHosts() {
        if let savedHosts = dataManager.getHosts() as? [TemporaryHost] {
            print("Loaded saved hosts: \(savedHosts.count)")
            // Directly assign saved hosts. The upsert logic will handle updates
            // once network discovery starts.
            self.hosts = savedHosts
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
    
    /// Callback from the discovery manager.
    nonisolated func updateAllHosts(_ newHosts: [Any]!) {
        if let newHosts = newHosts as? [TemporaryHost] {
            Task { @MainActor in
                // Use the new upsert function to prevent duplicates
                self.upsertDiscoveredHosts(newHosts)
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
     
    // MARK: - Stream Control

    func stream(app: TemporaryApp) -> StreamConfiguration? {
        let config = StreamConfiguration()

        guard let host = app.host() else {
            print("stream - ERROR: App \(app.name) has no associated host.")
            return nil
        }

        print("stream - Preparing stream configuration for app: \(app.name) on host: \(host.name)")

        config.host = host.activeAddress ?? host.address
        if config.host == nil {
            print("stream - ERROR: Host \(host.name) has no valid address (activeAddress or address).")
            return nil
        }

        config.httpsPort = host.httpsPort
        config.appID = app.id
        config.appName = app.name
        config.serverCert = host.serverCert
        if config.serverCert == nil {
             print("stream - WARNING: Host \(host.name) has no server certificate. Streaming might fail if pairing is required.")
        }

        config.frameRate = streamSettings.framerate
        config.height = streamSettings.height
        config.width = streamSettings.width
        config.bitRate = streamSettings.bitrate
        config.optimizeGameSettings = streamSettings.optimizeGames
        config.playAudioOnPC = streamSettings.playAudioOnPC
        config.useFramePacing = streamSettings.useFramePacing
        config.swapABXYButtons = streamSettings.swapABXYButtons
        config.multiController = streamSettings.multiController
        config.gamepadMask = ControllerSupport.getConnectedGamepadMask(config, settings: streamSettings)
        config.audioConfiguration = (0x63f << 16) | (8 << 8) | 0xca // 7.1 Surround
        config.serverCodecModeSupport = host.serverCodecModeSupport

        // Codec Selection Logic (simplified for readability)
        let AV1_MAIN8: Int32 = 0x1000
        let AV1_MAIN10: Int32 = 0x2000
        let H265: Int32 = 0x0100
        let H264: Int32 = 0x0001
        let H265_MAIN10: Int32 = 0x0200

        let av1_supported = VideoToolbox.VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        let hevc_supported = VideoToolbox.VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        let hdr10_supported = AVPlayer.availableHDRModes.contains(AVPlayer.HDRMode.hdr10)

        config.supportedVideoFormats = 0 // Start fresh

        switch streamSettings.preferredCodec {
        case .av1 where av1_supported:
              config.supportedVideoFormats |= AV1_MAIN8
              print("stream - Adding AV1_MAIN8 support.")
        case .hevc where hevc_supported:
              config.supportedVideoFormats |= H265
              print("stream - Adding H265 support.")
        case .h264:
              config.supportedVideoFormats |= H264
              print("stream - Adding H264 support.")
        case .auto:
              // Auto: Prioritize based on availability (e.g., AV1 > HEVC > H264)
              if av1_supported { config.supportedVideoFormats |= AV1_MAIN8; print("stream - Adding AV1_MAIN8 support (Auto).") }
              if hevc_supported { config.supportedVideoFormats |= H265; print("stream - Adding H265 support (Auto).") }
              config.supportedVideoFormats |= H264 // Always support H264 as fallback
              print("stream - Adding H264 support (Auto Fallback).")
        default: // Includes cases where preferred codec isn't supported
              if hevc_supported { config.supportedVideoFormats |= H265; print("stream - Adding H265 support (Default).") }
              config.supportedVideoFormats |= H264 // Fallback
              print("stream - Adding H264 support (Default Fallback).")
        }

        // HDR / High Resolution adjustments
        if streamSettings.enableHdr || config.width > 4096 || config.height > 4096 {
            if hevc_supported {
                config.supportedVideoFormats |= H265 // Ensure HEVC is enabled for HDR/HighRes
                if streamSettings.enableHdr && hdr10_supported {
                    config.supportedVideoFormats |= H265_MAIN10
                    print("stream - Adding H265_MAIN10 support for HDR.")
                }
            }
            if av1_supported && streamSettings.enableHdr && hdr10_supported {
                config.supportedVideoFormats |= AV1_MAIN10
                print("stream - Adding AV1_MAIN10 support for HDR.")
            }
        }
        print("stream - Final supportedVideoFormats: \(String(format: "0x%04X", config.supportedVideoFormats))")

        currentStreamConfig = config
        classicWindowNeedsManualClose = false
        realityWindowNeedsManualClose = false
        activelyStreaming = true
        print("stream - Stream configuration complete. Ready to start streaming.")
        return currentStreamConfig
    }

    func updateLanguage(_ language: AppLanguage) {
        streamSettings.appLanguage = language
        streamSettings.save()
        showLanguagePrompt = false
        UserDefaults.standard.set(true, forKey: languagePromptDefaultsKey)
    }

    func forceStopActiveStream() {
        activelyStreaming = false
        classicWindowNeedsManualClose = false
        realityWindowNeedsManualClose = false
    }

    nonisolated static func audioSessionMode() -> AudioSessionMode {
        return MainActor.assumeIsolated {
            MainViewModel.shared.streamSettings.audioSessionMode
        }
    }


    var currentLanguage: AppLanguage {
        streamSettings.appLanguage
    }

    func localized(english: String, chinese: String) -> String {
        currentLanguage == .chinese ? chinese : english
    }

    nonisolated static func localizedStatic(english: String, chinese: String) -> String {
        return MainActor.assumeIsolated {
            MainViewModel.shared.streamSettings.appLanguage == .chinese ? chinese : english
        }
    }
    
    @objc nonisolated static func localizedString(english: String, chinese: String) -> String {
        return localizedStatic(english: english, chinese: chinese)
    }
    
    @objc nonisolated static func startingStreamFormatString() -> String {
        return localizedStatic(english: "Starting %@...", chinese: "正在启动 %@...")
    }

    nonisolated static func shouldUseExclusiveAudio(microphoneActive: Bool) -> Bool {
        return MainActor.assumeIsolated {
            switch MainViewModel.shared.streamSettings.audioSessionMode {
            case .exclusive:
                return true
            case .mixed:
                return false
            case .exclusiveWhenMicActive:
                return microphoneActive
            }
        }
    }
}

extension String {
    // Helper function to remove a suffix if it exists.
    func dropSuffix(_ suffix: String) -> String {
        guard hasSuffix(suffix) else { return self }
        return String(dropLast(suffix.count))
    }
}
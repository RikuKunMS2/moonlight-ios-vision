//

import Foundation
import Observation

#if os(visionOS)
@Observable
#endif
@objc
@MainActor
public class TemporarySettings: NSObject {
    @objc public var bitrate: Int32
    @objc public var framerate: Int32
    @objc public var height: Int32
    @objc public var width: Int32
    @objc public var audioConfig: Int32
    @objc public var onscreenControls: Int32
    @objc public var uniqueId: String
    @objc public var preferredCodec = PreferredCodec.auto

    @objc public var useFramePacing = false
    @objc public var multiController = false
    @objc public var swapABXYButtons = false
    @objc public var playAudioOnPC = false
    @objc public var optimizeGames = false
    @objc public var enableHdr = false
    @objc public var btMouseSupport = false
    @objc public var absoluteTouchMode = false
    @objc public var statsOverlay = false

    @objc public var parent: MoonlightSettings?

    override public init() {
        self.bitrate = 0
        self.framerate = 0
        self.height = 0
        self.width = 0
        self.audioConfig = 0
        self.uniqueId = ""
        self.onscreenControls = 0
        super.init()
    }

    @objc public init(fromSettings settings: MoonlightSettings) {
        #if TARGET_OS_TV
        let settingsBundle = NSBundle.main.path(forResource: "Settings", ofType: "bundle")
        let settingsData = NSDictionary(contentsOf: settingsBundle)
        // TODO: Finish the tvos part
        #else

        self.bitrate = settings.bitrate?.int32Value ?? 0
        self.framerate = settings.framerate?.int32Value ?? 0
        self.height = settings.height?.int32Value ?? 0
        self.width = settings.width?.int32Value ?? 0
        self.audioConfig = settings.audioConfig?.int32Value ?? 0
        self.preferredCodec = PreferredCodec(rawValue: Int(settings.preferredCodec)) ?? PreferredCodec.auto
        self.onscreenControls = settings.onscreenControls?.int32Value ?? 0
        self.uniqueId = settings.uniqueId ?? ""

        self.useFramePacing = settings.useFramePacing
        self.multiController = settings.multiController
        self.swapABXYButtons = settings.swapABXYButtons
        self.playAudioOnPC = settings.playAudioOnPC
        self.optimizeGames = settings.optimizeGames
        self.enableHdr = settings.enableHdr
        self.btMouseSupport = settings.btMouseSupport
        self.absoluteTouchMode = settings.absoluteTouchMode
        self.statsOverlay = settings.statsOverlay
        #endif

        super.init()
    }

    @objc public func save() {
        // save settings to parent
        let dataManager = DataManager()
        dataManager.saveSettings(withBitrate: Int(bitrate), framerate: Int(framerate), height: Int(height), width: Int(width), audioConfig: Int(audioConfig), onscreenControls: Int(onscreenControls), optimizeGames: optimizeGames, multiController: multiController, swapABXYButtons: swapABXYButtons, audioOnPC: playAudioOnPC, preferredCodec: UInt32(preferredCodec.rawValue), useFramePacing: useFramePacing, enableHdr: enableHdr, btMouseSupport: btMouseSupport, absoluteTouchMode: absoluteTouchMode, statsOverlay: statsOverlay)
    }
}

@objc public enum PreferredCodec: Int {
    case auto
    case h264
    case hevc
    case av1
}

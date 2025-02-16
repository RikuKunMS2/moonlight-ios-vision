//

import Foundation
import Observation
import AppIntents

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
    @objc public var onscreenControls: OnScreenControlsLevel
    @objc public var uniqueId: String
    @objc public var preferredCodec = PreferredCodec.auto
    @objc public var renderer: Renderer = .classic

    @objc public var realitykitRendererAnimateOpening: Bool = false
    @objc public var realitykitRendererCurvature: Float = 0.0

    @objc public var useFramePacing = false
    @objc public var multiController = false
    @objc public var swapABXYButtons = false
    @objc public var playAudioOnPC = false
    @objc public var optimizeGames = false
    @objc public var enableHdr = false
    @objc public var btMouseSupport = false
    @objc public var absoluteTouchMode = false
    @objc public var statsOverlay = false
    @objc public var dimPassthrough = true

    @objc public var parent: MoonlightSettings?

    override public init() {
        self.bitrate = 50000
        self.framerate = 0
        self.height = 0
        self.width = 0
        self.audioConfig = 0
        self.uniqueId = ""
        self.onscreenControls = OnScreenControlsLevel.off
        self.renderer = .classic
        self.realitykitRendererAnimateOpening = false
        self.realitykitRendererCurvature = 0.0
        self.dimPassthrough = false
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
        self.onscreenControls = OnScreenControlsLevel(rawValue: settings.onscreenControls?.intValue ?? 0) ?? OnScreenControlsLevel.off
        self.renderer = if let ren = settings.renderer?.uint8Value { Renderer(rawValue: UInt8(ren)) ?? .classic } else { .classic }
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

        self.realitykitRendererAnimateOpening = settings.realitykitRendererAnimateOpening == 1
        self.realitykitRendererCurvature = settings.realitykitRendererCurvature?.floatValue ?? 0
        self.dimPassthrough = settings.dimPassthrough?.boolValue ?? false
        #endif

        super.init()
    }

    @objc public func save() {
        // save settings to parent
        let dataManager = DataManager()
        dataManager.saveSettings(withBitrate: Int(bitrate), framerate: Int(framerate), height: Int(height), width: Int(width), audioConfig: Int(audioConfig), onscreenControls: Int(onscreenControls.rawValue), optimizeGames: optimizeGames, multiController: multiController, swapABXYButtons: swapABXYButtons, audioOnPC: playAudioOnPC, preferredCodec: UInt32(preferredCodec.rawValue), renderer: renderer.rawValue, useFramePacing: useFramePacing, enableHdr: enableHdr, btMouseSupport: btMouseSupport, absoluteTouchMode: absoluteTouchMode, statsOverlay: statsOverlay, realitykitRendererAnimateOpening: realitykitRendererAnimateOpening, realitykitRendererCurvature: NSNumber(value: realitykitRendererCurvature), dimPassthrough: dimPassthrough)
    }
}

@objc public enum PreferredCodec: Int {
    case auto
    case h264
    case hevc
    case av1
}

@objc public enum Renderer: UInt8, Codable, Sendable, AppEnum {
    
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
            TypeDisplayRepresentation(
                stringLiteral: "Renderer"
            )
        }
    
    public static var caseDisplayRepresentations: [Renderer : DisplayRepresentation] = [
        .classic: .init(stringLiteral: "UIKit (Classic)"),
        .realitykit: .init(stringLiteral: "RealityKit (Experimental)"),
    ]
    
    case classic
    case realitykit

    // Swift-only computed property for mapping cases to strings
    var windowId: String {
        switch self {
        case .classic: return "classicStreamingWindow"
        case .realitykit: return "realitykitStreamingWindow"
        }
    }
}

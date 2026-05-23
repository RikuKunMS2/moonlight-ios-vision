//
//  TemporarySettings.swift
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/22/24.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation
import Observation
import AppIntents
import SwiftUI

private let appLanguageDefaultsKey = "appLanguagePreference"

@objc public enum AppLanguage: Int, CaseIterable, Sendable, Hashable {
    case english = 0
    case chinese

    public var displayName: LocalizedStringKey {
        switch self {
        case .english:
            return "English"
        case .chinese:
            return "简体中文"
        }
    }
}

@objc public enum SpatialAudioMode: Int, CaseIterable, Sendable, Hashable {
    case stereo = 0
    case window = 1
    case surround = 2
}

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
    @objc public var realitykitRendererTilt: Float = 0.0
    @objc public var realitykitAutoPitchFollow: Bool = false
    @objc public var realitykitDynamicScale: Bool = true
    @objc public var realitykitScreenCornerRadius: Float = 0.018
    @objc public var realitykitImmersiveMode: Bool = false
    @objc public var reactiveLightingEnabled: Bool = false

    @objc public var gazeTouchMode = false
    @objc public var gazeCursorOffsetX: Int = 0
    @objc public var gazeCursorOffsetY: Int = 0
    @objc public var hideHandsIn360Environment = false

    @objc public var useFramePacing = false
    @objc public var multiController = false
    @objc public var swapABXYButtons = false
    @objc public var playAudioOnPC = false
    @objc public var optimizeGames = false
    @objc public var enableHdr = false
    @objc public var btMouseSupport = false
    @objc public var fpsMouseCapture = false
    @objc public var controllerMouseMode = false
    @objc public var controllerMouseSpeed: Int = 1  // 0=slow, 1=medium, 2=fast
    @objc public var absoluteTouchMode = false
    @objc public var statsOverlay = false
    @objc public var dimPassthrough = true
    @objc public var macVirtualDisplayExperimental = false
    
    // UIKit window corner radius (default: 0, may affect clarity)
    @objc public var uikitWindowCornerRadius: Float = 0.0
    
    // --- HDR / Color Settings ---
    // HDR correct neutral: boost=1.0, contrast=1.0, saturation=1.0 (passed directly to shader)
    @objc public var brightness: Float = 1.0
    @objc public var gamma: Float = 1.0       // Default: 1.0 (Neutral)
    @objc public var saturation: Float = 1.0  // Default: 1.0 (Neutral)
    /// PQ (HDR10) / ST.2084 exposure trim for RealityKit; 1.0 = neutral. Not stored in Core Data.
    @objc public var pqExposure: Float = 1.0
    
    @objc public var appLanguageRaw: Int = AppLanguage.english.rawValue
    @objc public var autoResumeStreamOnReopen = false
    @objc public var rememberStreamSettings = true
    
    @objc public var spatialAudioMode: Int = SpatialAudioMode.window.rawValue
    @objc public var preferUninterruptedAudio: Bool = true

    @objc public var parent: MoonlightSettings?

    // This init is used for SwiftUI Previews only
    override public init() {
        self.bitrate = 30000
        self.framerate = 60
        self.height = 1440
        self.width = 2560
        self.audioConfig = 0
        self.uniqueId = ""
        self.onscreenControls = OnScreenControlsLevel.off
        self.renderer = .classic
        self.realitykitRendererAnimateOpening = false
        self.realitykitRendererCurvature = 0.0
        self.realitykitRendererTilt = 0.0
        self.realitykitAutoPitchFollow = false
        self.realitykitDynamicScale = true
        self.dimPassthrough = false
        self.macVirtualDisplayExperimental = false
        self.reactiveLightingEnabled = false
        
        // HDR defaults: 1.0 = neutral (correct for shader)
        self.brightness = 1.0
        self.gamma = 1.0
        self.saturation = 1.0
        self.pqExposure = 1.0
        
        if let storedLang = UserDefaults.standard.object(forKey: appLanguageDefaultsKey) as? Int {
            self.appLanguageRaw = storedLang
        } else {
            self.appLanguageRaw = AppLanguage.english.rawValue
        }
        
        self.spatialAudioMode = SpatialAudioMode.window.rawValue
        self.preferUninterruptedAudio = true
        super.init()
    }

    // This init is used by the App when loading from the Database
        @objc public init(fromSettings settings: MoonlightSettings) {
            #if TARGET_OS_TV
            self.bitrate = 0
            self.framerate = 0
            self.height = 0
            self.width = 0
            self.audioConfig = 0
            self.uniqueId = ""
            self.onscreenControls = .off
            #else

            // 1. Load raw values from the Database
            let loadedBitrate = settings.bitrate?.int32Value ?? 0
            let loadedHeight = settings.height?.int32Value ?? 0
            let loadedWidth = settings.width?.int32Value ?? 0
            let loadedFps = settings.framerate?.int32Value ?? 0
            let loadedOsc = settings.onscreenControls?.intValue ?? 0
            
            // Initialize self with loaded values first
            self.bitrate = loadedBitrate
            self.framerate = loadedFps
            self.height = loadedHeight
            self.width = loadedWidth
            self.onscreenControls = OnScreenControlsLevel(rawValue: loadedOsc) ?? OnScreenControlsLevel.off

            // 2. ONE-TIME MIGRATION CHECK (Resolution/Bitrate Defaults)
            let migrationKey = "hasMigratedToNewDefaults_v1"
            let hasMigrated = UserDefaults.standard.bool(forKey: migrationKey)

            if !hasMigrated {
                let isOldDefaultBitrate = (loadedBitrate == 10000)
                let isOldDefaultRes = (loadedHeight == 720 || loadedHeight == 1080)
                let isOldDefaultOsc = (loadedOsc == 1) // 1 = Auto
                let isOldDefaultFps = (loadedFps == 60)

                if isOldDefaultBitrate && isOldDefaultRes && isOldDefaultOsc && isOldDefaultFps {
                    print("Detected fresh install or default settings. Applying new Vision defaults.")
                    
                    self.bitrate = 30000
                    self.height = 1440
                    self.width = 2560
                    self.onscreenControls = .off
                }
                
                UserDefaults.standard.set(true, forKey: migrationKey)
            }

            // Load remaining settings normally
            self.audioConfig = settings.audioConfig?.int32Value ?? 0
            self.preferredCodec = PreferredCodec(rawValue: Int(settings.preferredCodec)) ?? PreferredCodec.auto
            self.renderer = if let ren = settings.renderer?.uint8Value { Renderer(rawValue: UInt8(ren)) ?? .classic } else { .classic }
            self.uniqueId = settings.uniqueId ?? ""

            self.useFramePacing = settings.useFramePacing
            self.multiController = settings.multiController
            self.swapABXYButtons = settings.swapABXYButtons
            self.playAudioOnPC = settings.playAudioOnPC
            self.optimizeGames = settings.optimizeGames
            self.enableHdr = settings.enableHdr
            self.btMouseSupport = settings.btMouseSupport
            self.fpsMouseCapture = UserDefaults.standard.bool(forKey: "fpsMouseCapture")
            self.controllerMouseMode = UserDefaults.standard.bool(forKey: "controllerMouseMode")
            self.controllerMouseSpeed = UserDefaults.standard.integer(forKey: "controllerMouseSpeed")
            self.absoluteTouchMode = settings.absoluteTouchMode
            self.statsOverlay = settings.statsOverlay

            self.realitykitRendererAnimateOpening = settings.realitykitRendererAnimateOpening == 1
            self.realitykitRendererCurvature = settings.realitykitRendererCurvature?.floatValue ?? 0
            self.realitykitRendererTilt = UserDefaults.standard.object(forKey: "realitykitRendererTilt") as? Float ?? 0.0
            self.realitykitAutoPitchFollow = UserDefaults.standard.object(forKey: "realitykitAutoPitchFollow") as? Bool ?? false
            self.realitykitDynamicScale = UserDefaults.standard.object(forKey: "realitykitDynamicScale") as? Bool ?? true
            self.realitykitScreenCornerRadius = UserDefaults.standard.object(forKey: "realitykitScreenCornerRadius") as? Float ?? 0.018
            self.dimPassthrough = settings.dimPassthrough?.boolValue ?? false
            
            self.realitykitImmersiveMode = UserDefaults.standard.bool(forKey: "realitykitImmersiveMode")
            self.reactiveLightingEnabled = UserDefaults.standard.bool(forKey: "reactiveLightingEnabled")
            self.macVirtualDisplayExperimental = UserDefaults.standard.bool(forKey: "macVirtualDisplayExperimental")
            
            // --- HDR / COLOR LOADING ---
            self.brightness = settings.brightness?.floatValue ?? 1.0
            self.gamma = settings.gamma?.floatValue ?? 1.0
            self.saturation = settings.saturation?.floatValue ?? 1.0
            self.pqExposure = 1.0
            
            if let storedLang = UserDefaults.standard.object(forKey: appLanguageDefaultsKey) as? Int {
                self.appLanguageRaw = storedLang
            } else {
                self.appLanguageRaw = AppLanguage.english.rawValue
            }
            self.autoResumeStreamOnReopen = UserDefaults.standard.bool(forKey: "autoResumeStreamOnReopen")
            self.rememberStreamSettings = UserDefaults.standard.object(forKey: "rememberStreamSettings") as? Bool ?? true
            self.uikitWindowCornerRadius = UserDefaults.standard.object(forKey: "uikitWindowCornerRadius") as? Float ?? 0.0
            self.spatialAudioMode = UserDefaults.standard.object(forKey: "spatialAudioMode") as? Int ?? SpatialAudioMode.window.rawValue
            self.preferUninterruptedAudio = UserDefaults.standard.object(forKey: "preferUninterruptedAudio") as? Bool ?? true
            #endif

            super.init()
            
            if !UserDefaults.standard.bool(forKey: "hasSavedNewDefaults_v1") {
                if self.bitrate != loadedBitrate || self.height != loadedHeight {
                    self.save()
                    UserDefaults.standard.set(true, forKey: "hasSavedNewDefaults_v1")
                }
            }
        }
    
    @objc public func save() {
        UserDefaults.standard.set(self.realitykitImmersiveMode, forKey: "realitykitImmersiveMode")
        UserDefaults.standard.set(self.reactiveLightingEnabled, forKey: "reactiveLightingEnabled")
        UserDefaults.standard.set(self.macVirtualDisplayExperimental, forKey: "macVirtualDisplayExperimental")
        UserDefaults.standard.set(self.autoResumeStreamOnReopen, forKey: "autoResumeStreamOnReopen")
        UserDefaults.standard.set(self.fpsMouseCapture, forKey: "fpsMouseCapture")
        UserDefaults.standard.set(self.rememberStreamSettings, forKey: "rememberStreamSettings")
        UserDefaults.standard.set(self.uikitWindowCornerRadius, forKey: "uikitWindowCornerRadius")
        UserDefaults.standard.set(self.realitykitScreenCornerRadius, forKey: "realitykitScreenCornerRadius")
        UserDefaults.standard.set(self.realitykitRendererTilt, forKey: "realitykitRendererTilt")
        UserDefaults.standard.set(self.realitykitAutoPitchFollow, forKey: "realitykitAutoPitchFollow")
        UserDefaults.standard.set(self.realitykitDynamicScale, forKey: "realitykitDynamicScale")
        UserDefaults.standard.set(self.spatialAudioMode, forKey: "spatialAudioMode")
        UserDefaults.standard.set(self.preferUninterruptedAudio, forKey: "preferUninterruptedAudio")
        UserDefaults.standard.set(self.controllerMouseMode, forKey: "controllerMouseMode")
        UserDefaults.standard.set(self.controllerMouseSpeed, forKey: "controllerMouseSpeed")

        // save settings to parent via DataManager
        let dataManager = DataManager()
        dataManager.saveSettings(
                withBitrate: Int(bitrate),
                framerate: Int(framerate),
                height: Int(height),
                width: Int(width),
                audioConfig: Int(audioConfig),
                onscreenControls: Int(onscreenControls.rawValue),
                optimizeGames: optimizeGames,
                multiController: multiController,
                swapABXYButtons: swapABXYButtons,
                audioOnPC: playAudioOnPC,
                preferredCodec: UInt32(preferredCodec.rawValue),
                renderer: renderer.rawValue,
                useFramePacing: useFramePacing,
                enableHdr: enableHdr,
                btMouseSupport: btMouseSupport,
                absoluteTouchMode: absoluteTouchMode,
                statsOverlay: statsOverlay,
                realitykitRendererAnimateOpening: realitykitRendererAnimateOpening,
                realitykitRendererCurvature: NSNumber(value: realitykitRendererCurvature),
                dimPassthrough: dimPassthrough,
                brightness: brightness,
                gamma: gamma,            // <--- Pass Gamma
                saturation: saturation   // <--- Pass Saturation
        )
        UserDefaults.standard.set(appLanguageRaw, forKey: appLanguageDefaultsKey)
    }
    
    // Reset only stream settings (slider parameters) to their default values
    // This resets HDR/Color settings, RealityKit display settings, and immersive screen parameters
    // System settings (resolution, framerate, bitrate, etc.) are preserved
    @objc public func resetStreamSettingsOnly() {
        // HDR / Color settings - correct neutral values for HDR shader
        self.brightness = 1.0
        self.gamma = 1.0
        self.saturation = 1.0
        self.pqExposure = 1.0
        
        // RealityKit display settings
        self.realitykitRendererCurvature = 0.0  // Default from slider
        self.realitykitRendererTilt = 0.0       // Default tilt
        self.realitykitAutoPitchFollow = false
        self.realitykitScreenCornerRadius = 0.018  // Default screen corner radius
        
        // Reset UserDefaults for immersive screen parameters
        let defaults = UserDefaults.standard
        
        // Reset immersive screen parameters to match StreamControlState defaults
        defaults.set(1.8, forKey: "realitykitImmersiveScale")      // Default: 1.8x
        defaults.set(0.0, forKey: "realitykitImmersivePosX")        // Default: 0.0
        defaults.set(1.5, forKey: "realitykitImmersivePosY")        // Default: 1.5m height
        defaults.set(-2.0, forKey: "realitykitImmersivePosZ")       // Default: -2.0 (viewing distance 2m)
        defaults.set(0.0, forKey: "realitykitImmersionAmount")     // Default: 0.0
        defaults.set(5.0, forKey: "realitykitPinnedStageScale")    // Default: 5.0
        defaults.set(0.75, forKey: "realitykitPinnedStageHeight") // Default: 0.75
        
        // Reset RealityKit non-immersive mode settings (will use defaults when loaded)
        defaults.removeObject(forKey: "realitykitHeight")
        defaults.removeObject(forKey: "realitykitDepthOffset")
        
        // Reset saved HDR values to correct neutral (1.0)
        defaults.set(1.0, forKey: "realitykitGamma")
        defaults.set(1.0, forKey: "realitykitSaturation")
        defaults.set(1.0, forKey: "realitykitBrightness")
        defaults.set(1.0, forKey: "realitykitVolumeGamma")
        defaults.set(1.0, forKey: "realitykitVolumeSaturation")
        defaults.set(1.0, forKey: "realitykitVolumeBrightness")
        defaults.set(1.0, forKey: "realitykitImmersiveGamma")
        defaults.set(1.0, forKey: "realitykitImmersiveSaturation")
        defaults.set(1.0, forKey: "realitykitImmersiveBrightness")
        defaults.set(1.0, forKey: "realitykitPqExposure")
        defaults.set(1.0, forKey: "realitykitVolumePqExposure")
        defaults.set(1.0, forKey: "realitykitImmersivePqExposure")
        
        // Save the reset values
        self.save()
    }
    
    // Reset all settings to default values
    // This includes video settings, RealityKit settings, stream settings, HDR/Color settings, and app settings
    @objc public func resetAllSettings() {
        // Video settings
        self.bitrate = 30000
        self.framerate = 60
        self.height = 1440
        self.width = 2560
        self.audioConfig = 0
        self.onscreenControls = OnScreenControlsLevel.off
        self.renderer = .classic
        
        // RealityKit settings
        self.realitykitRendererAnimateOpening = false
        self.realitykitRendererCurvature = 0.0
        self.realitykitRendererTilt = 0.0
        self.realitykitAutoPitchFollow = false
        self.realitykitScreenCornerRadius = 0.018
        self.realitykitImmersiveMode = false
        self.reactiveLightingEnabled = false
        self.macVirtualDisplayExperimental = false
        
        // Stream settings
        self.useFramePacing = false
        self.multiController = false
        self.swapABXYButtons = false
        self.playAudioOnPC = false
        self.optimizeGames = false
        self.enableHdr = false
        self.btMouseSupport = false
        self.controllerMouseMode = false
        self.controllerMouseSpeed = 1
        self.absoluteTouchMode = false
        self.statsOverlay = false
        self.dimPassthrough = true
        self.preferredCodec = PreferredCodec.auto
        self.uikitWindowCornerRadius = 0.0
        self.spatialAudioMode = SpatialAudioMode.window.rawValue
        self.preferUninterruptedAudio = true
        
        // HDR / Color settings (correct neutral for HDR shader)
        self.brightness = 1.0
        self.gamma = 1.0
        self.saturation = 1.0
        self.pqExposure = 1.0
        
        // App settings (keep language, reset others)
        self.autoResumeStreamOnReopen = false
        self.rememberStreamSettings = true
        
        // Reset UserDefaults for RealityKit settings
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "realitykitImmersiveMode")
        defaults.set(false, forKey: "reactiveLightingEnabled")
        defaults.set(false, forKey: "macVirtualDisplayExperimental")
        defaults.set(false, forKey: "autoResumeStreamOnReopen")
        defaults.set(true, forKey: "rememberStreamSettings")
        defaults.set(false, forKey: "controllerMouseMode")
        defaults.set(1, forKey: "controllerMouseSpeed")

        // Reset immersive screen parameters in UserDefaults
        defaults.removeObject(forKey: "realitykitImmersiveScale")
        defaults.removeObject(forKey: "realitykitImmersivePosX")
        defaults.removeObject(forKey: "realitykitImmersivePosY")
        defaults.removeObject(forKey: "realitykitImmersivePosZ")
        defaults.removeObject(forKey: "realitykitImmersionAmount")
        defaults.removeObject(forKey: "realitykitPinnedStageScale")
        defaults.removeObject(forKey: "realitykitPinnedStageHeight")
        
        // Reset RealityKit non-immersive mode settings
        defaults.removeObject(forKey: "realitykitHeight")
        defaults.removeObject(forKey: "realitykitDepthOffset")
        defaults.set(0.018, forKey: "realitykitScreenCornerRadius")
        defaults.removeObject(forKey: "realitykitRendererTilt")
        defaults.removeObject(forKey: "realitykitAutoPitchFollow")
        
        // Reset saved gamma and saturation values
        defaults.removeObject(forKey: "realitykitGamma")
        defaults.removeObject(forKey: "realitykitSaturation")
        defaults.removeObject(forKey: "realitykitPqExposure")
        defaults.removeObject(forKey: "realitykitVolumePqExposure")
        defaults.removeObject(forKey: "realitykitImmersivePqExposure")
        
        // Reset UIKit window corner radius
        defaults.set(0.0, forKey: "uikitWindowCornerRadius")
        
        // Reset spatial audio mode
        defaults.set(SpatialAudioMode.window.rawValue, forKey: "spatialAudioMode")
        
        // Reset prefer uninterrupted audio
        defaults.set(true, forKey: "preferUninterruptedAudio")
        
        // Save the reset values
        self.save()
    }
}

extension TemporarySettings {
    var appLanguage: AppLanguage {
        get {
            AppLanguage(rawValue: appLanguageRaw) ?? .english
        }
        set {
            appLanguageRaw = newValue.rawValue
        }
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

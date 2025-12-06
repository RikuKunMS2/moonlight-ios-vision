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
    @objc public var realitykitImmersiveMode: Bool = false
    @objc public var realitykitHighResPinnedScreen: Bool = false // Increase mesh resolution when pinned for better clarity (may affect performance)

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
    
    // UIKit window corner radius (default: 0, may affect clarity)
    @objc public var uikitWindowCornerRadius: Float = 0.0
    
    // --- HDR / Color Settings ---
    @objc public var brightness: Float = 0.0
    @objc public var gamma: Float = 1.0       // Default: 1.0 (Neutral)
    @objc public var saturation: Float = 1.0  // Default: 1.0 (Neutral)
    
    @objc public var appLanguageRaw: Int = AppLanguage.english.rawValue
    @objc public var autoResumeStreamOnReopen = false
    @objc public var rememberStreamSettings = true

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
        self.realitykitHighResPinnedScreen = false
        self.dimPassthrough = false
        
        // Defaults
        self.brightness = 0.0
        self.gamma = 1.0
        self.saturation = 1.0
        
        if let storedLang = UserDefaults.standard.object(forKey: appLanguageDefaultsKey) as? Int {
            self.appLanguageRaw = storedLang
        } else {
            self.appLanguageRaw = AppLanguage.english.rawValue
        }
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
            self.absoluteTouchMode = settings.absoluteTouchMode
            self.statsOverlay = settings.statsOverlay

            self.realitykitRendererAnimateOpening = settings.realitykitRendererAnimateOpening == 1
            self.realitykitRendererCurvature = settings.realitykitRendererCurvature?.floatValue ?? 0
            self.dimPassthrough = settings.dimPassthrough?.boolValue ?? false
            
            self.realitykitImmersiveMode = UserDefaults.standard.bool(forKey: "realitykitImmersiveMode")
            self.realitykitHighResPinnedScreen = UserDefaults.standard.bool(forKey: "realitykitHighResPinnedScreen")
            
            // --- HDR / COLOR SAFE LOADING ---
            // We track if we had to repair any values (0.0 -> 1.0) using this flag
            var valuesNeedRepair = false
            
            // 1. Brightness
            let loadedBrightness = settings.brightness?.floatValue ?? 0.0
            if loadedBrightness < 0.1 {
                self.brightness = 2.2 // Apply boost for fresh/legacy updates
            } else {
                self.brightness = loadedBrightness
            }
            
            // 2. Gamma
            // If nil or 0.0, default to 1.0
            let loadedGamma = settings.gamma?.floatValue ?? 0.0
            if loadedGamma < 0.01 {
                self.gamma = 1.0
                valuesNeedRepair = true
            } else {
                self.gamma = loadedGamma
            }
            
            // 3. Saturation
            // If nil or 0.0, default to 1.0
            let loadedSat = settings.saturation?.floatValue ?? 0.0
            if loadedSat < 0.01 {
                self.saturation = 1.0
                valuesNeedRepair = true
            } else {
                self.saturation = loadedSat
            }
            
            if let storedLang = UserDefaults.standard.object(forKey: appLanguageDefaultsKey) as? Int {
                self.appLanguageRaw = storedLang
            } else {
                self.appLanguageRaw = AppLanguage.english.rawValue
            }
            self.autoResumeStreamOnReopen = UserDefaults.standard.bool(forKey: "autoResumeStreamOnReopen")
            self.rememberStreamSettings = UserDefaults.standard.object(forKey: "rememberStreamSettings") as? Bool ?? true
            self.uikitWindowCornerRadius = UserDefaults.standard.object(forKey: "uikitWindowCornerRadius") as? Float ?? 0.0
            #endif

            super.init()
            
            // 3. SAVE BACK CORRECTED DEFAULTS
            // We check the flag we set above. If values were missing (0.0), we save the fix immediately.
            let hdrMigrationKey = "migrated_hdr_defaults_v1"
            let hasMigratedHDR = UserDefaults.standard.bool(forKey: hdrMigrationKey)
            
            if !hasMigratedHDR || valuesNeedRepair {
                print("[Settings] Repairing/Migrating Missing HDR Values...")
                self.save()
                UserDefaults.standard.set(true, forKey: hdrMigrationKey)
            }
            
            if !UserDefaults.standard.bool(forKey: "hasSavedNewDefaults_v1") {
                if self.bitrate != loadedBitrate || self.height != loadedHeight {
                    self.save()
                    UserDefaults.standard.set(true, forKey: "hasSavedNewDefaults_v1")
                }
            }
        }
    
    @objc public func save() {
        UserDefaults.standard.set(self.realitykitImmersiveMode, forKey: "realitykitImmersiveMode")
        UserDefaults.standard.set(self.realitykitHighResPinnedScreen, forKey: "realitykitHighResPinnedScreen")
        UserDefaults.standard.set(self.autoResumeStreamOnReopen, forKey: "autoResumeStreamOnReopen")
        UserDefaults.standard.set(self.rememberStreamSettings, forKey: "rememberStreamSettings")
        UserDefaults.standard.set(self.uikitWindowCornerRadius, forKey: "uikitWindowCornerRadius")

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
        // HDR / Color settings - reset to slider defaults
        self.brightness = 4.0  // Default from slider
        self.gamma = 2.0       // Default from slider (contrast)
        self.saturation = 1.70 // Default from slider
        
        // RealityKit display settings
        self.realitykitRendererCurvature = 0.0  // Default from slider
        
        // Reset UserDefaults for immersive screen parameters
        let defaults = UserDefaults.standard
        
        // Reset immersive screen parameters to defaults
        defaults.set(1.0, forKey: "realitykitImmersiveScale")      // Default: 1.0
        defaults.set(0.0, forKey: "realitykitImmersivePosX")        // Default: 0.0
        defaults.set(1.0, forKey: "realitykitImmersivePosY")        // Default: 1.0
        defaults.set(-1.5, forKey: "realitykitImmersivePosZ")       // Default: -1.5 (viewing distance 1.5m)
        defaults.set(0.0, forKey: "realitykitImmersionAmount")     // Default: 0.0
        defaults.set(5.0, forKey: "realitykitPinnedStageScale")    // Default: 5.0
        defaults.set(0.75, forKey: "realitykitPinnedStageHeight") // Default: 0.75
        
        // Reset RealityKit non-immersive mode settings (will use defaults when loaded)
        defaults.removeObject(forKey: "realitykitHeight")
        defaults.removeObject(forKey: "realitykitDepthOffset")
        
        // Reset saved gamma and saturation values
        defaults.set(2.0, forKey: "realitykitGamma")
        defaults.set(1.70, forKey: "realitykitSaturation")
        
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
        self.realitykitImmersiveMode = false
        self.realitykitHighResPinnedScreen = false
        
        // Stream settings
        self.useFramePacing = false
        self.multiController = false
        self.swapABXYButtons = false
        self.playAudioOnPC = false
        self.optimizeGames = false
        self.enableHdr = false
        self.btMouseSupport = false
        self.absoluteTouchMode = false
        self.statsOverlay = false
        self.dimPassthrough = true
        self.preferredCodec = PreferredCodec.auto
        self.uikitWindowCornerRadius = 0.0
        
        // HDR / Color settings
        self.brightness = 0.0
        self.gamma = 1.0
        self.saturation = 1.0
        
        // App settings (keep language, reset others)
        self.autoResumeStreamOnReopen = false
        self.rememberStreamSettings = true
        
        // Reset UserDefaults for RealityKit settings
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "realitykitImmersiveMode")
        defaults.set(false, forKey: "realitykitHighResPinnedScreen")
        defaults.set(false, forKey: "autoResumeStreamOnReopen")
        defaults.set(true, forKey: "rememberStreamSettings")
        
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
        
        // Reset saved gamma and saturation values
        defaults.removeObject(forKey: "realitykitGamma")
        defaults.removeObject(forKey: "realitykitSaturation")
        
        // Reset UIKit window corner radius
        defaults.set(0.0, forKey: "uikitWindowCornerRadius")
        
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

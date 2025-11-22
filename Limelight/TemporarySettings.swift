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
    @objc public var brightness: Float = 0.0
    @objc public var appLanguageRaw: Int = AppLanguage.english.rawValue
    @objc public var autoResumeStreamOnReopen = false // Default: close window returns to host
    @objc public var rememberStreamSettings = true // Default: remember stream settings (RealityKit settings and UIKit window size)

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
        self.dimPassthrough = false
        self.brightness = 0.0
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
        let settingsBundle = NSBundle.main.path(forResource: "Settings", ofType: "bundle")
        let settingsData = NSDictionary(contentsOf: settingsBundle)
        // TODO: Finish the tvos part
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

        // 2. ONE-TIME MIGRATION CHECK
        let migrationKey = "hasMigratedToNewDefaults_v1"
        let hasMigrated = UserDefaults.standard.bool(forKey: migrationKey)

        if !hasMigrated {
            // Check for the specific "Old Factory Default" signature.
            // This ensures we don't overwrite a user who intentionally set 720p.
            // Old Defaults: 10Mbps, 720p (1280x720), Auto OSC (1), 60fps
            
            let isOldDefaultBitrate = (loadedBitrate == 10000)
            // Check 720p OR 1080p just in case the model defaults vary slightly
            let isOldDefaultRes = (loadedHeight == 720 || loadedHeight == 1080)
            let isOldDefaultOsc = (loadedOsc == 1) // 1 = Auto
            let isOldDefaultFps = (loadedFps == 60)

            // ONLY override if ALL conditions match
            if isOldDefaultBitrate && isOldDefaultRes && isOldDefaultOsc && isOldDefaultFps {
                print("Detected fresh install or default settings. Applying new Vision defaults.")
                
                self.bitrate = 30000
                self.height = 1440
                self.width = 2560
                self.onscreenControls = .off
                
                // We will save this at the end of init
            }
            
            // Mark migration as done so we never check/override again
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
        
        // FIX: Load Immersive Mode from UserDefaults since CoreData isn't updated yet
        self.realitykitImmersiveMode = UserDefaults.standard.bool(forKey: "realitykitImmersiveMode")
        
        let storedBrightness = settings.brightness?.floatValue ?? 0.0
        if storedBrightness < 0.1 {
            self.brightness = 2.2
        } else {
            self.brightness = storedBrightness
        }
        
        if let storedLang = UserDefaults.standard.object(forKey: appLanguageDefaultsKey) as? Int {
            self.appLanguageRaw = storedLang
        } else {
            self.appLanguageRaw = AppLanguage.english.rawValue
        }
        self.autoResumeStreamOnReopen = UserDefaults.standard.bool(forKey: "autoResumeStreamOnReopen")
        self.rememberStreamSettings = UserDefaults.standard.object(forKey: "rememberStreamSettings") as? Bool ?? true
        #endif

        super.init()
        
        // If we modified the values during the migration block above, save them back to Core Data now.
        if !UserDefaults.standard.bool(forKey: "hasSavedNewDefaults_v1") {
            // Simple check to see if our in-memory values differ from what we loaded
            if self.bitrate != loadedBitrate || self.height != loadedHeight {
                self.save()
                UserDefaults.standard.set(true, forKey: "hasSavedNewDefaults_v1")
            }
        }
    }

    @objc public func save() {
        // FIX: Save Immersive Mode to UserDefaults
        UserDefaults.standard.set(self.realitykitImmersiveMode, forKey: "realitykitImmersiveMode")
        UserDefaults.standard.set(self.autoResumeStreamOnReopen, forKey: "autoResumeStreamOnReopen")
        UserDefaults.standard.set(self.rememberStreamSettings, forKey: "rememberStreamSettings")

        // save settings to parent
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
                // Removed realitykitImmersiveMode from this call to fix the error
                dimPassthrough: dimPassthrough,
                brightness: brightness
        )
        UserDefaults.standard.set(appLanguageRaw, forKey: appLanguageDefaultsKey)
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

//
//  AudioHelpers.swift
//  Moonlight Vision
//
//  Created by Lumanaire (RikuKunMS2).
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import AVFAudio
import UIKit

class AudioHelpers {
    private static func configureAudioSession(exclusive: Bool) {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            let options: AVAudioSession.CategoryOptions = exclusive ? [] : [.mixWithOthers]
            try audioSession.setCategory(.playback, options: options)
            try audioSession.setMode(.moviePlayback)
            try audioSession.setActive(true)
        } catch {
            print("Failed to set the audio session mic/category configuration: \(error)")
        }
    }

    static func fixAudioForDirectStereo(exclusive: Bool = true) {
        print("AudioHelpers - Fix for direct stereo")
        configureAudioSession(exclusive: exclusive)

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setPreferredOutputNumberOfChannels(2)
            try audioSession.setIntendedSpatialExperience(.bypassed)
        } catch {
            print("Failed to set the audio session configuration?")
        }
    }

    static func fixAudioForSurroundForCurrentWindow(exclusive: Bool = true) {
        configureAudioSession(exclusive: exclusive)

        let audioSession = AVAudioSession.sharedInstance()
        do {
            if let id = UIApplication.shared.connectedScenes.first?.session.persistentIdentifier {
                print("AudioHelpers - Found current window \(id)")
                try audioSession.setPreferredOutputNumberOfChannels(audioSession.maximumOutputNumberOfChannels)
                try audioSession.setIntendedSpatialExperience(.headTracked(soundStageSize: .medium, anchoringStrategy: .scene(identifier: id)))
            } else {
                print("AudioHelpers - Couldn't find current window?")
                fixAudioForDirectStereo(exclusive: exclusive)
            }
        } catch {
            print("Failed to set the audio session configuration?")
        }
    }

    static func fixAudioForScene(identifier: String) {
        configureAudioSession(exclusive: true)
        
        let audioSession = AVAudioSession.sharedInstance()
        do {
            print("AudioHelpers - Anchoring audio to scene: \(identifier)")
            try audioSession.setPreferredOutputNumberOfChannels(audioSession.maximumOutputNumberOfChannels)
            try audioSession.setIntendedSpatialExperience(.headTracked(soundStageSize: .medium, anchoringStrategy: .scene(identifier: identifier)))
        } catch {
            print("AudioHelpers - Failed to anchor to scene \(identifier): \(error)")
        }
    }

    static func fixAudioForSurroundForUIKitWindow(_ window: UIWindow, exclusive: Bool = true) {
        configureAudioSession(exclusive: exclusive)

        let audioSession = AVAudioSession.sharedInstance()
        do {
            if let id = window.windowScene?.session.persistentIdentifier {
                print("AudioHelpers - Found UIKit window \(id)")
                try audioSession.setPreferredOutputNumberOfChannels(audioSession.maximumOutputNumberOfChannels)
                try audioSession.setIntendedSpatialExperience(.headTracked(soundStageSize: .medium, anchoringStrategy: .scene(identifier: id)))
            } else {
                fixAudioForDirectStereo(exclusive: exclusive)
            }
        } catch {
            print("AudioHelpers - Couldn't find UIKit window?")
            print("Failed to set the audio session configuration?")
        }
    }
    
    static func applySpatialAudioMode(_ mode: SpatialAudioMode, sceneIdentifier: String? = nil, window: UIWindow? = nil, exclusive: Bool = true) {
        switch mode {
        case .stereo:
            fixAudioForDirectStereo(exclusive: exclusive)
        case .window:
            if let window = window {
                fixAudioForSurroundForUIKitWindow(window, exclusive: exclusive)
            } else if let sceneIdentifier = sceneIdentifier {
                fixAudioForScene(identifier: sceneIdentifier)
            } else {
                fixAudioForSurroundForCurrentWindow(exclusive: exclusive)
            }
        case .surround:
            // Core Audio AUSpatialMixer will handle the 7.1 spatialization.
            // We bypass the AVAudioSession's RealityKit anchoring so it doesn't double-spatialize.
            print("AudioHelpers - Applying Surround mode (CoreAudio)")
            configureAudioSession(exclusive: exclusive)
            let audioSession = AVAudioSession.sharedInstance()
            do {
                try audioSession.setPreferredOutputNumberOfChannels(audioSession.maximumOutputNumberOfChannels)
                try audioSession.setIntendedSpatialExperience(.bypassed)
            } catch {
                print("AudioHelpers - Failed to set bypassed experience for surround: \(error)")
            }
        }
    }
}

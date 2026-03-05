import AVFAudio
import UIKit

class AudioHelpers {
    private static func configureAudioSession(exclusive: Bool) {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            if exclusive {
                try audioSession.setCategory(.playAndRecord, options: [.mixWithOthers, .allowBluetoothA2DP, .allowAirPlay])
                try audioSession.setMode(.voiceChat)
                try audioSession.setPreferredInputNumberOfChannels(1)
            } else {
                try audioSession.setCategory(.playback, options: [.mixWithOthers])
                try audioSession.setMode(.moviePlayback)
            }
            try audioSession.setActive(true)
        } catch {
            print("Failed to set the audio session mic/category configuration?")
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
}

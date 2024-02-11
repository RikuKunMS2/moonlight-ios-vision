//

import SwiftUI

struct SettingsView: View {
    @Binding public var settings: TemporarySettings

    var body: some View {
        NavigationStack {
            Form {
                Picker("Resolution", selection: $settings.resolution) {
                    ForEach(Self.resolutionTable, id: \.self) { resolution in
                        Text(resolution.description)
                    }
                }
                Picker("Framerate", selection: $settings.framerate) {
                    ForEach(Self.framerateTable, id: \.self) { framerate in
                        Text("\(framerate)")
                    }
                }
                Picker("Bitrate", selection: $settings.bitrate) {
                    ForEach(Self.bitrateTable, id: \.self) { bitrate in
                        Text("\(bitrate / 1000)Mbps")
                    }
                }
                Picker("Touch Mode", selection: $settings.absoluteTouchMode) {
                    Text("Touchpad").tag(false)
                    Text("Touchscreen").tag(true)
                }
                Picker("On-Screen Controls", selection: $settings.onscreenControls) {
                    Text("Off").tag(OnScreenControlsLevel.off)
                    Text("Auto").tag(OnScreenControlsLevel.auto)
                    Text("Simple").tag(OnScreenControlsLevel.simple)
                    Text("Full").tag(OnScreenControlsLevel.full)
                }
                Toggle("Optimize Game Settings", isOn: $settings.optimizeGames)
                Picker("Multi-Controller Mode", selection: $settings.multiController) {
                    Text("Single").tag(false)
                    Text("Auto").tag(true)
                }
                Toggle("Swap A/B and X/Y Buttons", isOn: $settings.swapABXYButtons)
                Toggle("Play Audio on PC", isOn: $settings.playAudioOnPC)
                Picker("Preferred Codec", selection: $settings.preferredCodec) {
                    Text("H.264").tag(PreferredCodec.h264)
                    Text("HEVC").tag(PreferredCodec.hevc)
                    Text("AV1").tag(PreferredCodec.av1)
                    Text("Auto").tag(PreferredCodec.auto)
                }
                Toggle("Enable HDR", isOn: $settings.enableHdr)
                Picker("Frame Pacing", selection: $settings.useFramePacing) {
                    Text("Lowest Latency").tag(false)
                    Text("Smoothest Video").tag(true)
                }
                Toggle("Citrix X1 Mouse Support", isOn: $settings.btMouseSupport)
                Toggle("Statistics Overlay", isOn: $settings.statsOverlay)
            }
            .frame(width: 450)
            .navigationTitle("Settings")
            .onDisappear {
                settings.save()
            }
        }
    }
    }

fileprivate extension TemporarySettings {
    var resolution: SettingsView.Resolution {
        get {
            SettingsView.Resolution(width: width, height: height)
        }
        set {
            width = newValue.width
            height = newValue.height
        }
    }
}

extension SettingsView {
    struct Resolution: Equatable, Hashable, CustomStringConvertible {
        let width: Int32
        let height: Int32
        
        var description: String {
            switch self {
            case Resolution(width: 3840, height: 2160):
                "4K"
            case _ where simplifyFraction(numerator: width, denominator: height) == simplifyFraction(numerator: 16, denominator: 9):
                "\(height)p"
            default:
                "\(width)x\(height)"
            }
        }
    }

    static let resolutionTable = [
        Resolution(width: 640, height: 360),
        Resolution(width: 1280, height: 720),
        Resolution(width: 1920, height: 1080),
        Resolution(width: 3840, height: 2160)
    ]
    
    static let framerateTable: [Int32] = [30, 60, 90, 120]
    
    static let bitrateTable: [Int32] = [5000, 10000, 30000, 50000, 75000, 100000, 120000, 200000]
}

// Functions to help with aspect ratio calculation
fileprivate func gcd<I: BinaryInteger>(_ a: I, _ b: I) -> I {
    var a = a
    var b = b
    while b != 0 {
        let temp = b
        b = a % b
        a = temp
    }
    return a
}

fileprivate func simplifyFraction<I: BinaryInteger>(numerator: I, denominator: I) -> (I, I) {
    let divisor = gcd(numerator, denominator)
    return (numerator / divisor, denominator / divisor)
}

#Preview {
    @State var settings = TemporarySettings()
    return SettingsView(settings: $settings)
}

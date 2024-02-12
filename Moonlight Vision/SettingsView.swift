//

import SwiftUI

struct SettingsView: View {
    @Binding public var settings: TemporarySettings

    var body: some View {
        NavigationStack {
            Form {
                NavigationLink {
                    Form {
                        Picker("Resolution", selection: $settings.resolution) {
                            ForEach(Self.resolutionsGroupedByType, id: \.0) { aspectRatio, resolutions in
                                ForEach(resolutions, id: \.self) { resolution in
                                    Text(resolution.description)
                                        .badge(aspectRatio.casualDescription)
                                }
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.inline)
                    }
                    .ornament(attachmentAnchor: .scene(.bottom)) {
                        HStack {
                            TextField("Width", value: $settings.resolution.width, format: .number)
                            Text("by")
                            TextField("Height", value: $settings.resolution.height, format: .number)
                        }
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding()
                        .glassBackgroundEffect()
                    }
                    .navigationTitle("Resolution")
                } label: {
                    HStack {
                        Text("Resolution")
                        Spacer()
                        Text(settings.resolution.description)
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
            .navigationTitle("Settings")
            .onDisappear {
                settings.save()
            }
        }
    .frame(width: 600)
    }
}

private extension TemporarySettings {
    var resolution: SettingsView.Resolution {
        get {
            SettingsView.Resolution(width: Int(width), height: Int(height))
        }
        set {
            width = Int32(newValue.width)
            height = Int32(newValue.height)
        }
    }
}

extension SettingsView {
    struct AspectRatio: Equatable, Hashable, Comparable {
        // Always stored as reduced values
        private let width: Int
        private let height: Int

        init(width: Int, height: Int) {
            let reduced = simplifyFraction(numerator: width, denominator: height)
            self.width = reduced.numerator
            self.height = reduced.denominator
        }

        var casualDescription: LocalizedStringKey {
            switch self {
            case AspectRatio(width: 16, height: 9):
                "Widescreen (TV)"
            case AspectRatio(width: 16, height: 10):
                "Widescreen (PC)"
            case AspectRatio(width: 4, height: 3):
                "4:3"
            case AspectRatio(width: 64, height: 27):
                "Ultrawide (64:27)"
            case AspectRatio(width: 43, height: 18):
                "Ultrawide (43:18)"
            case AspectRatio(width: 32, height: 9):
                "Super-Ultrawide"
            default:
                "\(width)-by-\(height)"
            }
        }

        // "Wider" means "larger"
        static func < (lhs: SettingsView.AspectRatio, rhs: SettingsView.AspectRatio) -> Bool {
            (Double(lhs.width) / Double(lhs.height)) < (Double(rhs.width) / Double(rhs.height))
        }
    }

    struct Resolution: Equatable, Hashable, CustomStringConvertible {
        var width: Int
        var height: Int

        var aspectRatio: AspectRatio {
            AspectRatio(width: width, height: height)
        }

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
        // 16:9
        Resolution(width: 1280, height: 720),
        Resolution(width: 1920, height: 1080),
        Resolution(width: 2560, height: 1440),
        Resolution(width: 3840, height: 2160),
        // 16:10
        Resolution(width: 1920, height: 1200),
        Resolution(width: 2560, height: 1600),
        // "21:9"
        Resolution(width: 2560, height: 1080),
        Resolution(width: 3440, height: 1440),
        // 32:9
        Resolution(width: 5120, height: 1440),
    ]

    static var resolutionsGroupedByType: [(AspectRatio, [Resolution])] {
        Dictionary(grouping: resolutionTable, by: \.aspectRatio).sorted { $0.key < $1.key }
    }

    static let framerateTable: [Int32] = [30, 60, 90, 120]

    static let bitrateTable: [Int32] = [5000, 10000, 30000, 50000, 75000, 100000, 120000, 200000]
}

// Functions to help with aspect ratio calculation
private func gcd<I: BinaryInteger>(_ a: I, _ b: I) -> I {
    var a = a
    var b = b
    while b != 0 {
        let temp = b
        b = a % b
        a = temp
    }
    return a
}

private func simplifyFraction<I: BinaryInteger>(numerator: I, denominator: I) -> (numerator: I, denominator: I) {
    let divisor = gcd(numerator, denominator)
    return (numerator / divisor, denominator / divisor)
}

#Preview {
    @State var settings = TemporarySettings()
    return SettingsView(settings: $settings)
}

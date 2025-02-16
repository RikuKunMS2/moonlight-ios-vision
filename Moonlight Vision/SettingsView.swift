//
//  SettomgsView.swift
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/22/24.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//


import SwiftUI

struct SettingsView: View {
    @Binding public var settings: TemporarySettings
    @State private var selectedAspectRatio: AspectRatio?
    @State private var isCustomAspectRatio: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Video settings")) {
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
                            .onChange(of: settings.resolution) { _ in
                                isCustomAspectRatio = !Self.resolutionTable.contains(settings.resolution)
                                if isCustomAspectRatio {
                                    selectedAspectRatio = nil
                                }
                            }
                        }
                        .navigationTitle("Resolution")
                    } label: {
                        HStack {
                            Text("Resolution")
                            Spacer()
                            Text(settings.resolution.description)
                        }
                    }
                    
                    NavigationLink {
                        Form {
                            Picker("Aspect Ratio", selection: $selectedAspectRatio) {
                                ForEach(Self.resolutionsGroupedByType.map { $0.0 }, id: \.self) { aspectRatio in
                                    Text(aspectRatio.casualDescription).tag(aspectRatio as AspectRatio?)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.inline)
                            HStack {
                                Spacer()
                                if let selectedAspectRatio {
                                    Text(selectedAspectRatio.casualDescription)
                                } else {
                                    Text("Custom")
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numberPad)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding()
                            .onChange(of: selectedAspectRatio) { newValue in
                                if let newAspectRatio = newValue {
                                    Task { @MainActor in
                                        updateResolutionForAspectRatio(newAspectRatio)
                                    }
                                    isCustomAspectRatio = false
                                }
                            }
                        }
                        .navigationTitle("Aspect Ratio")
                    } label: {
                        HStack {
                            Text("Aspect Ratio")
                            Spacer()
                            Text(settings.resolution.aspectRatio.casualDescription)
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
                    
                    Picker("Renderer", selection: $settings.renderer) {
                        Text("UIKit (classic)").tag(Renderer.classic)
                        Text("RealityKit (native)").tag(Renderer.realitykit)
                    }
                }
                if (settings.renderer == .realitykit) {
                    Section(header: Text("RealityKit Renderer Settings (Experimental)"), footer: Text("The new RealityKit renderer is experemental and currently does not support keyboard or mouse, come at me on reddit u/tht7 if you care")) {
                        Toggle("Animate screen curve", isOn: $settings.realitykitRendererAnimateOpening)
                        Text("Screen curvature")
                        Slider(value: $settings.realitykitRendererCurvature, in: (0...1), step: 0.001)
                    }
                } else {
                    Section(header: Text("UIKit (Classic) Renderer Settings")) {
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
                        Toggle("Citrix X1 Mouse Support", isOn: $settings.btMouseSupport)
                        Toggle("Statistics Overlay", isOn: $settings.statsOverlay)
                    }
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
                Toggle("Automatically dim passthrough and hide window controls", isOn: $settings.dimPassthrough)
            }
            .navigationTitle("Settings")
            .onDisappear {
                settings.save()
            }
            .frame(width: 600)
            .onAppear {
                selectedAspectRatio = settings.resolution.aspectRatio
                isCustomAspectRatio = !Self.resolutionTable.contains(settings.resolution)
            }
        }
    }

    @MainActor
    private func updateResolutionForAspectRatio(_ newAspectRatio: AspectRatio) {
        // Get current width and height
        let currentWidth = settings.resolution.width
        let currentHeight = settings.resolution.height

        // Maintain the same width or height and adjust the other according to the new aspect ratio
        if currentWidth >= currentHeight {
            settings.resolution = Resolution(width: currentWidth, height: (currentWidth * newAspectRatio.height) / newAspectRatio.width)
        } else {
            settings.resolution = Resolution(width: (currentHeight * newAspectRatio.width) / newAspectRatio.height, height: currentHeight)
        }
        isCustomAspectRatio = false
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
        private(set) var width: Int
        private(set) var height: Int

        init(width: Int, height: Int) {
            let reduced = simplifyFraction(numerator: width, denominator: height)
            self.width = reduced.numerator
            self.height = reduced.denominator
        }

        var casualDescription: LocalizedStringKey {
            switch self {
            case AspectRatio(width: 16, height: 9):
                "16:9"
            case AspectRatio(width: 16, height: 10):
                "16:10"
            case AspectRatio(width: 4, height: 3):
                "4:3"
            case AspectRatio(width: 64, height: 27):
                "'21:9' 2560x1080 or 5120x2160"
            case AspectRatio(width: 43, height: 18):
                "'21:9' 3440x1440"
            case AspectRatio(width: 24, height: 10):
                "24:10 3840x1600"
            case AspectRatio(width: 64, height: 18):
                "32:9"
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
            case Resolution(width: 5120, height: 2880):
                "5K"
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
        Resolution(width: 5120, height: 2880),
        // 16:10
        Resolution(width: 1920, height: 1200),
        Resolution(width: 2560, height: 1600),
        // "21:9"
        Resolution(width: 2560, height: 1080),
        Resolution(width: 5120, height: 2160),
        Resolution(width: 3440, height: 1440),
        Resolution(width: 3840, height: 1600),
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

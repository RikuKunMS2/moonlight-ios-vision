//
//  SettingsView.swift
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/22/24.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

struct SettingsView: View {
    @Binding public var settings: TemporarySettings
    @EnvironmentObject private var viewModel: MainViewModel
    @State private var selectedAspectRatio: AspectRatio?
    @State private var isCustomAspectRatio: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(viewModel.localized("video_settings"))) {
                    NavigationLink {
                        Form {
                            Picker(viewModel.localized("resolution"), selection: $settings.resolution) {
                                ForEach(Self.resolutionsGroupedByType, id: \.0) { aspectRatio, resolutions in
                                    ForEach(resolutions, id: \.self) { resolution in
                                        Text(resolution.description)
                                            .badge(aspectRatio.casualDescription)
                                    }
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.inline)
                            // Save immediately when resolution changes
                            .onChange(of: settings.resolution) { _, _ in
                                settings.save()
                            }
                        }
                        .ornament(attachmentAnchor: .scene(.bottom)) {
                            HStack {
                                TextField(viewModel.localized("width"), value: $settings.resolution.width, format: .number)
                                Text(viewModel.localized("by"))
                                TextField(viewModel.localized("height"), value: $settings.resolution.height, format: .number)
                            }
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numberPad)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding()
                            .glassBackgroundEffect()
                            .onChange(of: settings.resolution) { _, _ in
                                isCustomAspectRatio = !Self.resolutionTable.contains(settings.resolution)
                                if isCustomAspectRatio {
                                    selectedAspectRatio = nil
                                }
                                // Save custom resolution changes immediately
                                settings.save()
                            }
                        }
                        .navigationTitle(viewModel.localized("resolution"))
                    } label: {
                        HStack {
                            Text(viewModel.localized("resolution"))
                            Spacer()
                            Text(settings.resolution.description)
                        }
                    }
                    
                    NavigationLink {
                        Form {
                            Picker(viewModel.localized("aspect_ratio"), selection: $selectedAspectRatio) {
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
                                    Text(viewModel.localized("custom"))
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
                                }
                            }
                        }
                        .navigationTitle(viewModel.localized("aspect_ratio"))
                    } label: {
                        HStack {
                            Text(viewModel.localized("aspect_ratio"))
                            Spacer()
                            Text(settings.resolution.aspectRatio.casualDescription)
                        }
                    }
                    
                    Picker(viewModel.localized("framerate"), selection: $settings.framerate) {
                        ForEach(Self.framerateTable, id: \.self) { framerate in
                            Text("\(framerate)")
                        }
                    }
                    .onChange(of: settings.framerate) { _, _ in settings.save() }
                    
                    Picker(viewModel.localized("bitrate"), selection: $settings.bitrate) {
                        ForEach(Self.bitrateTable, id: \.self) { bitrate in
                            Text("\(bitrate / 1000)Mbps")
                        }
                    }
                    .onChange(of: settings.bitrate) { _, _ in settings.save() }
                    
                    Picker(viewModel.localized("renderer"), selection: $settings.renderer) {
                        Text(viewModel.localized("uikit_classic")).tag(Renderer.classic)
                        Text(viewModel.localized("realitykit_native")).tag(Renderer.realitykit)
                    }
                    .onChange(of: settings.renderer) { _, _ in settings.save() }
                }
                
                if (settings.renderer == .realitykit) {
                    Section(header: Text(viewModel.localized("realitykit_settings")), footer: Text(viewModel.localized("realitykit_footer"))) {
                        // Add this Toggle
                                Toggle(viewModel.localized("immersive_mode"), isOn: $settings.realitykitImmersiveMode)
                                    .onChange(of: settings.realitykitImmersiveMode) { _, _ in settings.save() }
                        Toggle(viewModel.localized("animate_screen_curve"), isOn: $settings.realitykitRendererAnimateOpening)
                            .onChange(of: settings.realitykitRendererAnimateOpening) { _, _ in settings.save() }
                        
                        Text(viewModel.localized("screen_curvature"))
                        Slider(value: $settings.realitykitRendererCurvature, in: (0...1), step: 0.001)
                            .onChange(of: settings.realitykitRendererCurvature) { _, _ in settings.save() }
                    }
                }
                
                Section(header: Text(viewModel.localized("stream_settings"))) {
                    Toggle(viewModel.localized("remember_stream_settings"), isOn: $settings.rememberStreamSettings)
                        .onChange(of: settings.rememberStreamSettings) { _, _ in settings.save() }
                }
                
                if (settings.renderer == .classic) {
                    Section(header: Text(viewModel.localized("uikit_settings"))) {
                        Picker(viewModel.localized("touch_mode"), selection: $settings.absoluteTouchMode) {
                            Text(viewModel.localized("touchpad")).tag(false)
                            Text(viewModel.localized("touchscreen")).tag(true)
                        }
                        .onChange(of: settings.absoluteTouchMode) { _, _ in settings.save() }
                        
                        Picker(viewModel.localized("on_screen_controls"), selection: $settings.onscreenControls) {
                            Text(viewModel.localized("off")).tag(OnScreenControlsLevel.off)
                            Text(viewModel.localized("auto")).tag(OnScreenControlsLevel.auto)
                            Text(viewModel.localized("simple")).tag(OnScreenControlsLevel.simple)
                            Text(viewModel.localized("full")).tag(OnScreenControlsLevel.full)
                        }
                        .onChange(of: settings.onscreenControls) { _, _ in settings.save() }
                        
                        Toggle(viewModel.localized("citrix_x1_mouse"), isOn: $settings.btMouseSupport)
                            .onChange(of: settings.btMouseSupport) { _, _ in settings.save() }
                        
                        Toggle(viewModel.localized("statistics_overlay"), isOn: $settings.statsOverlay)
                            .onChange(of: settings.statsOverlay) { _, _ in settings.save() }
                    }
                }
                
                Toggle(viewModel.localized("optimize_game_settings"), isOn: $settings.optimizeGames)
                    .onChange(of: settings.optimizeGames) { _, _ in settings.save() }
                
                Picker(viewModel.localized("multi_controller_mode"), selection: $settings.multiController) {
                    Text(viewModel.localized("single")).tag(false)
                    Text(viewModel.localized("auto")).tag(true)
                }
                .onChange(of: settings.multiController) { _, _ in settings.save() }
                
                Toggle(viewModel.localized("swap_abxy_buttons"), isOn: $settings.swapABXYButtons)
                    .onChange(of: settings.swapABXYButtons) { _, _ in settings.save() }
                
                Toggle(viewModel.localized("play_audio_on_pc"), isOn: $settings.playAudioOnPC)
                    .onChange(of: settings.playAudioOnPC) { _, _ in settings.save() }
                
                Picker(viewModel.localized("preferred_codec"), selection: $settings.preferredCodec) {
                    Text(viewModel.localized("h264")).tag(PreferredCodec.h264)
                    Text(viewModel.localized("hevc")).tag(PreferredCodec.hevc)
                    Text(viewModel.localized("av1")).tag(PreferredCodec.av1)
                    Text(viewModel.localized("auto")).tag(PreferredCodec.auto)
                }
                .onChange(of: settings.preferredCodec) { _, _ in settings.save() }
                
                Toggle(viewModel.localized("enable_hdr"), isOn: $settings.enableHdr)
                    .onChange(of: settings.enableHdr) { _, _ in settings.save() }
                
                Picker(viewModel.localized("frame_pacing"), selection: $settings.useFramePacing) {
                    Text(viewModel.localized("lowest_latency")).tag(false)
                    Text(viewModel.localized("smoothest_video")).tag(true)
                }
                .onChange(of: settings.useFramePacing) { _, _ in settings.save() }
                
                Toggle(viewModel.localized("dim_passthrough"), isOn: $settings.dimPassthrough)
                    .onChange(of: settings.dimPassthrough) { _, _ in settings.save() }
                
                Picker(viewModel.localized("app_language"), selection: Binding(get: { settings.appLanguage }, set: { newLanguage in
                    settings.appLanguage = newLanguage
                    settings.save()
                    // Trigger view update when language changes
                    viewModel.objectWillChange.send()
                })) {
                    ForEach(Array(AppLanguage.allCases), id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
            }
            .navigationTitle(viewModel.localized("settings"))
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
        
        // Save immediately after calculating the new resolution
        settings.save()
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

    static let bitrateTable: [Int32] = [
            5000, 10000, 30000, 50000, 75000, 100000, 120000, 150000,
            200000, 300000, 400000, 500000, 600000
        ]
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

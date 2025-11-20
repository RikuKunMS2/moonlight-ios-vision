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
                Section(header: Text(viewModel.localized(english: "Video settings", chinese: "视频设置"))) {
                    NavigationLink {
                        Form {
                            Picker(viewModel.localized(english: "Resolution", chinese: "分辨率"), selection: $settings.resolution) {
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
                                TextField(viewModel.localized(english: "Width", chinese: "宽度"), value: $settings.resolution.width, format: .number)
                                Text(viewModel.localized(english: "by", chinese: "×"))
                                TextField(viewModel.localized(english: "Height", chinese: "高度"), value: $settings.resolution.height, format: .number)
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
                        .navigationTitle(viewModel.localized(english: "Resolution", chinese: "分辨率"))
                    } label: {
                        HStack {
                            Text(viewModel.localized(english: "Resolution", chinese: "分辨率"))
                            Spacer()
                            Text(settings.resolution.description)
                        }
                    }
                    
                    NavigationLink {
                        Form {
                            Picker(viewModel.localized(english: "Aspect Ratio", chinese: "宽高比"), selection: $selectedAspectRatio) {
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
                                    Text(viewModel.localized(english: "Custom", chinese: "自定义"))
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
                        .navigationTitle(viewModel.localized(english: "Aspect Ratio", chinese: "宽高比"))
                    } label: {
                        HStack {
                            Text(viewModel.localized(english: "Aspect Ratio", chinese: "宽高比"))
                            Spacer()
                            Text(settings.resolution.aspectRatio.casualDescription)
                        }
                    }
                    Picker(viewModel.localized(english: "Framerate", chinese: "帧率"), selection: $settings.framerate) {
                        ForEach(Self.framerateTable, id: \.self) { framerate in
                            Text("\(framerate)")
                        }
                    }
                    .onChange(of: settings.framerate) { _, _ in settings.save() }
                    
                    Picker(viewModel.localized(english: "Bitrate", chinese: "比特率"), selection: $settings.bitrate) {
                        ForEach(Self.bitrateTable, id: \.self) { bitrate in
                            Text("\(bitrate / 1000)Mbps")
                        }
                    }
                    .onChange(of: settings.bitrate) { _, _ in settings.save() }
                    
                    Picker(viewModel.localized(english: "Renderer", chinese: "渲染器"), selection: $settings.renderer) {
                        Text(viewModel.localized(english: "UIKit (classic)", chinese: "UIKit（经典）")).tag(Renderer.classic)
                        Text(viewModel.localized(english: "RealityKit (native)", chinese: "RealityKit（原生）")).tag(Renderer.realitykit)
                    }
                    .onChange(of: settings.renderer) { _, _ in settings.save() }
                }
                
                if (settings.renderer == .realitykit) {
                    Section(header: Text(viewModel.localized(english: "RealityKit Renderer Settings (Experimental)", chinese: "RealityKit 渲染器设置（实验性）")), footer: Text(viewModel.localized(english: "The new RealityKit renderer is experemental and does not support tap to control mouse, but will support a physical mouse and keyboard", chinese: "新的 RealityKit 渲染器是实验性的，不支持点击控制鼠标，但支持物理鼠标和键盘"))) {
                        Toggle(viewModel.localized(english: "Immersive Mode (Movable Screen)", chinese: "沉浸模式（可移动屏幕）"), isOn: $settings.realitykitImmersiveMode)
                            .onChange(of: settings.realitykitImmersiveMode) { _, _ in settings.save() }
                        Toggle(viewModel.localized(english: "Animate screen curve", chinese: "屏幕曲线动画"), isOn: $settings.realitykitRendererAnimateOpening)
                            .onChange(of: settings.realitykitRendererAnimateOpening) { _, _ in settings.save() }
                        
                        Text(viewModel.localized(english: "Screen curvature", chinese: "屏幕曲面度"))
                        Slider(value: $settings.realitykitRendererCurvature, in: (0...1), step: 0.001)
                            .onChange(of: settings.realitykitRendererCurvature) { _, _ in settings.save() }
                    }
                } else {
                    Section(header: Text(viewModel.localized(english: "UIKit (Classic) Renderer Settings", chinese: "UIKit（经典）渲染器设置"))) {
                        Picker(viewModel.localized(english: "Touch Mode", chinese: "触摸模式"), selection: $settings.absoluteTouchMode) {
                            Text(viewModel.localized(english: "Touchpad", chinese: "触控板")).tag(false)
                            Text(viewModel.localized(english: "Touchscreen", chinese: "触摸屏")).tag(true)
                        }
                        .onChange(of: settings.absoluteTouchMode) { _, _ in settings.save() }
                        
                        Picker(viewModel.localized(english: "On-Screen Controls", chinese: "屏幕控制"), selection: $settings.onscreenControls) {
                            Text(viewModel.localized(english: "Off", chinese: "关闭")).tag(OnScreenControlsLevel.off)
                            Text(viewModel.localized(english: "Auto", chinese: "自动")).tag(OnScreenControlsLevel.auto)
                            Text(viewModel.localized(english: "Simple", chinese: "简单")).tag(OnScreenControlsLevel.simple)
                            Text(viewModel.localized(english: "Full", chinese: "完整")).tag(OnScreenControlsLevel.full)
                        }
                        .onChange(of: settings.onscreenControls) { _, _ in settings.save() }
                        
                        Toggle(viewModel.localized(english: "Citrix X1 Mouse Support", chinese: "Citrix X1 鼠标支持"), isOn: $settings.btMouseSupport)
                            .onChange(of: settings.btMouseSupport) { _, _ in settings.save() }
                        
                        Toggle(viewModel.localized(english: "Statistics Overlay", chinese: "统计信息叠加"), isOn: $settings.statsOverlay)
                            .onChange(of: settings.statsOverlay) { _, _ in settings.save() }
                    }
                }
                
                Section(header: Text(viewModel.localized(english: "Stream Settings", chinese: "串流设置"))) {
                    Toggle(viewModel.localized(english: "Remember stream settings", chinese: "记住串流设置"), isOn: $settings.rememberStreamSettings)
                        .onChange(of: settings.rememberStreamSettings) { _, _ in settings.save() }
                }
                
                Toggle(viewModel.localized(english: "Optimize Game Settings", chinese: "优化游戏设置"), isOn: $settings.optimizeGames)
                    .onChange(of: settings.optimizeGames) { _, _ in settings.save() }
                
                Picker(viewModel.localized(english: "Multi-Controller Mode", chinese: "多控制器模式"), selection: $settings.multiController) {
                    Text(viewModel.localized(english: "Single", chinese: "单个")).tag(false)
                    Text(viewModel.localized(english: "Auto", chinese: "自动")).tag(true)
                }
                .onChange(of: settings.multiController) { _, _ in settings.save() }
                
                Toggle(viewModel.localized(english: "Swap A/B and X/Y Buttons", chinese: "交换 A/B 和 X/Y 按钮"), isOn: $settings.swapABXYButtons)
                    .onChange(of: settings.swapABXYButtons) { _, _ in settings.save() }
                
                Toggle(viewModel.localized(english: "Play Audio on PC", chinese: "在 PC 上播放音频"), isOn: $settings.playAudioOnPC)
                    .onChange(of: settings.playAudioOnPC) { _, _ in settings.save() }
                
                Picker(viewModel.localized(english: "Audio Session Mode", chinese: "音频会话模式"), selection: $settings.audioSessionMode) {
                    ForEach(Array(AudioSessionMode.allCases), id: \.self) { mode in
                        Text(mode.localizedDisplayName(for: viewModel.currentLanguage)).tag(mode)
                    }
                }
                .onChange(of: settings.audioSessionMode) { _, _ in settings.save() }
                
                Picker(viewModel.localized(english: "App Language", chinese: "应用语言"), selection: Binding(get: { settings.appLanguage }, set: { settings.appLanguage = $0 })) {
                    ForEach(Array(AppLanguage.allCases), id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .onChange(of: settings.appLanguage) { _, _ in
                    settings.save()
                    viewModel.objectWillChange.send()
                }
                
                HStack {
                    Text(viewModel.localized(english: "Window Corner Radius", chinese: "窗口圆角"))
                    Spacer()
                    Slider(value: $settings.windowCornerRadius, in: 0...60, step: 5) {
                        Text(viewModel.localized(english: "Window Corner Radius", chinese: "窗口圆角"))
                    }
                    .frame(width: 200)
                    Text("\(Int(settings.windowCornerRadius))")
                }
                .onChange(of: settings.windowCornerRadius) { _, _ in settings.save() }
                
                if settings.windowCornerRadius > 0 {
                    Text(viewModel.localized(english: "Note: Corner radius may slightly affect rendering sharpness. Set to 0 for maximum clarity.", chinese: "注意：圆角可能会略微影响渲染清晰度。设置为 0 可获得最佳清晰度。"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Picker(viewModel.localized(english: "Preferred Codec", chinese: "首选编解码器"), selection: $settings.preferredCodec) {
                    Text("H.264").tag(PreferredCodec.h264)
                    Text("HEVC").tag(PreferredCodec.hevc)
                    Text("AV1").tag(PreferredCodec.av1)
                    Text(viewModel.localized(english: "Auto", chinese: "自动")).tag(PreferredCodec.auto)
                }
                .onChange(of: settings.preferredCodec) { _, _ in settings.save() }
                
                Toggle(viewModel.localized(english: "Enable HDR", chinese: "启用 HDR"), isOn: $settings.enableHdr)
                    .onChange(of: settings.enableHdr) { _, _ in settings.save() }
                
                Picker(viewModel.localized(english: "Frame Pacing", chinese: "帧节奏"), selection: $settings.useFramePacing) {
                    Text(viewModel.localized(english: "Lowest Latency", chinese: "最低延迟")).tag(false)
                    Text(viewModel.localized(english: "Smoothest Video", chinese: "最流畅视频")).tag(true)
                }
                .onChange(of: settings.useFramePacing) { _, _ in settings.save() }
                
                Toggle(viewModel.localized(english: "Automatically dim passthrough and hide window controls", chinese: "自动调暗穿透并隐藏窗口控制"), isOn: $settings.dimPassthrough)
                    .onChange(of: settings.dimPassthrough) { _, _ in settings.save() }
            }
            .navigationTitle(viewModel.localized(english: "Settings", chinese: "设置"))
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


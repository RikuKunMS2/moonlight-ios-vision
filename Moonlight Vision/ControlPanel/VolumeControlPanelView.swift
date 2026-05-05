//
//  VolumeControlPanelView.swift
//  Moonlight Vision
//
//  Created by Lumanaire (RikuKunMS2).
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Control panel for volumetric (non-immersive) RealityKit window.
//  Horizontal layout like immersive; depth/height/tilt + curvature + UIKit-style dimming.
//  No: environment picker, pin to stage, immersion amount.
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

/// Volume window control panel - depth/height/tilt work; uses simple dimPassthrough dimming.
struct VolumeControlPanelView: View {
    @EnvironmentObject private var viewModel: MainViewModel
    @EnvironmentObject private var controlState: StreamControlState
    
    var homeAction: (() -> Void)?
    let closeAction: () -> Void
    var toggleKeyboardAction: (() -> Void)?
    var isKeyboardActive: Bool = false
    
    @Binding var inputMode: InputMode
    
    @Binding var depthOffset: Float
    @Binding var height: Float
    var zLimits: ClosedRange<Float>
    var yLimits: ClosedRange<Float>
    var needsHdr: Bool = false
    
    // Spatial audio mode state is now in viewModel.streamSettings.spatialAudioMode
    @State private var saveTimer: Timer?
    @State private var dimPassthroughSaveTimer: Timer?
    
    private var isHdrEnabled: Bool {
        controlState.needsHdr || viewModel.streamSettings.enableHdr
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            leftSection
                .frame(width: 420)
                .padding(40)
            
            Divider()
                .padding(.vertical, 40)
            
            if isHdrEnabled {
                centerSection
                    .frame(width: 480)
                    .padding(40)
                
                Divider()
                    .padding(.vertical, 40)
                
                rightSection
                    .frame(width: 480)
                    .padding(40)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    centerSection
                    
                    Divider()
                        .padding(.vertical, 28)
                    
                    rightSection
                }
                .frame(width: 480)
                .padding(40)
            }
        }
        .frame(width: isHdrEnabled ? 1600 : 1100, height: 650)
        .glassBackgroundEffect()
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    controlState.isControlPanelVisible = false
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .padding(40)
        }
        .onChange(of: viewModel.streamSettings.brightness) { _, _ in debouncedSave() }
        .onChange(of: viewModel.streamSettings.gamma) { _, _ in debouncedSave() }
        .onChange(of: viewModel.streamSettings.saturation) { _, _ in debouncedSave() }
        .onChange(of: viewModel.streamSettings.pqExposure) { _, _ in debouncedSave() }
        .onChange(of: viewModel.streamSettings.realitykitRendererCurvature) { _, _ in debouncedSave() }
        .onChange(of: viewModel.streamSettings.dimPassthrough) { _, _ in debouncedSaveDimPassthrough() }
        .onChange(of: depthOffset) { _, _ in debouncedSave() }
        .onChange(of: height) { _, _ in debouncedSave() }
        .onChange(of: controlState.tiltAngle) { _, _ in debouncedSave() }
        .onDisappear {
            saveTimer?.invalidate()
            dimPassthroughSaveTimer?.invalidate()
            saveVolumeSettings()
        }
    }
    
    private var leftSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            SectionHeader(title: viewModel.localized("quick_actions"), icon: "square.grid.2x2")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ModernActionTile(icon: "house.fill", title: viewModel.localized("home")) {
                    (homeAction ?? closeAction)()
                }
                ModernActionTile(
                    icon: viewModel.streamSettings.dimPassthrough ? "sun.max.fill" : "moon.fill",
                    title: viewModel.streamSettings.dimPassthrough ? viewModel.localized("restore_brightness") : viewModel.localized("toggle_dimming"),
                    isActive: viewModel.streamSettings.dimPassthrough
                ) {
                    withAnimation { viewModel.streamSettings.dimPassthrough.toggle() }
                }
                
                // Input Mode Menu
                Menu {
                    Button(action: { inputMode = .gazeControl }) { Label("Gaze Control", systemImage: "eye") }
                    Button(action: { inputMode = .controller; viewModel.streamSettings.fpsMouseCapture = false; viewModel.streamSettings.save() }) { Label("Absolute Mouse", systemImage: "cursorarrow") }
                    Button(action: { inputMode = .controller; viewModel.streamSettings.fpsMouseCapture = true; viewModel.streamSettings.save() }) { Label("FPS Locked Mouse", systemImage: "cursorarrow.and.square.on.square.dashed") }
                } label: {
                    VStack(spacing: 10) {
                        Image(systemName: inputMode == .gazeControl ? "eye" : (viewModel.streamSettings.fpsMouseCapture ? "cursorarrow.and.square.on.square.dashed" : "cursorarrow"))
                            .font(.system(size: 24))
                            .foregroundStyle(Color.black)
                        
                        Text(inputMode == .gazeControl ? "Gaze Mode" : (viewModel.streamSettings.fpsMouseCapture ? "FPS Mouse" : "Absolute Mouse"))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(Color.black.opacity(0.8))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color.white))
                }
                .buttonStyle(.plain)
                .hoverEffect(.lift)
                // Spatial audio
                let currentMode = SpatialAudioMode(rawValue: viewModel.streamSettings.spatialAudioMode) ?? .window
                let fallback = controlState.isAudioFallbackModeActive
                ModernActionTile(
                    icon: fallback ? "exclamationmark.triangle.fill" : (currentMode == .surround ? "speaker.wave.3.fill" : (currentMode == .window ? "person.fill.viewfinder" : "headphones")),
                    title: fallback ? "Audio: Mic in Use" : (currentMode == .surround ? "7.1 Surround" : (currentMode == .window ? viewModel.localized("spatial_audio") : viewModel.localized("stereo_audio"))),
                    isActive: fallback || currentMode != .stereo
                ) {
                    withAnimation {
                        let nextModeRaw = (currentMode.rawValue + 1) % 3
                        viewModel.streamSettings.spatialAudioMode = nextModeRaw
                        let nextMode = SpatialAudioMode(rawValue: nextModeRaw) ?? .window
                        AudioHelpers.applySpatialAudioMode(nextMode)
                    }
                }
                ModernActionTile(
                    icon: "cube.transparent.fill",
                    title: viewModel.localized("3d_mode"),
                    isActive: controlState.videoMode == .sideBySide3D
                ) {
                    withAnimation { controlState.toggle3DMode?() }
                }
                ModernActionTile(
                    icon: viewModel.streamSettings.statsOverlay ? "chart.bar.fill" : "chart.bar",
                    title: viewModel.localized("stats_overlay"),
                    isActive: viewModel.streamSettings.statsOverlay
                ) {
                    withAnimation { viewModel.streamSettings.statsOverlay.toggle() }
                }
                ModernActionTile(
                    icon: "shareplay",
                    title: "SharePlay",
                    isActive: false
                ) {
                    SharePlayManager.shared.startSharePlay()
                }
                ModernActionTile(
                    icon: "light.beacon.max.fill",
                    title: "Reactive Lighting",
                    isActive: viewModel.streamSettings.reactiveLightingEnabled
                ) {
                    withAnimation {
                        viewModel.streamSettings.reactiveLightingEnabled.toggle()
                        controlState.reactiveLighting = viewModel.streamSettings.reactiveLightingEnabled
                        UserDefaults.standard.set(viewModel.streamSettings.reactiveLightingEnabled, forKey: "reactiveLightingEnabled")
                    }
                }
                if let toggle = toggleKeyboardAction {
                    ModernActionTile(icon: "keyboard.fill", title: viewModel.localized("virtual_keyboard"), isActive: isKeyboardActive) {
                        withAnimation { toggle() }
                    }
                }
            }
            volumeControl
        }
    }
    
    private var centerSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            SectionHeader(title: viewModel.localized("display_effects"), icon: "display")
            Grid(horizontalSpacing: 20, verticalSpacing: 24) {
                if isHdrEnabled {
                    SteppedSliderRow(title: viewModel.localized("brightness"), value: $viewModel.streamSettings.brightness, range: 0.5...3.0, defaultValue: 1.0, format: "%.2f", step: 0.01)
                    SteppedSliderRow(title: viewModel.localized("contrast"), value: $viewModel.streamSettings.gamma, range: 0.5...3.0, defaultValue: 1.0, format: "%.2f", step: 0.01)
                    SteppedSliderRow(title: viewModel.localized("saturation"), value: $viewModel.streamSettings.saturation, range: 0.5...3.0, defaultValue: 1.0, format: "%.2f", step: 0.01)
                    SteppedSliderRow(title: viewModel.localized("pq_hdr_exposure"), value: $viewModel.streamSettings.pqExposure, range: 0.25...2.5, defaultValue: 1.0, format: "%.2f", step: 0.01)
                }
                SteppedSliderRow(title: viewModel.localized("screen_curvature"), value: $viewModel.streamSettings.realitykitRendererCurvature, range: 0...1, defaultValue: 0.0, format: "%.3f", step: 0.01)
            }
        }
    }
    
    private var rightSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            SectionHeader(title: viewModel.localized("spatial_adjustments"), icon: "move.3d")
            Grid(horizontalSpacing: 20, verticalSpacing: 24) {
                SteppedSliderRow(title: viewModel.localized("depth"), value: $depthOffset, range: zLimits, defaultValue: 0.0, format: "%.2f", step: 0.01)
                SteppedSliderRow(title: viewModel.localized("vertical_height"), value: $height, range: yLimits, defaultValue: 0.0, format: "%.2f", step: 0.01)
                SteppedSliderRow(
                    title: viewModel.localized("screen_tilt"),
                    value: Binding(get: { controlState.tiltAngle }, set: { controlState.tiltAngle = $0 }),
                    range: -60.0...60.0,
                    defaultValue: 0.0,
                    format: "%.0f°",
                    step: 1.0
                )
            }
        }
    }
    
    private var volumeControl: some View {
        VStack(spacing: 12) {
            HStack {
                Label(viewModel.localized("volume"), systemImage: viewModel.mute ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.subheadline)
                    .foregroundStyle(viewModel.mute ? .secondary : .primary)
                Spacer()
                Text("\(Int(viewModel.vol))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .onTapGesture { withAnimation { viewModel.mute.toggle() } }
            Slider(value: Binding(
                get: { viewModel.vol },
                set: { viewModel.vol = $0; setVolume(Int32($0)) }
            ), in: 0...127)
                .tint(.white)
        }
        .padding(16)
        .background(Material.regular)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.top, 8)
    }
    
    private func debouncedSave() {
        guard viewModel.streamSettings.rememberStreamSettings else { return }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            saveVolumeSettings()
        }
    }
    
    private func debouncedSaveDimPassthrough() {
        dimPassthroughSaveTimer?.invalidate()
        dimPassthroughSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            if viewModel.streamSettings.rememberStreamSettings {
                UserDefaults.standard.set(viewModel.streamSettings.dimPassthrough, forKey: "realitykitVolumeDimPassthrough")
            }
            viewModel.streamSettings.save()
        }
    }
    
    private func saveVolumeSettings() {
        guard viewModel.streamSettings.rememberStreamSettings else { return }
        let defaults = UserDefaults.standard
        defaults.set(height, forKey: "realitykitHeight")
        defaults.set(depthOffset, forKey: "realitykitDepthOffset")
        viewModel.streamSettings.realitykitRendererTilt = controlState.tiltAngle
        defaults.set(viewModel.streamSettings.realitykitRendererCurvature, forKey: "realitykitVolumeCurvature")
        defaults.set(viewModel.streamSettings.gamma, forKey: "realitykitVolumeGamma")
        defaults.set(viewModel.streamSettings.saturation, forKey: "realitykitVolumeSaturation")
        defaults.set(viewModel.streamSettings.brightness, forKey: "realitykitVolumeBrightness")
        defaults.set(viewModel.streamSettings.pqExposure, forKey: "realitykitVolumePqExposure")
        defaults.set(viewModel.streamSettings.dimPassthrough, forKey: "realitykitVolumeDimPassthrough")
        viewModel.streamSettings.save()
    }
}

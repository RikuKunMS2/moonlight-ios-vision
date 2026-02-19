//
//  StandardControlPanelView.swift
//  Moonlight Vision
//
//  Standard mode (non-immersive) control panel - uses the same design style as immersive control panel
//  Created by Linggan-ua on 2025/12/03.
//

import SwiftUI

/// Standard mode control panel view
struct StandardControlPanelView: View {
    @EnvironmentObject private var viewModel: MainViewModel
    
    let closeAction: () -> Void
    let toggleKeyboardAction: (() -> Void)?
    let isKeyboardActive: Bool
    
    // RealityKit spatial adjustment parameters (optional)
    var depthOffset: Binding<Float>? = nil
    var height: Binding<Float>? = nil
    var zLimits: ClosedRange<Float>? = nil
    var yLimits: ClosedRange<Float>? = nil
    var needsHdr: Bool = false
    var isRealityKit: Bool = false
    
    // UIKit window button (optional)
    var windowButtonAction: (() -> Void)? = nil
    
    // Spatial audio mode state
    @State private var spatialAudioMode: Bool = true
    
    // Debounce timer for settings save
    @State private var saveTimer: Timer?
    @State private var dimPassthroughSaveTimer: Timer?
    
    var body: some View {
        VStack(spacing: 0) {
            // Quick actions section
            quickActionsSection
            
            Divider()
                .padding(.vertical, 16)
            
            // Display settings section
            displaySettingsSection
            
            // Only show spatial adjustments in RealityKit mode
            if isRealityKit && depthOffset != nil && height != nil {
                Divider()
                    .padding(.vertical, 16)
                
                spatialSettingsSection
            }
        }
        .padding(24)
        .frame(width: 500)
        .glassBackgroundEffect()
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onChange(of: viewModel.streamSettings.brightness) { _, _ in debouncedSave() }
        .onChange(of: viewModel.streamSettings.gamma) { _, _ in debouncedSave() }
        .onChange(of: viewModel.streamSettings.saturation) { _, _ in debouncedSave() }
        .onChange(of: viewModel.streamSettings.realitykitRendererCurvature) { _, _ in debouncedSave() }
        .onChange(of: viewModel.streamSettings.dimPassthrough) { _, _ in debouncedSaveDimPassthrough() }
        .onDisappear {
            saveTimer?.invalidate()
            saveTimer = nil
            dimPassthroughSaveTimer?.invalidate()
            dimPassthroughSaveTimer = nil
            saveRealityKitSettings()
            viewModel.streamSettings.save()
        }
        .modifier(SpatialSettingsMonitorModifier(height: height, depthOffset: depthOffset, onValueChange: debouncedSave))
    }
    
    // MARK: - Quick Actions Section
    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: viewModel.localized("quick_actions"), icon: "square.grid.2x2")
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                // Home
                ModernActionTile(icon: "house.fill", title: viewModel.localized("home")) {
                    closeAction()
                }
                
                // Dimming
                ModernActionTile(
                    icon: viewModel.streamSettings.dimPassthrough ? "sun.max.fill" : "moon.fill",
                    title: viewModel.streamSettings.dimPassthrough ? viewModel.localized("restore_brightness") : viewModel.localized("toggle_dimming"),
                    isActive: viewModel.streamSettings.dimPassthrough
                ) {
                    withAnimation {
                        viewModel.streamSettings.dimPassthrough.toggle()
                        // Note: onChange will trigger debouncedSaveDimPassthrough()
                    }
                }
                
                // Spatial audio
                ModernActionTile(
                    icon: spatialAudioMode ? "speaker.wave.3.fill" : "headphones",
                    title: spatialAudioMode ? viewModel.localized("spatial_audio") : viewModel.localized("stereo_audio"),
                    isActive: spatialAudioMode
                ) {
                    withAnimation {
                        spatialAudioMode.toggle()
                        if spatialAudioMode {
                            AudioHelpers.fixAudioForSurroundForCurrentWindow()
                        } else {
                            AudioHelpers.fixAudioForDirectStereo()
                        }
                    }
                }
                
                // Keyboard
                if let toggleAction = toggleKeyboardAction {
                    ModernActionTile(
                        icon: "keyboard.fill",
                        title: viewModel.localized("virtual_keyboard"),
                        isActive: isKeyboardActive
                    ) {
                        withAnimation { toggleAction() }
                    }
                }
                
                // UIKit window button (UIKit mode only)
                if let windowAction = windowButtonAction {
                    ModernActionTile(
                        icon: "aspectratio",
                        title: viewModel.localized("lock_aspect_ratio"),
                        isActive: false
                    ) {
                        windowAction()
                    }
                }
            }
        }
    }
    
    // MARK: - Display Settings Section
    private var displaySettingsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: viewModel.localized("display_effects"), icon: "display")
            
            Grid(horizontalSpacing: 16, verticalSpacing: 20) {
                // HDR settings
                if viewModel.streamSettings.enableHdr || needsHdr {
                    SteppedSliderRow(
                        title: viewModel.localized("brightness"),
                        value: $viewModel.streamSettings.brightness,
                        range: 1.0...10.0,
                        defaultValue: 2.2,
                        format: "%.1f",
                        step: 0.01
                    )
                    
                    SteppedSliderRow(
                        title: viewModel.localized("contrast"),
                        value: $viewModel.streamSettings.gamma,
                        range: 0.5...5.0,
                        defaultValue: 1.0,
                        format: "%.2f",
                        step: 0.01
                    )
                    
                    SteppedSliderRow(
                        title: viewModel.localized("saturation"),
                        value: $viewModel.streamSettings.saturation,
                        range: 0.0...4.0,
                        defaultValue: 1.0,
                        format: "%.2f",
                        step: 0.01
                    )
                }
                
                // Screen curvature (RealityKit only)
                if isRealityKit {
                    SteppedSliderRow(
                        title: viewModel.localized("screen_curvature"),
                        value: $viewModel.streamSettings.realitykitRendererCurvature,
                        range: 0...1,
                        defaultValue: 0.0,
                        format: "%.3f",
                        step: 0.01
                    )
                }
            }
            
            // Volume control
            volumeControl
        }
    }
    
    // MARK: - Spatial Settings Section (RealityKit only)
    private var spatialSettingsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: viewModel.localized("spatial_adjustments"), icon: "move.3d")
            
            if let depthOffset = depthOffset, let height = height,
               let zLimits = zLimits, let yLimits = yLimits {
                Grid(horizontalSpacing: 16, verticalSpacing: 20) {
                    SteppedSliderRow(
                        title: viewModel.localized("depth"),
                        value: depthOffset,
                        range: zLimits,
                        defaultValue: 0.0,
                        format: "%.2f",
                        step: 0.01
                    )
                    
                    SteppedSliderRow(
                        title: viewModel.localized("vertical_height"),
                        value: height,
                        range: yLimits,
                        defaultValue: 0.0,
                        format: "%.2f",
                        step: 0.01
                    )
                }
            }
        }
    }
    
    // MARK: - Volume Control
    private var volumeControl: some View {
        VStack(spacing: 12) {
            HStack {
                Label(viewModel.localized("volume"), systemImage: viewModel.mute ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.subheadline)
                    .foregroundStyle(viewModel.mute ? .secondary : .primary)
                    .contentTransition(.symbolEffect(.replace))
                
                Spacer()
                
                Text("\(Int(viewModel.vol))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .onTapGesture { withAnimation { viewModel.mute.toggle() } }
            
            Slider(value: Binding(
                get: { viewModel.vol },
                set: { newValue in
                    viewModel.vol = newValue
                    setVolume(Int32(newValue)) // Real-time update
                }
            ), in: 0...127)
                .tint(.white)
        }
        .padding(16)
        .background(Material.regular)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    
    // MARK: - Helper Methods
    private func debouncedSave() {
        guard viewModel.streamSettings.rememberStreamSettings else { return }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            saveRealityKitSettings()
        }
    }
    
    // Debounce save for dimPassthrough: delay 0.5 seconds to avoid frequent writes
    private func debouncedSaveDimPassthrough() {
        dimPassthroughSaveTimer?.invalidate()
        dimPassthroughSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            viewModel.streamSettings.save()
        }
    }
    
    private func saveRealityKitSettings() {
        guard viewModel.streamSettings.rememberStreamSettings else { return }
        let defaults = UserDefaults.standard
        defaults.set(viewModel.streamSettings.gamma, forKey: "realitykitGamma")
        defaults.set(viewModel.streamSettings.saturation, forKey: "realitykitSaturation")
        if let height = height {
            defaults.set(height.wrappedValue, forKey: "realitykitHeight")
        }
        if let depthOffset = depthOffset {
            defaults.set(depthOffset.wrappedValue, forKey: "realitykitDepthOffset")
        }
    }
}

// Helper modifier to monitor optional Binding values
private struct SpatialSettingsMonitorModifier: ViewModifier {
    let height: Binding<Float>?
    let depthOffset: Binding<Float>?
    let onValueChange: () -> Void
    
    func body(content: Content) -> some View {
        content
            .background {
                Group {
                    if let height = height {
                        Color.clear.onChange(of: height.wrappedValue) { _, _ in onValueChange() }
                    }
                    if let depthOffset = depthOffset {
                        Color.clear.onChange(of: depthOffset.wrappedValue) { _, _ in onValueChange() }
                    }
                }
            }
    }
}


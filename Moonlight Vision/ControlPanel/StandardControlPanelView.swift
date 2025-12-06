//
//  StandardControlPanelView.swift
//  Moonlight Vision
//
//  Standard mode (non-immersive) control panel - uses the same design style as immersive control panel
//  Created by Linggan-ua on 2025/12/03.

import SwiftUI

/// Standard mode control panel view
struct StandardControlPanelView: View {
    @EnvironmentObject private var viewModel: MainViewModel
    
    let closeAction: () -> Void
    let toggleKeyboardAction: (() -> Void)?
    let isKeyboardActive: Bool
    
    // RealityKit spatial adjustment parameters (optional, only for RealityKit non-immersive mode)
    var depthOffset: Binding<Float>? = nil
    var height: Binding<Float>? = nil
    var zLimits: ClosedRange<Float>? = nil
    var yLimits: ClosedRange<Float>? = nil
    var needsHdr: Bool = false
    var isRealityKit: Bool = false
    
    // UIKit window button (optional, only for UIKit mode)
    var windowButtonAction: (() -> Void)? = nil
    
    // Spatial audio mode state
    @State private var spatialAudioMode: Bool = true
    
    // Expand/collapse state
    @State private var isExpanded: Bool = false
    
    // Debounce timer for settings save
    @State private var saveTimer: Timer?
    @State private var dimPassthroughSaveTimer: Timer?
    
    var body: some View {
        ZStack {
            if !isExpanded {
                collapsedButton
                    .transition(.opacity.animation(.linear(duration: 0)))
                    .zIndex(0)
            }
            
            if isExpanded {
                expandedPanel
                    .transition(.scale.combined(with: .opacity).animation(.spring(response: 0.3, dampingFraction: 0.8)))
                    .zIndex(1)
            }
        }
    }
    
    // MARK: - Collapsed Button
    private var collapsedButton: some View {
        Button(action: {
            // Immediately hide button without animation
            isExpanded = true
        }) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(viewModel.localized("control_panel"))
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Material.regular)
            .clipShape(Capsule())
            .glassBackgroundEffect()
        }
        .buttonStyle(.plain)
        .hoverEffect { effect, isActive, _ in
            effect.opacity(isActive ? 1.0 : 0.05)
        }
    }
    
    // MARK: - Expanded Panel
    private var expandedPanel: some View {
        let content = Group {
            if isRealityKit {
                // RealityKit mode: vertical layout
                realityKitPanel
            } else {
                // UIKit mode: horizontal layout
                uiKitPanel
            }
        }
        
        return content
            .onChange(of: viewModel.streamSettings.brightness) { _, _ in if isRealityKit { debouncedSave() } }
            .onChange(of: viewModel.streamSettings.gamma) { _, _ in if isRealityKit { debouncedSave() } }
            .onChange(of: viewModel.streamSettings.saturation) { _, _ in if isRealityKit { debouncedSave() } }
            .onChange(of: viewModel.streamSettings.realitykitRendererCurvature) { _, _ in if isRealityKit { debouncedSave() } }
            .onChange(of: viewModel.streamSettings.dimPassthrough) { _, _ in debouncedSaveDimPassthrough() }
            .onDisappear {
                saveTimer?.invalidate()
                saveTimer = nil
                dimPassthroughSaveTimer?.invalidate()
                dimPassthroughSaveTimer = nil
                if isRealityKit {
                    saveRealityKitSettings()
                }
                viewModel.streamSettings.save()
            }
            .modifier(SpatialSettingsMonitorModifier(height: height, depthOffset: depthOffset, isRealityKit: isRealityKit, onValueChange: debouncedSave))
    }
    
    // MARK: - UIKit Panel (Horizontal Layout)
    private var uiKitPanel: some View {
        HStack(spacing: 20) {
            // Quick action buttons (horizontal arrangement, square)
            HStack(spacing: 12) {
                // Home
                ModernActionTile(icon: "house.fill", title: viewModel.localized("home")) {
                    closeAction()
                }
                .frame(width: 80, height: 80)
                
                // Dimming
                ModernActionTile(
                    icon: viewModel.streamSettings.dimPassthrough ? "sun.max.fill" : "moon.fill",
                    title: viewModel.streamSettings.dimPassthrough ? 
                        (viewModel.currentLanguage == .english ? viewModel.localized("restore_brightness_short") : viewModel.localized("restore_brightness")) :
                        (viewModel.currentLanguage == .english ? viewModel.localized("toggle_dimming_short") : viewModel.localized("toggle_dimming")),
                    isActive: viewModel.streamSettings.dimPassthrough
                ) {
                    withAnimation {
                        viewModel.streamSettings.dimPassthrough.toggle()
                        // Note: onChange will trigger debouncedSaveDimPassthrough()
                    }
                }
                .frame(width: 80, height: 80)
                
                // Spatial audio
                ModernActionTile(
                    icon: spatialAudioMode ? "speaker.wave.3.fill" : "headphones",
                    title: spatialAudioMode ? 
                        (viewModel.currentLanguage == .english ? viewModel.localized("spatial_audio_short") : viewModel.localized("spatial_audio")) :
                        (viewModel.currentLanguage == .english ? viewModel.localized("stereo_audio_short") : viewModel.localized("stereo_audio")),
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
                .frame(width: 80, height: 80)
                
                // Keyboard
                if let toggleAction = toggleKeyboardAction {
                    ModernActionTile(
                        icon: "keyboard.fill",
                        title: viewModel.currentLanguage == .english ? viewModel.localized("virtual_keyboard_short") : viewModel.localized("virtual_keyboard"),
                        isActive: isKeyboardActive
                    ) {
                        withAnimation { toggleAction() }
                    }
                    .frame(width: 80, height: 80)
                }
                
                // UIKit window button
                if let windowAction = windowButtonAction {
                    ModernActionTile(
                        icon: "aspectratio",
                        title: viewModel.currentLanguage == .english ? viewModel.localized("lock_aspect_ratio_short") : viewModel.localized("lock_aspect_ratio"),
                        isActive: false
                    ) {
                        windowAction()
                    }
                    .frame(width: 80, height: 80)
                }
            }
            
            Divider()
                .frame(height: 40)
            
            // Volume control (compact horizontal version)
            compactVolumeControl
            
            // Close button
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded = false
                }
            }) {
                Image(systemName: "chevron.down")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Material.regular)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.lift)
        }
        .padding(20)
        .glassBackgroundEffect()
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
    
    // MARK: - RealityKit Panel (Vertical Layout)
    private var realityKitPanel: some View {
        VStack(spacing: 0) {
            // Quick actions section (with close button)
            VStack(alignment: .leading, spacing: 16) {
                // Title bar (with close button)
                HStack {
                    SectionHeader(title: viewModel.localized("quick_actions"), icon: "square.grid.2x2")
                    Spacer()
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isExpanded = false
                        }
                    }) {
                        Image(systemName: "chevron.down")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .background(Material.regular)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.lift)
                }
            
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
                }
                
                // Volume control (moved from display settings)
                volumeControl
            }
            
            Divider()
                .padding(.vertical, 16)
            
            displaySettingsSection
            
            // Spatial adjustments (only for RealityKit non-immersive mode)
            if depthOffset != nil && height != nil {
                Divider()
                    .padding(.vertical, 16)
                
                spatialSettingsSection
            }
        }
        .padding(24)
        .frame(width: 500)
        .glassBackgroundEffect()
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
    
    
    // MARK: - Display Settings Section (RealityKit only)
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
                        defaultValue: 4.0,
                        format: "%.1f",
                        step: 0.01
                    )
                    
                    SteppedSliderRow(
                        title: viewModel.localized("contrast"),
                        value: $viewModel.streamSettings.gamma,
                        range: 0.5...5.0,
                        defaultValue: 2.0,
                        format: "%.2f",
                        step: 0.01
                    )
                    
                    SteppedSliderRow(
                        title: viewModel.localized("saturation"),
                        value: $viewModel.streamSettings.saturation,
                        range: 0.0...4.0,
                        defaultValue: 1.70,
                        format: "%.2f",
                        step: 0.01
                    )
                }
                
                // Screen curvature (RealityKit only)
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
    
    // MARK: - Compact Volume Control (for horizontal layout)
    private var compactVolumeControl: some View {
        HStack(spacing: 12) {
            Button(action: { withAnimation { viewModel.mute.toggle() } }) {
                Image(systemName: viewModel.mute ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.subheadline)
                    .foregroundStyle(viewModel.mute ? .secondary : .primary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            
            Slider(value: Binding(
                get: { viewModel.vol },
                set: { newValue in
                    viewModel.vol = newValue
                    setVolume(Int32(newValue)) // Real-time update
                }
            ), in: 0...127)
                .frame(width: 150)
                .tint(.white)
        }
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
    let isRealityKit: Bool
    let onValueChange: () -> Void
    
    func body(content: Content) -> some View {
        content
            .background {
                Group {
                    if isRealityKit {
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
}



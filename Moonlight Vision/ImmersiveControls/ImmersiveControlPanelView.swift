//
//  ImmersiveControlPanelView.swift
//  Moonlight Vision
//
//  Fixed position control panel - as RealityKit Attachment
//  Created by Linggan-ua on 2025/12/03.
//

import SwiftUI
import RealityKit

/// Immersive control panel view - used as Attachment
struct ImmersiveControlPanelView: View {
    @EnvironmentObject private var viewModel: MainViewModel
    @EnvironmentObject private var controlState: StreamControlState
    
    // Debounce timer for settings save
    @State private var saveTimer: Timer?
    
    // Spatial audio mode state
    @State private var spatialAudioMode: Bool = true
    
    // Check if HDR is enabled
    private var isHdrEnabled: Bool {
        controlState.needsHdr || viewModel.streamSettings.enableHdr
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left: Environment and quick actions
            leftSection
                .frame(width: 420)
                .padding(40)
            
            Divider()
                .padding(.vertical, 40)
            
            if isHdrEnabled {
                // Three-column layout when HDR is enabled
                // Center: Display settings
                centerSection
                    .frame(width: 480)
                    .padding(40)
                
                Divider()
                    .padding(.vertical, 40)
                
                // Right: Spatial settings
                rightSection
                    .frame(width: 480)
                    .padding(40)
            } else {
                // Two-column layout when HDR is disabled
                // Center: Display settings + Spatial settings
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
        .frame(width: isHdrEnabled ? 1600 : 1100, height: 650) // Adjust width based on HDR state
        .glassBackgroundEffect()
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
        .onChange(of: viewModel.streamSettings.brightness) { _, _ in debouncedSave() }
        .onChange(of: viewModel.streamSettings.gamma) { _, _ in debouncedSave() }
        .onChange(of: viewModel.streamSettings.saturation) { _, _ in debouncedSave() }
        .onChange(of: viewModel.streamSettings.realitykitRendererCurvature) { _, _ in debouncedSave() }
        .onChange(of: viewModel.streamSettings.dimPassthrough) { _, _ in debouncedSaveDimPassthrough() }
        .onChange(of: controlState.immersiveScale) { _, _ in debouncedSave() }
        .onChange(of: controlState.immersivePositionX) { _, _ in debouncedSave() }
        .onChange(of: controlState.immersivePositionY) { _, _ in debouncedSave() }
        .onChange(of: controlState.immersivePositionZ) { _, _ in debouncedSave() }
        .onChange(of: controlState.immersionAmount) { _, _ in debouncedSave() }
        .onChange(of: controlState.pinnedStageScale) { _, _ in debouncedSave() }
        .onChange(of: controlState.pinnedStageHeight) { _, _ in debouncedSave() }
        .onDisappear {
            // Save immediately when view disappears
            saveTimer?.invalidate()
            saveTimer = nil
            dimPassthroughSaveTimer?.invalidate()
            dimPassthroughSaveTimer = nil
            controlState.saveSettings?()
            viewModel.streamSettings.save()
        }
    }
    
    // Debounce save: delay 0.5 seconds to avoid frequent writes
    private func debouncedSave() {
        guard viewModel.streamSettings.rememberStreamSettings else { return }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            controlState.saveSettings?()
        }
    }
    
    // Debounce save for dimPassthrough: delay 0.5 seconds to avoid frequent writes
    @State private var dimPassthroughSaveTimer: Timer?
    private func debouncedSaveDimPassthrough() {
        dimPassthroughSaveTimer?.invalidate()
        dimPassthroughSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            viewModel.streamSettings.save()
        }
    }
    
    // MARK: - Left Section (Environment + Quick Actions)
    private var leftSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            // Environment selection
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: viewModel.localized("environment"), icon: "globe")
                
                Picker("", selection: $controlState.selectedEnvironmentState) {
                    Text(viewModel.localized("passthrough")).tag(EnvironmentStateType.none)
                    Text(viewModel.localized("light")).tag(EnvironmentStateType.light)
                    Text(viewModel.localized("dark")).tag(EnvironmentStateType.dark)
                }
                .pickerStyle(.segmented)
                .disabled(controlState.isUpdatingImmersion)
                .onChange(of: controlState.selectedEnvironmentState) { _, newValue in
                    controlState.onEnvironmentChange?(newValue)
                }
                
                // Semi-immersion toggle
                if controlState.selectedEnvironmentState != .none {
                    Toggle(isOn: Binding(
                        get: { controlState.isSemiImmersionEnabled },
                        set: { controlState.onSemiImmersionToggle?($0) }
                    )) {
                        Label(viewModel.localized("semi_immersion_mode"), systemImage: "dial.medium")
                            .font(.subheadline)
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(controlState.isUpdatingImmersion)
                }
            }
            
            // Quick actions
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: viewModel.localized("quick_actions"), icon: "square.grid.2x2")
                
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    // Home
                    ModernActionTile(icon: "house.fill", title: viewModel.localized("home")) {
                        controlState.closeAction?()
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
                                // Switch to spatial audio (sound from screen)
                                AudioHelpers.fixAudioForSurroundForCurrentWindow()
                            } else {
                                // Switch to direct audio (sound from ears)
                                AudioHelpers.fixAudioForDirectStereo()
                            }
                        }
                    }
                    
                    // Keyboard
                    ModernActionTile(
                        icon: "keyboard.fill",
                        title: viewModel.localized("virtual_keyboard"),
                        isActive: controlState.isKeyboardActive
                    ) {
                        withAnimation { controlState.toggleKeyboardAction?() }
                    }
                    
                    // 3D
                    ModernActionTile(
                        icon: "cube.transparent.fill",
                        title: viewModel.localized("3d_mode"),
                        isActive: controlState.videoMode == .sideBySide3D
                    ) {
                        withAnimation { controlState.toggle3DMode?() }
                    }
                    
                    // Gamepad Home Button
                    ModernActionTile(
                        icon: "gamecontroller.fill",
                        title: viewModel.localized("gamepad_home"),
                        isActive: false
                    ) {
                        sendGamepadHomeButton()
                    }
                }
                
                // Volume control (moved from display settings)
                volumeControl
            }
        }
    }
    
    // MARK: - Center Section (Display Settings)
    private var centerSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            SectionHeader(title: viewModel.localized("display_effects"), icon: "display")
            
            // Use Grid to align sliders
            Grid(horizontalSpacing: 20, verticalSpacing: 24) {
                // HDR group
                if controlState.needsHdr || viewModel.streamSettings.enableHdr {
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
                
                // Curvature
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
    
    // MARK: - Right Section (Spatial Settings)
    private var rightSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            SectionHeader(title: viewModel.localized("spatial_adjustments"), icon: "move.3d")
            
            // Lock and pin
            if controlState.selectedEnvironmentState == .none {
                // Passthrough mode: Lock button centered and full width
                HStack {
                    ModernActionTile(
                        icon: controlState.isInteractive ? "lock.fill" : "lock.open.fill",
                        title: controlState.isInteractive ? viewModel.localized("locked") : viewModel.localized("lock_position"),
                        isActive: controlState.isInteractive,
                        disabled: controlState.isPinnedToStage
                    ) {
                        withAnimation { controlState.isInteractive.toggle() }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 88)
            } else {
                // Virtual environment: Lock button on left, Pin button on right
                HStack(spacing: 12) {
                    ModernActionTile(
                        icon: controlState.isInteractive ? "lock.fill" : "lock.open.fill",
                        title: controlState.isInteractive ? viewModel.localized("locked") : viewModel.localized("lock_position"),
                        isActive: controlState.isInteractive,
                        disabled: controlState.isPinnedToStage
                    ) {
                        withAnimation { controlState.isInteractive.toggle() }
                    }
                    
                    ModernActionTile(
                        icon: controlState.isPinnedToStage ? "pin.slash.fill" : "pin.fill",
                        title: controlState.isPinnedToStage ? viewModel.localized("unpin_studio") : viewModel.localized("pin_studio"),
                        isActive: controlState.isPinnedToStage,
                        disabled: controlState.isPinningTransitioning || !controlState.canPinToStage
                    ) {
                        withAnimation { controlState.onPinToggle?() }
                    }
                }
                .frame(height: 88)
            }
            
            Grid(horizontalSpacing: 20, verticalSpacing: 24) {
                // Passthrough environment brightness - only shown in passthrough mode
                if controlState.selectedEnvironmentState == .none {
                    SteppedSliderRow(
                        title: viewModel.localized("passthrough_environment_brightness"),
                        value: $controlState.immersionAmount,
                        range: 0.0...1.0,
                        defaultValue: 0.0,
                        format: "%.0f%%",
                        multiplier: 100,
                        step: 0.01
                    )
                }
                
                // Pinned screen size and height - only shown when pinned and animation completes (avoid animation stutter)
                if controlState.isPinnedToStage && !controlState.isPinningTransitioning {
                    SteppedSliderRow(
                        title: viewModel.localized("pinned_screen_size"),
                        value: $controlState.pinnedStageScale,
                        range: 0.3...5.21,
                        defaultValue: 5.0,
                        format: "%.2fx",
                        step: 0.01
                    )
                    SteppedSliderRow(
                        title: viewModel.localized("pinned_screen_height"),
                        value: $controlState.pinnedStageHeight,
                        range: -2.0...3.0,
                        defaultValue: 0.75,
                        format: "%.2fm",
                        step: 0.01
                    )
                }
                
                SteppedSliderRow(
                    title: viewModel.localized("screen_scale"),
                    value: $controlState.immersiveScale,
                    range: 0.05...5.0,
                    defaultValue: 1.0,
                    format: "%.2fx",
                    disabled: controlState.isPinnedToStage,
                    step: 0.01
                )
                
                SteppedSliderRow(
                    title: viewModel.localized("viewing_distance"),
                    value: Binding(
                        get: { -controlState.immersivePositionZ },
                        set: { controlState.immersivePositionZ = -$0 }
                    ),
                    range: 1.5...10.5,
                    defaultValue: 1.5,
                    format: "%.2fm",
                    disabled: controlState.isPinnedToStage,
                    step: 0.01
                )
                
                SteppedSliderRow(
                    title: viewModel.localized("vertical_height"),
                    value: $controlState.immersivePositionY,
                    range: 0.0...8.0,
                    defaultValue: 1.0,
                    format: "%.2fm",
                    disabled: controlState.isPinnedToStage,
                    step: 0.01
                )
            }
        }
    }
    
    // MARK: - Helper Methods
    private func sendGamepadHomeButton() {
        // Send Xbox Home/Guide button (SPECIAL_FLAG = 0x0400)
        if let controller = controlState.controllerSupport?.getOscController() {
            controlState.controllerSupport?.setButtonFlag(controller, flags: 0x0400)
            controlState.controllerSupport?.updateFinished(controller)
            // Release the button after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                controlState.controllerSupport?.clearButtonFlag(controller, flags: 0x0400)
                controlState.controllerSupport?.updateFinished(controller)
            }
        }
    }
    
    // MARK: - Volume Control
    private var volumeControl: some View {
        VStack(spacing: 16) {
            HStack {
                Label(viewModel.localized("volume"), systemImage: viewModel.mute ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.headline)
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
        .padding(20)
        .background(Material.regular)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - Helper Views

/// Unified section header
struct SectionHeader: View {
    let title: String
    let icon: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
            Text(title)
                .font(.headline)
        }
        .foregroundStyle(.secondary)
    }
}

/// Modern style action tile (inspired by Control Center)
struct ModernActionTile: View {
    let icon: String
    let title: String
    var isActive: Bool = false
    var disabled: Bool = false
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(isActive ? Color.black : Color.primary)
                    .contentTransition(.symbolEffect(.replace))
                
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(isActive ? Color.black.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(isActive ? Color.white : Color.black.opacity(0.2))
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1.0)
        .hoverEffect(.lift)
    }
}

/// Stepped slider row (supports fine adjustment and restore default, inspired by ALVR implementation)
struct SteppedSliderRow: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let defaultValue: Float
    let format: String
    var multiplier: Float = 1
    var disabled: Bool = false
    let step: Float
    
    var body: some View {
        GridRow {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
                .padding(.trailing, 8)
            
            HStack(spacing: 8) {
                Slider(value: $value, in: range, step: step)
                    .disabled(disabled)
                    .tint(.white)
                
                // Restore default value button
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        value = defaultValue
                    }
                    // Note: Setting value will trigger onChange, which calls debouncedSave
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .disabled(disabled || abs(value - defaultValue) < step * 0.5)
                .opacity((disabled || abs(value - defaultValue) < step * 0.5) ? 0.3 : 1.0)
            }
            
            Text(String(format: format, value * multiplier))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
                .frame(width: 60, alignment: .trailing)
        }
        .opacity(disabled ? 0.5 : 1.0)
    }
}

#Preview {
    ImmersiveControlPanelView()
        .environmentObject(MainViewModel())
        .environmentObject(StreamControlState.shared)
}

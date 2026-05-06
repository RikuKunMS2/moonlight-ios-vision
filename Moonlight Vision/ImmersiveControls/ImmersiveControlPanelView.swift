//
//  ImmersiveControlPanelView.swift
//  Moonlight Vision
//
//  Created by Linggan-ua on 2025/12/03.
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Fixed position control panel - as RealityKit Attachment
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI
import RealityKit

/// Immersive control panel view - used as Attachment
struct ImmersiveControlPanelView: View {
    @EnvironmentObject private var viewModel: MainViewModel
    @EnvironmentObject private var controlState: StreamControlState
    
    @Binding var inputMode: InputMode
    
    // Debounce timer for settings save
    @State private var saveTimer: Timer?
    
    // Spatial audio mode state is now in viewModel.streamSettings.spatialAudioMode
    
    // Delay pinned sliders ~1.5s after pin completes to avoid animation stutter
    @State private var showPinnedSliders = false
    @State private var pinnedSlidersDelayTask: Task<Void, Never>?
    
    // Check if HDR is enabled
    private var isHdrEnabled: Bool {
        controlState.needsHdr || viewModel.streamSettings.enableHdr
    }
    
    private var mainContent: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                leftSection
                    .frame(width: 420)
                    .padding(40)
                
                Divider()
                    .padding(.vertical, 40)
                
                mainCenterColumn
            }
            
            if !controlState.isPinnedToStage {
                Divider()
                    .padding(.horizontal, 40)
                
                bottomSection
                    .padding(40)
            }
        }
    }
    
    @ViewBuilder
    private var mainCenterColumn: some View {
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
    private var styledContent: some View {
        mainContent
            .frame(width: isHdrEnabled ? 1600 : 1100, height: controlState.isPinnedToStage ? (showPinnedSliders ? 730 : 650) : 1050)
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
    }

    var body: some View {
        styledContent
            .modifier(ImmersivePanelSaveModifier(
                viewModel: viewModel,
                controlState: controlState,
                debouncedSave: debouncedSave,
                debouncedSaveDimPassthrough: debouncedSaveDimPassthrough
            ))
            .modifier(ImmersivePanelPinnedModifier(
                controlState: controlState,
                handlePinnedChange: handlePinnedChange,
                handlePinningTransitioningChange: handlePinningTransitioningChange,
                handleDisappear: handleDisappear
            ))
            .onAppear {
                if controlState.isPinnedToStage && !controlState.isPinningTransitioning {
                    showPinnedSliders = true
                }
            }
    }

    private func handlePinnedChange(_ isPinned: Bool) {
        if !isPinned { showPinnedSliders = false; pinnedSlidersDelayTask?.cancel() }
    }

    private func handlePinningTransitioningChange(_ transitioning: Bool) {
        if !transitioning && controlState.isPinnedToStage {
            pinnedSlidersDelayTask?.cancel()
            pinnedSlidersDelayTask = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.25)) { showPinnedSliders = true }
                }
            }
        } else if transitioning {
            showPinnedSliders = false
            pinnedSlidersDelayTask?.cancel()
        }
    }

    private func handleDisappear() {
        saveTimer?.invalidate()
        saveTimer = nil
        dimPassthroughSaveTimer?.invalidate()
        dimPassthroughSaveTimer = nil
        controlState.saveSettings?()
        viewModel.streamSettings.save()
    }
    
    // Debounce save: delay 0.5 seconds to avoid frequent writes
    private func debouncedSave() {
        guard viewModel.streamSettings.rememberStreamSettings else { return }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            controlState.saveSettings?()
            SharePlayManager.shared.broadcastCurrentTransform()
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
                
                }
            
            // Quick actions
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: viewModel.localized("quick_actions"), icon: "square.grid.2x2")
                
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    // Home: push main overlay; Stop is on main menu
                    ModernActionTile(icon: "house.fill", title: viewModel.localized("home")) {
                        (controlState.homeAction ?? controlState.closeAction)?()
                    }
                    
                    // Dimming
                    ModernActionTile(
                        icon: controlState.dimLevel == 0 ? "moon.fill" : "sun.max.fill",
                        title: viewModel.localized("toggle_dimming") + " (\(controlState.dimLevel == 0 ? "Off" : "\(controlState.dimLevel * 25)%"))",
                        isActive: controlState.dimLevel != 0
                    ) {
                        withAnimation {
                            var nextLevel = controlState.dimLevel + 1
                            if nextLevel > 4 { nextLevel = 0 }
                            controlState.dimLevel = nextLevel
                            viewModel.streamSettings.dimPassthrough = (nextLevel != 0)
                            viewModel.streamSettings.save()
                        }
                    }
                    
                    // Input Mode Menu
                    Menu {
                        Button(action: { inputMode = .gazeControl }) { Label("Gaze Control", systemImage: "eye") }
                        Button(action: { inputMode = .controller; viewModel.streamSettings.fpsMouseCapture = false; viewModel.streamSettings.save() }) { Label("Absolute Mouse", systemImage: "cursorarrow") }
                        Button(action: { inputMode = .controller; viewModel.streamSettings.fpsMouseCapture = true; viewModel.streamSettings.save() }) { Label("FPS Locked Mouse", systemImage: "cursorarrow.and.square.on.square.dashed") }
                        Button(action: { inputMode = .screenMove }) { Label("Screen Adjust", systemImage: "arrow.up.and.down.and.arrow.left.and.right") }
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: inputMode == .gazeControl ? "eye" : (inputMode == .screenMove ? "arrow.up.and.down.and.arrow.left.and.right" : (viewModel.streamSettings.fpsMouseCapture ? "cursorarrow.and.square.on.square.dashed" : "cursorarrow")))
                                .font(.system(size: 24))
                                .foregroundStyle(Color.black)
                            
                            Text(inputMode == .gazeControl ? "Gaze Mode" : (inputMode == .screenMove ? "Screen Adjust" : (viewModel.streamSettings.fpsMouseCapture ? "FPS Mouse" : "Absolute Mouse")))
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
                    
                    // Audio Quality Mode
                    let mixedMode = controlState.preferUninterruptedAudio
                    ModernActionTile(
                        icon: mixedMode ? "exclamationmark.triangle" : "waveform",
                        title: mixedMode ? "Audio: Mixed Mode" : "Audio: High Quality",
                        isActive: mixedMode
                    ) {
                        withAnimation {
                            controlState.preferUninterruptedAudio.toggle()
                            UserDefaults.standard.set(controlState.preferUninterruptedAudio, forKey: "preferUninterruptedAudio")
                            
                            // Re-apply spatial audio to trigger the change
                            let currentMode = SpatialAudioMode(rawValue: viewModel.streamSettings.spatialAudioMode) ?? .window
                            AudioHelpers.applySpatialAudioMode(currentMode)
                        }
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
                    
                    // Stats Overlay
                    ModernActionTile(
                        icon: viewModel.streamSettings.statsOverlay ? "chart.bar.fill" : "chart.bar",
                        title: viewModel.localized("stats_overlay"),
                        isActive: viewModel.streamSettings.statsOverlay
                    ) {
                        withAnimation { viewModel.streamSettings.statsOverlay.toggle() }
                    }
                    
                    // SharePlay
                    ModernActionTile(
                        icon: "shareplay",
                        title: "SharePlay",
                        isActive: false
                    ) {
                        SharePlayManager.shared.startSharePlay()
                    }
                    
                    // Reactive Lighting
                    ModernActionTile(
                        icon: viewModel.streamSettings.reactiveLightingEnabled ? "wand.and.rays" : "wand.and.rays.inverse",
                        title: viewModel.localized("reactive_lighting"),
                        isActive: viewModel.streamSettings.reactiveLightingEnabled
                    ) {
                        withAnimation {
                            viewModel.streamSettings.reactiveLightingEnabled.toggle()
                            viewModel.streamSettings.save()
                        }
                    }
                    
                    // Mac Virtual Display
                    ModernActionTile(
                        icon: "macbook.and.visionpro",
                        title: "Mac Virtual Display",
                        isActive: viewModel.streamSettings.macVirtualDisplayExperimental
                    ) {
                        withAnimation {
                            viewModel.streamSettings.macVirtualDisplayExperimental.toggle()
                            viewModel.streamSettings.save()
                        }
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
                if controlState.needsHdr || viewModel.streamSettings.enableHdr {
                    SteppedSliderRow(
                        title: viewModel.localized("brightness"),
                        value: $viewModel.streamSettings.brightness,
                        range: -10.0...10.0,
                        defaultValue: 1.0,
                        format: "%.2f",
                        step: 0.01
                    )
                    
                    SteppedSliderRow(
                        title: viewModel.localized("contrast"),
                        value: $viewModel.streamSettings.gamma,
                        range: -10.0...10.0,
                        defaultValue: 1.0,
                        format: "%.2f",
                        step: 0.01
                    )
                    
                    SteppedSliderRow(
                        title: viewModel.localized("saturation"),
                        value: $viewModel.streamSettings.saturation,
                        range: -10.0...10.0,
                        defaultValue: 1.0,
                        format: "%.2f",
                        step: 0.01
                    )
                    
                    SteppedSliderRow(
                        title: viewModel.localized("pq_hdr_exposure"),
                        value: $viewModel.streamSettings.pqExposure,
                        range: 0.25...2.5,
                        defaultValue: 1.0,
                        format: "%.2f",
                        step: 0.01
                    )
                    
                    GridRow {
                        Text(viewModel.localized("hdr_calibration_mode"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                            .padding(.trailing, 8)
                        
                        HStack {
                            Toggle("", isOn: $controlState.isCalibrationModeActive)
                                .labelsHidden()
                                .tint(.white)
                            Spacer()
                        }
                        
                        Color.clear
                            .frame(width: 60)
                    }
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
                
                // Screen corner radius
                SteppedSliderRow(
                    title: viewModel.localized("screen_corner_radius"),
                    value: $viewModel.streamSettings.realitykitScreenCornerRadius,
                    range: 0...0.05,
                    defaultValue: 0.018,
                    format: "%.3f",
                    step: 0.001
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
                // Passthrough mode: lock + auto pitch follow
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
                        icon: viewModel.streamSettings.realitykitAutoPitchFollow ? "gyroscope.circle.fill" : "gyroscope",
                        title: viewModel.localized("auto_pitch_follow"),
                        isActive: viewModel.streamSettings.realitykitAutoPitchFollow,
                        disabled: controlState.isPinnedToStage
                    ) {
                        toggleAutoPitchFollow()
                    }
                }
                .frame(height: 88)
            } else {
                // Virtual environment: lock + auto pitch + pin
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
                        icon: viewModel.streamSettings.realitykitAutoPitchFollow ? "gyroscope.circle.fill" : "gyroscope",
                        title: viewModel.localized("auto_pitch_follow"),
                        isActive: viewModel.streamSettings.realitykitAutoPitchFollow,
                        disabled: controlState.isPinnedToStage
                    ) {
                        toggleAutoPitchFollow()
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
                
                // Pinned screen size and height - delayed ~1.5s after pin completes to avoid animation stutter
                if controlState.isPinnedToStage && !controlState.isPinningTransitioning && showPinnedSliders {
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
                // Removed VelocitySliders from rightSection; they are now in bottomSection
            }
        }
    }
    
    // MARK: - Bottom Section (Spatial Controls)
    private var bottomSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: "Spatial Adjustments", icon: "arrow.up.and.down.and.arrow.left.and.right")
            HStack(alignment: .top, spacing: 60) {
                Grid(horizontalSpacing: 20, verticalSpacing: 24) {
                    SteppedSliderRow(
                        title: viewModel.localized("viewing_distance"),
                        value: Binding(
                            get: { -controlState.immersivePositionZ },
                            set: { controlState.immersivePositionZ = -$0 }
                        ),
                        range: 0.5...5.0,
                        defaultValue: 2.0,
                        format: "%.2fm",
                        step: 0.01
                    )
                    
                    SteppedSliderRow(
                        title: viewModel.localized("screen_scale"),
                        value: $controlState.immersiveScale,
                        range: 0.05...5.0,
                        defaultValue: 0.8,
                        format: "%.2fx",
                        step: 0.01
                    )
                }
                
                Grid(horizontalSpacing: 20, verticalSpacing: 24) {
                    SteppedSliderRow(
                        title: viewModel.localized("vertical_height"),
                        value: $controlState.immersivePositionY,
                        range: -2.0...3.0,
                        defaultValue: 1.0,
                        format: "%.2fm",
                        step: 0.01
                    )
                    if !viewModel.streamSettings.realitykitAutoPitchFollow {
                        SteppedSliderRow(
                            title: viewModel.localized("screen_tilt"),
                            value: $controlState.tiltAngle,
                            range: -60.0...60.0,
                            defaultValue: 0.0,
                            format: "%.0f°",
                            disabled: controlState.isPinnedToStage,
                            step: 1.0
                        )
                    }
                }
            }
        }
    }

    private func toggleAutoPitchFollow() {
        withAnimation {
            viewModel.streamSettings.realitykitAutoPitchFollow.toggle()
            if viewModel.streamSettings.realitykitAutoPitchFollow {
                controlState.tiltAngle = 0.0
            }
        }
        debouncedSave()
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

// MARK: - Immersive Panel Change Modifiers (split to avoid compiler type-check timeout)

private struct ImmersivePanelSaveModifier: ViewModifier {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var controlState: StreamControlState
    let debouncedSave: () -> Void
    let debouncedSaveDimPassthrough: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: viewModel.streamSettings.brightness) { _, _ in debouncedSave() }
            .onChange(of: viewModel.streamSettings.gamma) { _, _ in debouncedSave() }
            .onChange(of: viewModel.streamSettings.saturation) { _, _ in debouncedSave() }
            .onChange(of: viewModel.streamSettings.pqExposure) { _, _ in debouncedSave() }
            .onChange(of: viewModel.streamSettings.realitykitRendererCurvature) { _, _ in debouncedSave() }
            .onChange(of: viewModel.streamSettings.realitykitAutoPitchFollow) { _, _ in debouncedSave() }
            .onChange(of: viewModel.streamSettings.realitykitScreenCornerRadius) { _, _ in debouncedSave() }
            .onChange(of: viewModel.streamSettings.dimPassthrough) { _, _ in debouncedSaveDimPassthrough() }
            .onChange(of: controlState.immersiveScale) { _, _ in debouncedSave() }
            .onChange(of: controlState.immersivePositionX) { _, _ in debouncedSave() }
            .onChange(of: controlState.immersivePositionY) { _, _ in debouncedSave() }
            .onChange(of: controlState.immersivePositionZ) { _, _ in debouncedSave() }
            .onChange(of: controlState.immersionAmount) { _, _ in debouncedSave() }
            .onChange(of: controlState.pinnedStageScale) { _, _ in debouncedSave() }
            .onChange(of: controlState.pinnedStageHeight) { _, _ in debouncedSave() }
            .onChange(of: controlState.isInteractive) { _, _ in debouncedSave() }
    }
}

private struct ImmersivePanelPinnedModifier: ViewModifier {
    @ObservedObject var controlState: StreamControlState
    let handlePinnedChange: (Bool) -> Void
    let handlePinningTransitioningChange: (Bool) -> Void
    let handleDisappear: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: controlState.isPinnedToStage) { _, newValue in handlePinnedChange(newValue) }
            .onChange(of: controlState.isPinningTransitioning) { _, newValue in handlePinningTransitioningChange(newValue) }
            .onDisappear(perform: handleDisappear)
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
    /// When true, keep uniform style (no white background when active), only content changes
    var keepUniformStyle: Bool = false
    let action: () -> Void
    
    private var effectiveIconColor: Color {
        keepUniformStyle ? Color.primary : (isActive ? Color.black : Color.primary)
    }
    
    private var effectiveTextColor: Color {
        keepUniformStyle ? Color.secondary : (isActive ? Color.black.opacity(0.8) : Color.secondary)
    }
    
    private var effectiveBackground: Color {
        keepUniformStyle ? Color.black.opacity(0.2) : (isActive ? Color.white : Color.black.opacity(0.2))
    }
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(effectiveIconColor)
                    .contentTransition(.symbolEffect(.replace))
                
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(effectiveTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(effectiveBackground)
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
    ImmersiveControlPanelView(inputMode: .constant(.controller))
        .environmentObject(MainViewModel())
        .environmentObject(StreamControlState.shared)
}

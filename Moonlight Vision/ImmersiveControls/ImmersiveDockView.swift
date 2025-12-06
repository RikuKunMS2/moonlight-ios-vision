//
//  ImmersiveDockView.swift
//  Moonlight Vision
//
//  Global Dock - fixed below user's line of sight
//  Created by Linggan-ua on 2025/12/03.
//

import SwiftUI

/// Global Dock view
struct ImmersiveDockView: View {
    @EnvironmentObject private var controlState: StreamControlState
    @EnvironmentObject private var viewModel: MainViewModel
    
    var body: some View {
        HStack(spacing: 12) {
            // Show/hide control panel
            controlPanelButton
            
            // Immersion mode toggle (only shown in virtual environments)
            if controlState.selectedEnvironmentState != .none {
                immersionModeButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
        .hoverEffect { effect, isActive, _ in
            effect.opacity(isActive ? 1.0 : 0.2)
        }
    }
    
    // MARK: - Buttons
    
    @ViewBuilder
    private var controlPanelButton: some View {
        if controlState.isControlPanelVisible {
            Button(action: toggleControlPanel) {
                Label(viewModel.localized("collapse_panel"), systemImage: "rectangle.badge.minus")
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(action: toggleControlPanel) {
                Label(viewModel.localized("control_panel"), systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
        }
    }
    
    @ViewBuilder
    private var immersionModeButton: some View {
        if controlState.isSemiImmersionEnabled {
            Button(action: toggleImmersionMode) {
                Label(viewModel.localized("semi_immersion_mode"), systemImage: "circle.lefthalf.filled")
            }
            .buttonStyle(.bordered)
            .disabled(controlState.isUpdatingImmersion)
        } else {
            Button(action: toggleImmersionMode) {
                Label(viewModel.localized("full_immersion"), systemImage: "circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(controlState.isUpdatingImmersion)
        }
    }
    
    // MARK: - Actions
    
    private func toggleControlPanel() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            controlState.isControlPanelVisible.toggle()
        }
    }
    
    private func toggleImmersionMode() {
        controlState.onSemiImmersionToggle?(!controlState.isSemiImmersionEnabled)
    }
}

#Preview {
    ImmersiveDockView()
        .environmentObject(StreamControlState.shared)
}

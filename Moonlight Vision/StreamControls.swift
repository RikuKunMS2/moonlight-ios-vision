//
//  StreamControls.swift
//  Moonlight
//
//  Created by tht7 on 24/01/2025.
//  Copyright © 2025 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

struct StreamControls<Additions: View>: View {
    @EnvironmentObject private var viewModel: MainViewModel
    @Environment(\.openWindow) private var openWindow
    
    let horizontal: Bool
    @Binding var streamConfig: StreamConfiguration
    
    let isKeyboardActive: Bool
    let closeAction: () -> Void
    let toggleKeyboardAction: (() -> Void)?

    @State private var volumeBeforeMute: Float = 127
    
    @ViewBuilder var additions: () -> Additions
    
    // Initializer
    init(horizontal: Bool,
         streamConfig: Binding<StreamConfiguration>,
         isKeyboardActive: Bool = false,
         closeAction: @escaping () -> Void,
         toggleKeyboardAction: (() -> Void)? = nil,
         @ViewBuilder additions: @escaping () -> Additions) {
        self.horizontal = horizontal
        self._streamConfig = streamConfig
        self.isKeyboardActive = isKeyboardActive
        self.closeAction = closeAction
        self.toggleKeyboardAction = toggleKeyboardAction
        self.additions = additions
    }

    var body: some View {
        Group {
            if (horizontal) {
                HStack(alignment: .center, spacing: 20) { controls }
            } else {
                VStack(alignment: .leading, spacing: 15) { controls }
            }
        }
        // Removed .labelStyle(.iconOnly) to display Text labels
        .padding()
        .hoverEffect { effect, isActive, _ in
            effect.opacity(isActive ? 1 : 0.3)
        }
    }

    var controls: some View {
        Group {
            Button(action: { closeAction() }) {
                Text(viewModel.localized("home"))
            }
            
            Button(action: { viewModel.streamSettings.dimPassthrough.toggle() }) {
                Text(viewModel.localized("toggle_dimming"))
            }
            
            // --- SPATIAL AUDIO TOGGLE ---
            let currentMode = SpatialAudioMode(rawValue: viewModel.streamSettings.spatialAudioMode) ?? .window
            Button(action: {
                let nextModeRaw = (currentMode.rawValue + 1) % 3
                viewModel.streamSettings.spatialAudioMode = nextModeRaw
                let nextMode = SpatialAudioMode(rawValue: nextModeRaw) ?? .window
                AudioHelpers.applySpatialAudioMode(nextMode)
            }) {
                Text(currentMode == .surround ? "7.1 Surround" : (currentMode == .window ? "Head Tracked" : "Window Source"))
            }
            // -------------------------------------
            
            // Virtual Keyboard Toggle
            if let toggleAction = toggleKeyboardAction {
                Button(action: toggleAction) {
                    Text(viewModel.localized("keyboard"))
                }
                .background(isKeyboardActive ? Color.white.opacity(0.2) : Color.clear)
                .clipShape(Capsule()) // Changed from Circle to Capsule for text
            }

            HStack {
                Button(action: { viewModel.mute.toggle() }) {
                    Text(viewModel.localized("volume"))
                        .foregroundStyle(viewModel.mute ? .secondary : .primary)
                }
                
                Slider(value: Binding(
                    get: { viewModel.vol },
                    set: { newValue in
                        viewModel.vol = newValue
                        setVolume(Int32(newValue)) // Real-time update
                    }
                ), in: 0...127)
                    .frame(width: 300)
                    .padding([.trailing])
            }
            .hoverEffect { effect, isActive, proxy in
                effect.clipShape(.capsule.size(
                    width: isActive ? proxy.size.width : proxy.size.height,
                    height: proxy.size.height,
                    anchor: .leading
                ))
            }
            
            additions()
        }
    }
}

struct aspectRatioRectangle: View {
    let aspectRatio: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle()
                    .fill(Color.primary.opacity(0.0001)) // Invisible fill for interaction
                Rectangle()
                    .stroke(Color.primary, lineWidth: 2)
                    .padding(geometry.size.width * 0.1) // Adjust padding for visual aspect ratio
                    .aspectRatio(aspectRatio, contentMode: .fit)
            }
        }
        .frame(width: 30, height: 20) // Adjust size as needed
    }
}

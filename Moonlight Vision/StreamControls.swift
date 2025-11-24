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

    @State private var spatialAudioMode: Bool = true // From Razorub
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
        .onChange(of: viewModel.vol) { newVal, _ in
            setVolume(Int32(newVal))
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
            
            // --- SPATIAL AUDIO TOGGLE (From Razorub) ---
            Button(action: {
                spatialAudioMode.toggle()
                if spatialAudioMode {
                    // Switch to spatial audio (sound from screen)
                    AudioHelpers.fixAudioForSurroundForCurrentWindow()
                } else {
                    // Switch to direct audio (sound from ears)
                    AudioHelpers.fixAudioForDirectStereo()
                }
            }) {
                Text(spatialAudioMode ? viewModel.localized("spatial_audio") : viewModel.localized("direct_audio"))
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
                
                Slider(value: $viewModel.vol, in: 0...127)
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

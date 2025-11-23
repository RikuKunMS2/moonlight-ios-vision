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
                HStack(alignment: .firstTextBaseline) { controls }
            } else {
                VStack(alignment: .leading) { controls }
            }
        }
        .onChange(of: viewModel.vol) { newVal, _ in
            setVolume(Int32(newVal))
        }
        .labelStyle(.iconOnly)
        .padding()
        .hoverEffect { effect, isActive, _ in
            effect.opacity(isActive ? 1 : 0.3)
        }
    }

    var controls: some View {
        Group {
            Button(viewModel.localized("home"), systemImage: "house.fill") {
                closeAction()
            }
            
            Button(viewModel.localized("toggle_dimming"), systemImage: viewModel.streamSettings.dimPassthrough ? "moon.fill" : "moon") {
                viewModel.streamSettings.dimPassthrough.toggle()
            }
            // --- SPATIAL AUDIO TOGGLE (From Razorub) ---
            Button(spatialAudioMode ? "Spatial Audio" : "Direct Audio",
                systemImage: spatialAudioMode ? "speaker.wave.3" : "headphones") {
                spatialAudioMode.toggle()
                if spatialAudioMode {
                // Switch to spatial audio (sound from screen)
                    AudioHelpers.fixAudioForSurroundForCurrentWindow()
                } else {
                    // Switch to direct audio (sound from ears)
                    AudioHelpers.fixAudioForDirectStereo()
                }
            }
            // -------------------------------------
            
            // Virtual Keyboard Toggle
            if let toggleAction = toggleKeyboardAction {
                Button(action: toggleAction) {
                    Label(viewModel.localized("keyboard"), systemImage: isKeyboardActive ? "keyboard.fill" : "keyboard")
                }
                .background(isKeyboardActive ? Color.white.opacity(0.2) : Color.clear)
                .clipShape(Circle())
            }

            HStack {
                Button(viewModel.localized("volume"), systemImage: viewModel.vol == 0 || viewModel.mute ? "speaker.slash.fill" : "speaker.fill" ) {
                    viewModel.mute.toggle()
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

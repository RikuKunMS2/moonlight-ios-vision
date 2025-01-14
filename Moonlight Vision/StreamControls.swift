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
    let horizontal: Bool
    
    @ViewBuilder var additions: () -> Additions
    
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
            effect.opacity(isActive ? 1 : 0.1)
            //.scaleEffect(isActive ? 1: 0.9)
        }
    }
    
    var controls: some View {
        Group {
            Button("Toggle Dimming", systemImage: viewModel.dimPassthrough ? "moon.fill" : "moon") {
                viewModel.dimPassthrough.toggle()
            }
            HStack {
                Button("Volume", systemImage: viewModel.vol == 0 || viewModel.mute ? "speaker.slash.fill" : "speaker.fill" ) {
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
                //effect.scaleEffect(x: isActive ? 1: 0.5, y: 1, anchor: .leading)
            }
            additions()
        }
    }
}

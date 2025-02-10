//
//  DumyView.swift
//  Moonlight
//
//  Created by tht7 on 06/02/2025.
//  Copyright © 2025 Moonlight Game Streaming Project. All rights reserved.
//
import SwiftUI

struct DummyView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismiss) private var dismiss
    
    @EnvironmentObject private var viewModel: MainViewModel
    
    var body: some View {
        ProgressView()
            .onContinueUserActivity("dummy") { acc in
                let config = try! acc.typedPayload(StreamConfiguration.self)
                print("DUMMY GOT EVENT \(String(describing: config))")
                //DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                openWindow(id: viewModel.streamSettings.renderer.windowId, value: config)
                //}
                dismiss()
            }
    }
}

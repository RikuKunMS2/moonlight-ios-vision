//
//  DummyView.swift
//  Moonlight Vision
//
//  Created by tht7 on 06/02/2025.
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  DumyView.swift
//  Moonlight
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

struct DummyView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismiss) private var dismiss
    
    @EnvironmentObject private var viewModel: MainViewModel
    
    var body: some View {
        ProgressView()
            .onContinueUserActivity("dummy") { acc in
                let config = try! acc.typedPayload(StreamConfiguration.self)
                print("DUMMY GOT EVENT \(String(describing: config))")
                
                let destination = viewModel.getStreamDestination()
                switch destination {
                case .window(let id):
                    openWindow(id: id, value: config)
                case .immersiveSpace(let id):
                    Task {
                        await openImmersiveSpace(id: id, value: config)
                    }
                }
                
                dismiss()
            }
    }
}

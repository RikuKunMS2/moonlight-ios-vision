//
//  AppsView.swift
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/27/24.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation
import SwiftUI

struct AppsView: View {
    @EnvironmentObject private var viewModel: MainViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.pushWindow) private var pushWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace // Required for Immersive Mode
    
    @State private var nowLoading: String?
    
    @Binding
    public var host: TemporaryHost
    
    var body: some View {
        List {
            ForEach(host.appList.sorted(by: { $0.name ?? "" < $1.name ?? "" }), id: \.id) { app in
                HStack {
                    if (nowLoading == (app.id ?? app.name)) {
                        ProgressView()
                    }
                    AppButtonView(host: host, app: app) {
                        if (nowLoading != nil) {
                            return
                        }
                        nowLoading = app.id ?? app.name
                        
                        // 1. Generate Configuration
                        if let config = viewModel.stream(app: app) {
                            
                            let settings = viewModel.streamSettings
                            
                            // 2. Route based on Renderer Selection
                            if settings.renderer == .realitykit {
                                
                                // Check if user wants Immersive Mode (Full Space) or Volumetric Window
                                if settings.realitykitImmersiveMode {
                                    // Immersive Space requires an async Task
                                    Task {
                                        await openImmersiveSpace(id: "realitykitImmersiveSpace", value: config)
                                        dismissWindow(id: "mainView")
                                        // Note: Immersive space doesn't automatically dismiss main view,
                                        // so we do it manually here.
                                    }
                                } else {
                                    // Standard Volumetric Window
                                    openWindow(id: "realitykitStreamingWindow", value: config)
                                    dismissWindow(id: "mainView")
                                }
                                
                            } else {
                                // Classic UIKit Renderer (Push Window)
                                pushWindow(id: "classicStreamingWindow", value: config)
                                nowLoading = nil
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(host.name)
        .onAppear() {
            // this MUST be async lmao
            Task {
                print("LOAD")
                viewModel.refreshAppsFor(host: host)
            }
        }.refreshable() {
            print("REFRESH")
            viewModel.refreshAppsFor(host: host)
        }
    }
}

struct AppButtonView: View {
    let host: TemporaryHost
    let app: TemporaryApp
    let action: () -> Void
    
    var body: some View {
        Button(app.name ?? "Unknown", action: action)
            .badge(Text(app.id == host.currentGame ? "Running" : ""))
            .contextMenu {
                if app.id == host.currentGame {
                    Button {
                        let httpManager = HttpManager(host: app.host())
                        let httpResponse = HttpResponse()
                        let quitRequest = HttpRequest(for: httpResponse, with: httpManager?.newQuitAppRequest())
                        Task {
                            httpManager?.executeRequestSynchronously(quitRequest)
                            // lol no error handling...
                        }
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                }
            }
    }
}

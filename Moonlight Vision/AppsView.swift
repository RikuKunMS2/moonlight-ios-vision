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
        let sortedApps = host.appList.sorted(by: { ($0.name ?? "") < ($1.name ?? "") })
        
        return List {
            ForEach(sortedApps, id: \.id) { app in
                HStack {
                    if (nowLoading == (app.id ?? app.name)) {
                        ProgressView()
                    }
                    AppButtonView(host: host, app: app) {

                        Task { await handleStreamLaunch(for: app) }

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
                    .environmentObject(viewModel)
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
        }
        .alert(viewModel.localized("active_stream"), isPresented: $viewModel.showActiveStreamAlert) {
            Button(viewModel.localized("go_back_to_window")) {
                if viewModel.streamSettings.renderer == .realitykit {
                    openWindow(id: viewModel.streamSettings.renderer.windowId)
                } else {
                    pushWindow(id: viewModel.streamSettings.renderer.windowId)
                }
            }
            Button(viewModel.localized("force_quit"), role: .destructive) {
                viewModel.activelyStreaming = false
                if let pendingApp = viewModel.pendingAppToStream {
                    Task { await startStream(for: pendingApp) }
                }
                viewModel.pendingAppToStream = nil
            }
            Button(viewModel.localized("cancel"), role: .cancel) {
                viewModel.pendingAppToStream = nil
            }
        } message: {
            Text(viewModel.localized("active_stream_message"))
        }
        .alert(viewModel.localized("close_previous_window"), isPresented: $viewModel.showClassicWindowCloseAlert) {
            Button(viewModel.localized("got_it"), role: .cancel) {}
        } message: {
            Text(viewModel.localized("close_previous_window_message"))
        }
        .alert(viewModel.localized("close_realitykit_window"), isPresented: $viewModel.showRealityWindowCloseAlert) {
            Button(viewModel.localized("got_it"), role: .cancel) {}
        } message: {
            Text(viewModel.localized("close_realitykit_window_message"))
        }
        .refreshable() {
            print("REFRESH")
            viewModel.refreshAppsFor(host: host)
        }
    }
    
    @MainActor
    private func handleStreamLaunch(for app: TemporaryApp) async {
        guard nowLoading == nil else { return }
        nowLoading = app.id ?? app.name
        
        defer { nowLoading = nil }
        
        if viewModel.activelyStreaming {
            viewModel.pendingAppToStream = app
            viewModel.showActiveStreamAlert = true
            return
        }
        
        // Note: Manual close checks removed as they are no longer needed
        // Windows are now properly managed through the window lifecycle
        
        await startStream(for: app)
    }
    
    @MainActor
    private func startStream(for app: TemporaryApp) async {
        guard let config = viewModel.stream(app: app) else { return }
        if viewModel.streamSettings.renderer == .realitykit {
            openWindow(id: viewModel.streamSettings.renderer.windowId, value: config)
            dismissWindow(id: "mainView")
        } else {
            openWindow(id: "classicStreamingWindow", value: config)
            dismissWindow(id: "mainView")
        }
    }
}

struct AppButtonView: View {
    @EnvironmentObject private var viewModel: MainViewModel
    let host: TemporaryHost
    let app: TemporaryApp
    let action: () -> Void
    
    var body: some View {
        Button(app.name ?? viewModel.localized("unknown"), action: action)
            .badge(Text(app.id == host.currentGame ? viewModel.localized("running") : ""))
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
                        Label(viewModel.localized("stop"), systemImage: "stop.circle")
                    }
                }
            }
    }
}

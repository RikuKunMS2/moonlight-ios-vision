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
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    
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
                    }
                }
            }
        }
        .navigationTitle(host.name)
        .onAppear() {
            Task {
                // print("LOAD")
                viewModel.refreshAppsFor(host: host)
            }
        }
        .alert(viewModel.localized("active_stream"), isPresented: $viewModel.showActiveStreamAlert) {
            // --- 1. RESUME ACTION ---
            Button(viewModel.localized("go_back_to_window")) {
                Task {
                    // FIX: Removed 'if let' because the config is guaranteed to exist by the compiler
                    let config = viewModel.savedStreamConfigForResume ?? viewModel.currentStreamConfig
                    
                    if viewModel.streamSettings.renderer == .realitykit {
                        if viewModel.streamSettings.realitykitImmersiveMode {
                            await openImmersiveSpace(id: "realitykitImmersiveSpace", value: config)
                        } else {
                            openWindow(id: "realitykitStreamingWindow", value: config)
                        }
                    } else {
                        openWindow(id: "classicStreamingWindow", value: config)
                    }
                    dismissWindow(id: "mainView")
                }
            }
            
            // --- 2. FORCE QUIT & RESTART ACTION ---
            Button(viewModel.localized("force_quit"), role: .destructive) {
                // Stop current stream
                viewModel.activelyStreaming = false
                
                if let pendingApp = viewModel.pendingAppToStream {
                    // Add delay to ensure previous window tears down completely
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        Task { await startStream(for: pendingApp) }
                    }
                } else {
                    viewModel.pendingAppToStream = nil
                }
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
            // print("REFRESH")
            viewModel.refreshAppsFor(host: host)
        }
    }
    
    @MainActor
    private func handleStreamLaunch(for app: TemporaryApp) async {
        guard nowLoading == nil else { return }
        nowLoading = app.id ?? app.name
        
        // Defer clearing loading state
        defer { nowLoading = nil }
        
        if viewModel.activelyStreaming {
            viewModel.pendingAppToStream = app
            viewModel.showActiveStreamAlert = true
            return
        }
        
        await startStream(for: app)
    }
    
    @MainActor
    private func startStream(for app: TemporaryApp) async {
        // 1. Generate Configuration and CAPTURE IT
        // Passing 'value:' in openWindow is required for the WindowGroup data binding to work
        guard let config = viewModel.stream(app: app) else {
            print("Failed to generate stream config")
            return
        }
        
        let settings = viewModel.streamSettings
        
        // 2. Route based on Renderer WITH VALUE
        if settings.renderer == .realitykit {
            if settings.realitykitImmersiveMode {
                // Pass config value
                await openImmersiveSpace(id: "realitykitImmersiveSpace", value: config)
            } else {
                // Pass config value
                openWindow(id: "realitykitStreamingWindow", value: config)
            }
        } else {
            // Pass config value
            openWindow(id: "classicStreamingWindow", value: config)
        }
        
        // 3. Dismiss Main View (The stream window should now be active)
        dismissWindow(id: "mainView")
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
                        }
                    } label: {
                        Label(viewModel.localized("stop"), systemImage: "stop.circle")
                    }
                }
            }
    }
}

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
                        Task { await handleStreamLaunch(for: app) }
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
        .alert(viewModel.localized(english: "Active Stream", chinese: "已有串流窗口"), isPresented: $viewModel.showActiveStreamAlert) {
            Button(viewModel.localized(english: "Go back to window", chinese: "回到窗口")) {
                if viewModel.streamSettings.renderer == .realitykit {
                    openWindow(id: viewModel.streamSettings.renderer.windowId)
                } else {
                    pushWindow(id: viewModel.streamSettings.renderer.windowId)
                }
            }
            Button(viewModel.localized(english: "Force quit", chinese: "强制结束"), role: .destructive) {
                viewModel.forceStopActiveStream()
                if let pendingApp = viewModel.pendingAppToStream {
                    Task { await startStream(for: pendingApp) }
                }
                viewModel.pendingAppToStream = nil
            }
            Button(viewModel.localized(english: "Cancel", chinese: "取消"), role: .cancel) {
                viewModel.pendingAppToStream = nil
            }
        } message: {
            Text(viewModel.localized(english: "A stream is already running. Please return to that window or terminate it before starting a new one.", chinese: "检测到已有串流窗口在运行。请选择回到该窗口或强制结束后重新启动。"))
        }
        .alert(viewModel.localized(english: "Please close the previous window", chinese: "请先关闭旧窗口"), isPresented: $viewModel.showClassicWindowCloseAlert) {
            Button(viewModel.localized(english: "Got it", chinese: "知道了"), role: .cancel) {}
        } message: {
            Text(viewModel.localized(english: "The previous classic window is still open. Please close it before starting another stream.", chinese: "上一次串流已停止，但窗口仍保持打开。请在原窗口横条上点击关闭按钮后再重试。"))
        }
        .alert(viewModel.localized(english: "Please close the RealityKit window", chinese: "请先关闭 RealityKit 窗口"), isPresented: $viewModel.showRealityWindowCloseAlert) {
            Button(viewModel.localized(english: "Got it", chinese: "知道了"), role: .cancel) {}
        } message: {
            Text(viewModel.localized(english: "The RealityKit window is still open. Close it before launching another stream.", chinese: "RealityKit 窗口仍保持打开。请关闭后再尝试启动新的串流。"))
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
        
        if viewModel.streamSettings.renderer == .classic {
            if viewModel.classicWindowNeedsManualClose {
                viewModel.showClassicWindowCloseAlert = true
                return
            }
        } else {
            if viewModel.realityWindowNeedsManualClose {
                viewModel.showRealityWindowCloseAlert = true
                return
            }
        }
        
        await startStream(for: app)
    }
    
    @MainActor
    private func startStream(for app: TemporaryApp) async {
        guard let config = viewModel.stream(app: app) else { return }
        let settings = viewModel.streamSettings
        
        if settings.renderer == .realitykit {
            // Check if user wants Immersive Mode (Full Space) or Volumetric Window
            if settings.realitykitImmersiveMode {
                // Immersive Space requires an async Task
                await openImmersiveSpace(id: "realitykitImmersiveSpace", value: config)
                dismissWindow(id: "mainView")
                // Note: Immersive space doesn't automatically dismiss main view,
                // so we do it manually here.
            } else {
                // Standard Volumetric Window
                openWindow(id: "realitykitStreamingWindow", value: config)
                dismissWindow(id: "mainView")
            }
        } else {
            // Classic UIKit Renderer
            pushWindow(id: "classicStreamingWindow", value: config)
        }
    }
}

struct AppButtonView: View {
    @EnvironmentObject private var viewModel: MainViewModel
    let host: TemporaryHost
    let app: TemporaryApp
    let action: () -> Void
    
    var body: some View {
        Button(app.name ?? viewModel.localized(english: "Unknown", chinese: "未知"), action: action)
            .badge(Text(app.id == host.currentGame ? viewModel.localized(english: "Running", chinese: "运行中") : ""))
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
                        Label(viewModel.localized(english: "Stop", chinese: "停止"), systemImage: "stop.circle")
                    }
                }
            }
    }
}

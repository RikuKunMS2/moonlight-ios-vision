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
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var nowLoading: String?
    @State private var nowLoadingTimeout: Task<Void, Never>?
    @State private var streamModeOverlayApp: TemporaryApp?
    
    @Binding
    public var host: TemporaryHost
    
    var body: some View {
        Group {
            if viewModel.activelyStreaming {
                // When stream running in background, show Resume + Stop instead of app list
                streamInProgressView
            } else {
                let sortedApps = host.appList.sorted(by: { ($0.name ?? "") < ($1.name ?? "") })
                List {
                    ForEach(sortedApps, id: \.id) { app in
                        HStack {
                            if (nowLoading == (app.id ?? app.name)) {
                                ProgressView()
                            }
                            AppButtonView(host: host, app: app) {
                                streamModeOverlayApp = app
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(host.name)
        .onAppear() {
            guard !viewModel.activelyStreaming else { return }
            Task { viewModel.refreshAppsFor(host: host) }
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
            guard !viewModel.activelyStreaming else { return }
            viewModel.refreshAppsFor(host: host)
        }
        .sheet(item: $streamModeOverlayApp) { app in
            StreamModeSelectionOverlay(
                app: app,
                onSelect: { mode in
                    streamModeOverlayApp = nil
                    Task { await launchStreamWithMode(app: app, mode: mode) }
                },
                onDismiss: {
                    streamModeOverlayApp = nil
                }
            )
            .environmentObject(viewModel)
        }
    }
    
    /// Resume + Stop when stream is running in background (main pushed from Home)
    @ViewBuilder
    private var streamInProgressView: some View {
        VStack(spacing: 24) {
            Text(viewModel.localized("active_stream"))
                .font(.title2)
                .foregroundStyle(.secondary)
            
            // Resume - return to stream window via notification
            Button {
                Task { await resumeStreamFromMainMenu() }
            } label: {
                Label(viewModel.localized("resume_stream"), systemImage: "play.circle.fill")
                    .font(.title2)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            
            // Stop - full teardown (notification needed: stream view behind main may not receive shouldCloseStream)
            Button(role: .destructive) {
                Task { await stopStreamFromMainMenu() }
            } label: {
                Label(viewModel.localized("stop"), systemImage: "stop.circle.fill")
                    .font(.title2)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @MainActor
    private func handleStreamLaunch(for app: TemporaryApp) async {
        guard nowLoading == nil else { return }
        let appId = app.id ?? app.name
        nowLoading = appId
        startNowLoadingTimeout()

        // If stale lifecycle state remains after crown/app interruptions, wait briefly and recover.
        if viewModel.streamState != .idle {
            await viewModel.waitForTeardown(timeout: 1.2)
        }
        if viewModel.streamState != .idle {
            viewModel.forceResetStreamLifecycleIfNeeded()
        }
        if viewModel.activelyStreaming {
            clearNowLoading()
            return
        }

        let cooldown = viewModel.reconnectCooldownRemaining()
        if cooldown > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + cooldown + 0.05) {
                Task {
                    if viewModel.streamState != .idle {
                        await viewModel.waitForTeardown()
                    }
                    await openAppStream(app: app)
                }
            }
            return
        }

        if let stale = _UIKitStreamView.controllerReference.object {
            stale.stopStream()
            _UIKitStreamView.controllerReference.object = nil
        }
        await openAppStream(app: app)
    }

    @MainActor
    private func launchStreamWithMode(app: TemporaryApp, mode: StreamModeOption) async {
        let settings = viewModel.streamSettings
        switch mode {
        case .uikit:
            settings.renderer = .classic
            settings.realitykitImmersiveMode = false
        case .realitykitVolume:
            settings.renderer = .realitykit
            settings.realitykitImmersiveMode = false
        case .realitykitImmersive:
            settings.renderer = .realitykit
            settings.realitykitImmersiveMode = true
        }
        settings.save()
        await handleStreamLaunch(for: app)
    }

    @MainActor
    private func resumeStreamFromMainMenu() async {
        NotificationCenter.default.post(name: Notification.Name("ResumeStreamFromMenu"), object: nil)

        // If stream window/space was closed by system gesture (e.g. crown),
        // no receiver may exist for ResumeStreamFromMenu. Reopen from saved config.
        guard let saved = viewModel.savedStreamConfigForResume else { return }
        if viewModel.streamState == .idle {
            viewModel.streamState = .starting
        }
        viewModel.activelyStreaming = true

        let settings = viewModel.streamSettings
        if settings.renderer == .realitykit && settings.realitykitImmersiveMode {
            dismissWindow(id: "mainView")
            _ = try? await openImmersiveSpace(id: "realitykitImmersiveSpace", value: saved)
        } else if settings.renderer == .realitykit {
            dismissWindow(id: "classicStreamingWindow")
            openWindow(id: "realitykitStreamingWindow", value: saved)
            dismissWindow(id: "mainView")
        } else {
            dismissWindow(id: "realitykitStreamingWindow")
            openWindow(id: "classicStreamingWindow", value: saved)
            dismissWindow(id: "mainView")
        }
    }

    @MainActor
    private func stopStreamFromMainMenu() async {
        NotificationCenter.default.post(name: Notification.Name("RequestStreamCloseFromMainMenu"), object: nil)
        viewModel.userDidRequestDisconnect()
        await viewModel.waitForTeardown(timeout: 1.2)
        if viewModel.streamState != .idle {
            viewModel.forceResetStreamLifecycleIfNeeded()
        }
    }

    private func openAppStream(app: TemporaryApp) async {
        viewModel.prepareForNewStream()

        guard let config = viewModel.stream(app: app) else {
            clearNowLoading()
            return
        }

        let settings = viewModel.streamSettings

        // Dismiss existing stream windows before opening new one
        dismissWindow(id: "realitykitStreamingWindow")
        dismissWindow(id: "classicStreamingWindow")

        if settings.renderer == .realitykit && settings.realitykitImmersiveMode {
            dismissWindow(id: "mainView")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                Task {
                    _ = try? await openImmersiveSpace(id: "realitykitImmersiveSpace", value: config)
                    await MainActor.run { clearNowLoading() }
                }
            }
        } else {
            Task {
                await dismissImmersiveSpace()
                await MainActor.run {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        if settings.renderer == .realitykit {
                            openWindow(id: "realitykitStreamingWindow", value: config)
                        } else {
                            openWindow(id: "classicStreamingWindow", value: config)
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        dismissWindow(id: "mainView")
                        clearNowLoading()
                    }
                }
            }
        }
    }

    private func clearNowLoading() {
        nowLoadingTimeout?.cancel()
        nowLoadingTimeout = nil
        nowLoading = nil
    }

    private func startNowLoadingTimeout() {
        nowLoadingTimeout?.cancel()
        nowLoadingTimeout = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if nowLoading != nil {
                    print("[AppsView] nowLoading safety timeout (5s)")
                    clearNowLoading()
                }
            }
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
                        }
                    } label: {
                        Label(viewModel.localized("stop"), systemImage: "stop.circle")
                    }
                }
            }
    }
}

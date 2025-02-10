//
//  AppView.swift
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
                        if let config = viewModel.stream(app: app) {
                            if (viewModel.streamSettings.renderer == .realitykit) {
                                openWindow(id: viewModel.streamSettings.renderer.windowId, value: config)
                                dismissWindow(id: "mainView")
                            } else {
                                pushWindow(id: viewModel.streamSettings.renderer.windowId, value: config)
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

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
    
    public var host: TemporaryHost
    
    var body: some View {
        List {
            ForEach(host.appList.sorted(by: { $0.name ?? "" < $1.name ?? "" }), id: \.id) { app in
                AppButtonView(host: host, app: app) {
                    viewModel.stream(app: app)
                }
            }
        }
        .navigationTitle(host.name)
        .onAppear() {
            // this MUST be async lmao
            
            viewModel.refreshAppsFor(host: host)
        }.refreshable() {
            viewModel.refreshAppsFor(host: host)
        }
    }
}

struct AppButtonView: View {
    var host: TemporaryHost
    var app: TemporaryApp
    var action: () -> Void
    
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

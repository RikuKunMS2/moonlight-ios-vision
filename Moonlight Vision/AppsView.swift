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
        ScrollView {
            VStack {
                Text(String(host.appList.count))
                
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))]) {
                    ForEach(host.appList, id: \.id) { app in
                        Button(app.name ?? "Unknown") {
                            viewModel.stream(app: app)
                        }
                    }
                }
            }
        }.onAppear() {
            // this MUST be async lmao
            
            viewModel.refreshAppsFor(host: host)
        }.refreshable() {
            viewModel.refreshAppsFor(host: host)
        }
    }
}

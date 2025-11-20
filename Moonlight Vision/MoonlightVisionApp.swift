//
//  MoonlightVisionApp.swift
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/27/24.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

struct MoonlightVisionApp: SwiftUI.App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    @Environment(\.pushWindow) private var pushWindow
    
    var body: some Scene {
        WindowGroup("Main view", id: "mainView") {
            MainContentView()
                .environmentObject(appDelegate.mainViewModel)
                .persistentSystemOverlays(.hidden) // Add this line to hide overlays
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        
        WindowGroup("LoadingStream", id: "dummy") {
            DummyView()
                .environmentObject(appDelegate.mainViewModel)
        }
        .handlesExternalEvents(matching: ["dummy"])
        
        // 1. Bounded Volumetric Window (Existing)
                WindowGroup(id: "realitykitStreamingWindow", for: StreamConfiguration.self) { streamConfig in
                     RealityKitStreamView(
                         streamConfig: streamConfig,
                         needsHdr: appDelegate.mainViewModel.streamSettings.enableHdr,
                         isImmersive: false // Explicitly false
                     )
                     .environmentObject(appDelegate.mainViewModel)
                     .onDisappear { streamConfig.wrappedValue = nil }
                }
                .windowStyle(.volumetric)
                .defaultSize(width: 2, height: 2, depth: 2, in: .meters)

                // 2. Unbounded Immersive Space (New)
                ImmersiveSpace(id: "realitykitImmersiveSpace", for: StreamConfiguration.self) { streamConfig in
                     RealityKitStreamView(
                         streamConfig: streamConfig,
                         needsHdr: appDelegate.mainViewModel.streamSettings.enableHdr,
                         isImmersive: true // Explicitly true
                     )
                     .environmentObject(appDelegate.mainViewModel)
                     .onDisappear { streamConfig.wrappedValue = nil }
                }
                .immersionStyle(selection: .constant(.mixed), in: .mixed) // Mixed allows passthrough

                // 3. UIKit Window
                WindowGroup(id: "classicStreamingWindow", for: StreamConfiguration.self) { streamConfig in
                    UIKitStreamView(streamConfig: streamConfig)
                    .environmentObject(appDelegate.mainViewModel)
                }
                .windowStyle(.plain)
                .windowResizability(.contentSize)
            }
        }

@main
struct MainWrapper {
    static func main() -> Void {
        SDLMainWrapper.setMainReady();
        MoonlightVisionApp.main()
    }
}

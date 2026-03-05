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
    @StateObject private var immersionManager = ImmersionStyleManager.shared
    @StateObject private var streamControlState = StreamControlState.shared
    
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
                     .id(streamConfig.wrappedValue?.sessionUUID ?? "none")
                     .environmentObject(appDelegate.mainViewModel)
                     .environmentObject(streamControlState)
                     .task {
                         // Auto-resume: if we have a saved config and current config is nil, restore it
                         if let savedConfig = appDelegate.mainViewModel.savedStreamConfigForResume,
                            streamConfig.wrappedValue == nil {
                             // Restore the saved stream config and start streaming
                             streamConfig.wrappedValue = savedConfig
                             appDelegate.mainViewModel.savedStreamConfigForResume = nil
                             appDelegate.mainViewModel.activelyStreaming = true
                         }
                         // If opening with a new config, clear any saved config
                         if streamConfig.wrappedValue != nil {
                             appDelegate.mainViewModel.savedStreamConfigForResume = nil
                         }
                     }
                     .onDisappear { 
                         // Save config for auto-resume when window closes
                         if let config = streamConfig.wrappedValue {
                             appDelegate.mainViewModel.savedStreamConfigForResume = config
                         }
                         streamConfig.wrappedValue = nil
                     }
                }
                .windowStyle(.volumetric)
                .defaultSize(width: 1.2, height: 1.2, depth: 1.2, in: .meters)

                // 2. Unbounded Immersive Space (New)
                ImmersiveSpace(id: "realitykitImmersiveSpace", for: StreamConfiguration.self) { streamConfig in
                     RealityKitStreamView(
                         streamConfig: streamConfig,
                         needsHdr: appDelegate.mainViewModel.streamSettings.enableHdr,
                         isImmersive: true // Explicitly true
                     )
                     .id(streamConfig.wrappedValue?.sessionUUID ?? "none")
                     .environmentObject(appDelegate.mainViewModel)
                     .environmentObject(streamControlState)
                     .task {
                         // Auto-resume: if we have a saved config and current config is nil, restore it
                         if let savedConfig = appDelegate.mainViewModel.savedStreamConfigForResume,
                            streamConfig.wrappedValue == nil {
                             // Restore the saved stream config and start streaming
                             streamConfig.wrappedValue = savedConfig
                             appDelegate.mainViewModel.savedStreamConfigForResume = nil
                             appDelegate.mainViewModel.activelyStreaming = true
                         }
                         // If opening with a new config, clear any saved config
                         if streamConfig.wrappedValue != nil {
                             appDelegate.mainViewModel.savedStreamConfigForResume = nil
                         }
                     }
                     .onDisappear { 
                         // Save config for auto-resume when immersive space closes
                         if let config = streamConfig.wrappedValue {
                             appDelegate.mainViewModel.savedStreamConfigForResume = config
                         }
                         streamConfig.wrappedValue = nil
                     }
                }
                .immersionStyle(selection: $immersionManager.currentStyle, in: .mixed, .progressive, .full)

                // 3. UIKit Window
                WindowGroup(id: "classicStreamingWindow", for: StreamConfiguration.self) { streamConfig in
                    UIKitStreamView(streamConfig: streamConfig)
                    .id(streamConfig.wrappedValue?.sessionUUID ?? "none")
                    .environmentObject(appDelegate.mainViewModel)
                    .task {
                        // Auto-resume: if we have a saved config and current config is nil, restore it
                        if let savedConfig = appDelegate.mainViewModel.savedStreamConfigForResume,
                           streamConfig.wrappedValue == nil {
                            // Restore the saved stream config and start streaming
                            streamConfig.wrappedValue = savedConfig
                            appDelegate.mainViewModel.savedStreamConfigForResume = nil
                            appDelegate.mainViewModel.activelyStreaming = true
                        }
                        // If opening with a new config, clear any saved config
                        if streamConfig.wrappedValue != nil {
                            appDelegate.mainViewModel.savedStreamConfigForResume = nil
                        }
                    }
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

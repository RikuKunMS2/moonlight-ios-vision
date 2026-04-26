//
//  MoonlightVisionApp.swift
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/27/24.
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

#if os(visionOS)
extension View {
    @ViewBuilder
    func applyUpperLimbVisibility() -> some View {
        if #available(visionOS 2.0, *) {
            self.upperLimbVisibility(.visible)
        } else {
            self
        }
    }
}
#endif

struct MoonlightVisionApp: SwiftUI.App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // Shared singletons must NOT use @StateObject — StateObject assumes exclusive
    // ownership. Using .shared here is undefined across scene churn and can surface as
    // runtime traps (e.g. EXC_BREAKPOINT in App.main) after repeated window/immersive toggles.
    @ObservedObject private var immersionManager = ImmersionStyleManager.shared
    @ObservedObject private var streamControlState = StreamControlState.shared
    @StateObject private var sharePlayManager = SharePlayManager.shared
    
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
#if os(visionOS)
                     .applyUpperLimbVisibility()
#endif
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

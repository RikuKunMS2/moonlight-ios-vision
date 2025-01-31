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
        
        WindowGroup(id: "realitykitStreamingWindow", for: StreamConfiguration.self) { streamConfig in
            @State var lol: Bool = false
            if streamConfig.wrappedValue != nil {
                RealityKitStreamView(streamConfig: Binding(
                    get: { streamConfig.wrappedValue! },
                    set: { n in streamConfig.wrappedValue = n }
                ))
                .onDisappear {
                    print("SteamWindowClosedOutside")
                }
                    .environmentObject(appDelegate.mainViewModel)
                    .onChange(of: appDelegate.mainViewModel) {
                        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
                                                let geometryRequest = UIWindowScene.GeometryPreferences.Vision(resizingRestrictions: .uniform)
                                                windowScene.requestGeometryUpdate(geometryRequest)
                    }
//                    .onAppear {
//                        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
//                        let geometryRequest = UIWindowScene.GeometryPreferences.Vision(resizingRestrictions: .uniform)
//                        windowScene.requestGeometryUpdate(geometryRequest)
//                    }
                   
            } else {
                Text("No computer selected")
            }
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 2, height: 2, depth: 2, in: .meters)
//        .windowResizability(.contentSize)
        
        WindowGroup(id: "classicStreamingWindow", for: StreamConfiguration.self) { streamConfig in
            if streamConfig.wrappedValue != nil {
                UIKitStreamView(streamConfig: Binding(
                    get: { streamConfig.wrappedValue! },
                    set: { n in streamConfig.wrappedValue = n }
                ))
                    .environmentObject(appDelegate.mainViewModel)
            } else {
                Text("No computer selected")
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

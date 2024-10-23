import SwiftUI

struct MoonlightVisionApp: SwiftUI.App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        WindowGroup {
            MainContentView()
                .environmentObject(appDelegate.mainViewModel)
                .persistentSystemOverlays(.hidden) // Add this line to hide overlays
        }
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

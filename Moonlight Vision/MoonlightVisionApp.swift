//

import SwiftUI

struct MoonlightVisionApp: SwiftUI.App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainContentView().environmentObject(MainViewModel())
        }
    }

}

@main
struct MainWrapper {
    
    static func main() -> Void {
        SDLMainWrapper.setMainReady();
        MoonlightVisionApp.main()
    }
}

//

import SwiftUI

@main
struct MoonlightApp: SwiftUI.App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainContentView().environmentObject(MainViewModel())
        }
    }
}

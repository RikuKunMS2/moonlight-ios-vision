//

import SwiftUI

@main
struct MoonlightApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainContentView()
        }
    }
}

//

import SwiftUI

struct SettingsView: View {
    
    @Binding public var settings: TemporarySettings
    
    var body: some View {
        VStack {
            Toggle(isOn: $settings.enableHdr) {
                Text("Enable HDR")
            }
        }.onDisappear() {
            settings.save()
        }
    }
}

//#Preview {
//    SettingsView(TemporarySettings())
//}

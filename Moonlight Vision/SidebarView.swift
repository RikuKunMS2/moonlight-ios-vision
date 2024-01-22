//

import SwiftUI

struct SidebarView: View {
    var body: some View {
        VStack {
            Text("Servers").font(.largeTitle)
            // servers
            Spacer()
            HStack {
                Text("Add Server")
                Text("Settings")

            }

        }
    }
}

#Preview {
    // embed this in the right vertical size
    VStack {
        SidebarView()
    }
    .padding()
    .glassBackgroundEffect()
    
}

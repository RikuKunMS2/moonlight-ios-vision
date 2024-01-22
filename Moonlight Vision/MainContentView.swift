//

import SwiftUI


struct MainContentView: View {

    @State private var items: Set<String> = ["ok"];

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            ComputerView()
        }
    }
}

#Preview {
    MainContentView()
}

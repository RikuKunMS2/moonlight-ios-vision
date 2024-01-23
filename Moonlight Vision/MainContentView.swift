//

import SwiftUI


struct MainContentView: View {
    
    @EnvironmentObject private var viewModel: MainViewModel
    
    @SwiftUI.State private var selectedHost: TemporaryHost?

    var body: some View {
        NavigationSplitView {
            VStack {
                Text("Computers").font(.largeTitle)
                List(viewModel.hosts, selection: $selectedHost) { host in
                    NavigationLink(value: host) {
                        Text(host.name)
                    }
                }
                Spacer()
                HStack {
                    Text("Add Server")
                    Text("Settings")
                }
            }
            
        } detail: {
            if selectedHost != nil {
                ComputerView(host: $selectedHost)
            }
            
        }.task {
            viewModel.loadSavedHosts();
        }.onAppear {
            NotificationCenter.default.addObserver(
                   self,
                   selector:#selector(viewModel.beginRefresh),
                   name: UIApplication.didBecomeActiveNotification,
                   object: nil)
            viewModel.beginRefresh()
        }.onDisappear {
            viewModel.stopRefresh()
            NotificationCenter.default.removeObserver(self)
        }
    }
}

#Preview {
    MainContentView().environmentObject(MainViewModel())
}

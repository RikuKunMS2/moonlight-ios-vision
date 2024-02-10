//

import SwiftUI

struct MainContentView: View {
    @EnvironmentObject private var viewModel: MainViewModel
    
    @State private var selectedHost: TemporaryHost?
    
    @State private var addingHost = false
    @State private var newHostIp = ""
    
    var body: some View {
        if viewModel.activelyStreaming {
            ZStack {
                StreamView(streamConfig: $viewModel.currentStreamConfig)
            }
            .onAppear() {
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
                let geometryRequest = UIWindowScene.GeometryPreferences.Vision(resizingRestrictions: .uniform)
                windowScene.requestGeometryUpdate(geometryRequest)
            }
            .onDisappear() {
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
                let geometryRequest = UIWindowScene.GeometryPreferences.Vision(resizingRestrictions: .freeform)
                windowScene.requestGeometryUpdate(geometryRequest)
            }
            .ornament(attachmentAnchor: .scene(.top), contentAlignment: .bottom) {
                Button("Close") {
                    viewModel.activelyStreaming = false
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 15.0))
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 15.0))
        } else {
            TabView {
                NavigationSplitView {
                    VStack {
                        Text("Computers").font(.largeTitle)
                        List(viewModel.hosts, selection: $selectedHost) { host in
                            NavigationLink(value: host) {
                                Label(host.name, systemImage: host.currentGame == nil ? "desktopcomputer" : "play.desktopcomputer")
                                    .foregroundColor(.primary)
                            }
                        }
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                Button("Add Server", systemImage: "laptopcomputer.and.arrow.down") {
                                    addingHost = true
                                }.alert(
                                    "Enter server",
                                    isPresented: $addingHost
                                ) {
                                    TextField("IP or Host", text: $newHostIp)
                                    Button("Add") {
                                        addingHost = false
                                        viewModel.manuallyDiscoverHost(hostOrIp: newHostIp)
                                    }
                                    Button("Cancel", role: .cancel) {
                                        addingHost = false
                                    }
                                }.alert(
                                    "Unable to add host",
                                    isPresented: $viewModel.errorAddingHost
                                ) {
                                    Button("Ok", role: .cancel) {
                                        viewModel.errorAddingHost = true
                                    }
                                } message: {
                                    Text(viewModel.addHostErrorMessage)
                                }
                            }
                        }
                    }
                    
                } detail: {
                    if let selectedHost {
                        ComputerView(host: selectedHost)
                    }
                    
                }.tabItem {
                    Label("Computers", systemImage: "desktopcomputer")
                }
                .task {
                    viewModel.loadSavedHosts()
                }
                .onAppear {
                    NotificationCenter.default.addObserver(
                        self,
                        selector: #selector(viewModel.beginRefresh),
                        name: UIApplication.didBecomeActiveNotification,
                        object: nil
                    )
                    viewModel.beginRefresh()
                }.onDisappear {
                    viewModel.stopRefresh()
                    NotificationCenter.default.removeObserver(self)
                }
            
                SettingsView(settings: $viewModel.streamSettings).tabItem {
                    Label("Settings", systemImage: "gear")
                }
            }
        }
    }
}

#Preview {
    MainContentView().environmentObject(MainViewModel())
}

//

import SwiftUI

struct MainContentView: View {
    @EnvironmentObject private var viewModel: MainViewModel
    
    @State private var selectedHost: TemporaryHost?
    
    @State private var addingHost = false
    @State private var newHostIp = ""
    
    var body: some View {
        if viewModel.activelyStreaming {
            let streamView = StreamView(streamConfig: $viewModel.currentStreamConfig)
            streamView
                .ornament(attachmentAnchor: .scene(.top)) {
                    Button("Close") {
                        viewModel.activelyStreaming = false
                    }
                }
                .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 3.0))
        } else {
            TabView {
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
                            Button("Add Server") {
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
                    
                } detail: {
                    if let selectedHost {
                        ComputerView(host: selectedHost)
                    }
                    
                }.tabItem {
                    Label("Computers", systemImage: "desktopcomputer")
                }
                .task {
                    viewModel.loadSavedHosts()
                }.onAppear {
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
            
                VStack {
                    Text("ok")
                }.tabItem {
                    Label("Settings", systemImage: "gear")
                }
            }
        }
    }
}

#Preview {
    MainContentView().environmentObject(MainViewModel())
}

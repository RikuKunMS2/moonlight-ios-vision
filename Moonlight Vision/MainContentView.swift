//
//  MainContentView.swift
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/22/24.
//  Copyright © 2024 Moonlight Game Streaming Project.
//


import SwiftUI

struct MainContentView: View {
    @EnvironmentObject private var viewModel: MainViewModel
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var selectedHost: TemporaryHost?

    @State private var addingHost = false
    @State private var isDeletingHost = false
    @State private var hostToDelete: TemporaryHost?
    @State private var newHostIp = ""
    @State private var isRefreshingDiscovery = false // State to track refresh status
    @State private var showDeletionTriggeredMessage = false



    var body: some View {
        TabView {
            NavigationSplitView {
                VStack { // Wrap List and text in a VStack
                    List(viewModel.hostsWithPairState, selection: $selectedHost) { host in
                        NavigationLink(value: host) {
                            hostRow(for: host)
                        }
                    }
                    .alert(viewModel.localized(english: "Really delete?", chinese: "确定要删除吗？"), isPresented: $isDeletingHost) {
                        Button(viewModel.localized(english: "Yes, delete it", chinese: "是的，删除"), role: .destructive) {
                            if let hostToDelete {
                                viewModel.removeHost(hostToDelete)
                                selectedHost = nil
                                showDeletionTriggeredMessage = false
                            }
                        }
                        Button(viewModel.localized(english: "Cancel", chinese: "取消"), role: .cancel) {
                            isDeletingHost = false
                            hostToDelete = nil
                            showDeletionTriggeredMessage = false
                        }
                    }
                    .navigationTitle(viewModel.localized(english: "Computers", chinese: "电脑"))
                    Text(viewModel.localized(english: "Please actually read the Change Log", chinese: "请务必阅读更新日志"))
                        .font(.system(size: 10)) // Even smaller font size for the second line
                        .foregroundColor(.gray)
                        .padding(.bottom) // Add bottom padding for visual spacing

                    Button { // Make the Text a Button
                        isRefreshingDiscovery.toggle()
                        if isRefreshingDiscovery {
                            viewModel.beginRefresh()
                        } else {
                            viewModel.stopRefresh()
                        }
                    } label: {
                        Text(isRefreshingDiscovery ? viewModel.localized(english: "Click here to Stop network discovery, or if things are unresponsive", chinese: "点击此处停止网络发现，或如果无响应") : viewModel.localized(english: "Click here to scans for Hosts", chinese: "点击此处扫描主机")) // Conditional Text
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding() // Add some bottom padding for visual spacing
                    .buttonStyle(.plain) // Remove button styling to make it look like text
                }
                .toolbar { // Keep the toolbar as is for now
                    ToolbarItem(placement: .primaryAction) {
                        Button(viewModel.localized(english: "Add Server", chinese: "添加服务器"), systemImage: "plus") {
                            addingHost = true
                        }.alert(
                            viewModel.localized(english: "Enter server", chinese: "输入服务器"),
                            isPresented: $addingHost
                        ) {
                            TextField(viewModel.localized(english: "IP or Host", chinese: "IP 或主机名"), text: $newHostIp)
                            Button(viewModel.localized(english: "Add", chinese: "添加")) {
                                addingHost = false
                                viewModel.manuallyDiscoverHost(hostOrIp: newHostIp)
                            }
                            Button(viewModel.localized(english: "Cancel", chinese: "取消"), role: .cancel) {
                                addingHost = false
                            }
                        }.alert(
                            viewModel.localized(english: "Unable to add host", chinese: "无法添加主机"),
                            isPresented: $viewModel.errorAddingHost
                        ) {
                            Button(viewModel.localized(english: "Ok", chinese: "确定"), role: .cancel) {
                                viewModel.errorAddingHost = true
                            }
                        } message: {
                            Text(viewModel.addHostErrorMessage)
                        }
                    }
                }
            } detail: {
                if showDeletionTriggeredMessage {
                    Text(viewModel.localized(english: "Host deletion triggered", chinese: "主机删除已触发"))
                }
                else if let selectedHost = Binding<TemporaryHost>($selectedHost) {
                    ComputerViewWrapper(selectedHost: $selectedHost)
                        .environmentObject(viewModel)
                } else {
                    // If the 'if let' above failed, it means the @State variable selectedHost was nil.
                    // Display the placeholder view in this case.
                    Text(viewModel.localized(english: "No host selected", chinese: "未选择主机"))
                        .navigationTitle("") // Optionally clear title when nothing is selected
                }

            }.tabItem {
                Label(viewModel.localized(english: "Computers", chinese: "电脑"), systemImage: "desktopcomputer")
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
                // If we have some hosts in the host list and no host has been selected
                // try to select the first paired host automatically.
                // this will usually happen when we close the stream and reopen this window
                // when we do, the host list won't change but we still want to keep the list looking nice and select something by default
                if selectedHost == nil,
                   let firstHost = viewModel.hosts.first(where: { $0.pairState == .paired })
                {
                    selectedHost = firstHost
                }
                //if !isRefreshingDiscovery { // Only begin refresh if not already toggled on
                //    viewModel.beginRefresh()
                //}
            }.onDisappear {
                //if !isRefreshingDiscovery { // Only stop refresh if not toggled on and still running
                    viewModel.stopRefresh()
                //}
                NotificationCenter.default.removeObserver(self)
            }

            SettingsView(settings: $viewModel.streamSettings)
                .environmentObject(viewModel)
                .tabItem {
                    Label(viewModel.localized(english: "Settings", chinese: "设置"), systemImage: "gear")
                }

            UpdatesView()
                .environmentObject(viewModel)
                .tabItem {
                    Label(viewModel.localized(english: "Changelog", chinese: "更新日志"), systemImage: "info.circle.fill")
                }

        }
        .sheet(isPresented: $viewModel.showLanguagePrompt) {
            LanguagePromptView()
                .environmentObject(viewModel)
        }
    }
    
    private func hostRow(for host: TemporaryHost) -> some View {
        Label {
            Text(host.name)
        } icon: {
            Image(systemName: hostIconName(for: host))
                .foregroundColor(hostIconColor(for: host))
        }
        .foregroundColor(host.state == .online ? .primary : .secondary) // Dim text if offline
        .opacity(host.state == .online ? 1.0 : 0.6) // Further dim if offline
        .contextMenu {
             // Show "Wake PC" only if host is NOT online
             if host.state != .online {
                 Button {
                     viewModel.wakeHost(host)
                 } label: {
                     Label(viewModel.localized(english: "Wake PC", chinese: "唤醒电脑"), systemImage: "sun.horizon")
                 }
                 .disabled(host.mac == nil || host.mac == "00:00:00:00:00:00") // Disable if MAC is missing
             }

             // Allow pairing attempt only if host is online and not paired
             if host.state == .online && host.pairState != .paired {
                  Button {
                      viewModel.tryPairHost(host)
                  } label: {
                      Label(viewModel.localized(english: "Pair", chinese: "配对"), systemImage: "lock.open.desktopcomputer")
                  }
             }

            // Always show Delete
            Button(role: .destructive) {
                print("Setting showDeletionTriggeredMessage = true for selected host")
                showDeletionTriggeredMessage = true
                isDeletingHost = true
                hostToDelete = host
            } label: {
                Label(viewModel.localized(english: "Delete PC", chinese: "删除电脑"), systemImage: "trash")
            }
        }
        // Add an overlay or badge for specific states if desired
        // .overlay(alignment: .bottomTrailing) {
        //     if host.updatePending { ProgressView().scaleEffect(0.5) }
        // }
    }

    // Helper function for icon name based on state
    private func hostIconName(for host: TemporaryHost) -> String {
        switch host.state {
        case .online:
            return host.pairState == .paired ? "desktopcomputer" : "lock.desktopcomputer"
        case .offline:
            return "desktopcomputer.trianglebadge.exclamationmark" // Icon for offline
        case .unknown:
            return "questionmark.circle.fill" // Icon for unknown state
        default: // Should not happen if using enum
             return "questionmark.diamond"
        }
    }

    // Helper function for icon color based on state
      private func hostIconColor(for host: TemporaryHost) -> Color {
          switch host.state {
          case .online:
              return host.pairState == .paired ? .green : .orange // Green if paired, orange if unpaired but online
          case .offline:
              return .red // Red for offline
          case .unknown:
              return .gray // Gray for unknown
          default:
              return .gray
          }
      }

}

// MARK: - Stream Routing Logic

// 1. Define the types of destinations we can launch
enum StreamDestination {
    case window(id: String)
    case immersiveSpace(id: String)
}

extension MainViewModel {
    
    /// Determines the correct Window ID or ImmersiveSpace ID based on current settings
    func getStreamDestination() -> StreamDestination {
        switch streamSettings.renderer {
        case .classic:
            // UIKit renderer always uses a standard window
            return .window(id: "classicStreamingWindow")
            
        case .realitykit:
            // RealityKit renderer checks the new Immersive Mode toggle
            if streamSettings.realitykitImmersiveMode {
                // Unbounded space (allows moving screen anywhere)
                return .immersiveSpace(id: "realitykitImmersiveSpace")
            } else {
                // Bounded volume (standard 3D window)
                return .window(id: "realitykitStreamingWindow")
            }
        }
    }
}

#Preview {
    MainContentView().environmentObject(MainViewModel())
}

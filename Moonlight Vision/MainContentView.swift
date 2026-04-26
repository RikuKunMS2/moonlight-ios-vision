//
//  MainContentView.swift
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/22/24.
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

struct MainContentView: View {
    @EnvironmentObject private var viewModel: MainViewModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

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
                    .alert(viewModel.localized("really_delete"), isPresented: $isDeletingHost) {
                        Button(viewModel.localized("yes_delete_it"), role: .destructive) {
                            if let hostToDelete {
                                viewModel.removeHost(hostToDelete)
                                selectedHost = nil
                                showDeletionTriggeredMessage = false
                            }
                        }
                        Button(viewModel.localized("cancel"), role: .cancel) {
                            isDeletingHost = false
                            hostToDelete = nil
                            showDeletionTriggeredMessage = false
                        }
                    }
                    .navigationTitle(viewModel.localized("computers"))
                    Text(viewModel.localized("please_read_changelog"))
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
                        Text(isRefreshingDiscovery ? viewModel.localized("click_to_stop_discovery") : viewModel.localized("click_to_scan_hosts"))
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding() // Add some bottom padding for visual spacing
                    .buttonStyle(.plain) // Remove button styling to make it look like text
                }
                .toolbar {
                    if viewModel.activelyStreaming {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(viewModel.localized("resume_stream"), systemImage: "play.circle.fill") {
                                NotificationCenter.default.post(name: Notification.Name("ResumeStreamFromMenu"), object: nil)
                            }
                        }
                        ToolbarItem(placement: .destructiveAction) {
                            Button(viewModel.localized("stop"), systemImage: "stop.circle.fill") {
                                Task {
                                    // Post notification first — RealityKitStreamView/UIKitStreamView
                                    // receive it and call triggerCloseSequence/teardown which handles
                                    // dismissing their own window. Avoid calling dismissWindow here for
                                    // RealityKit volume streams: the stream view dismisses itself via
                                    // triggerCloseSequence, and a second dismissWindow call racing with
                                    // an in-flight window animation can cause intermittent crashes.
                                    NotificationCenter.default.post(name: Notification.Name("RequestStreamCloseFromMainMenu"), object: nil)
                                    viewModel.userDidRequestDisconnect()
                                    // Classic UIKit window doesn't observe the notification for self-dismiss,
                                    // so we still need to dismiss it from here.
                                    if viewModel.streamSettings.renderer == .classic {
                                        dismissWindow(id: "classicStreamingWindow")
                                    }
                                    await viewModel.waitForTeardown(timeout: 1.2)
                                    if viewModel.streamState != .idle {
                                        viewModel.forceResetStreamLifecycleIfNeeded()
                                    }
                                }
                            }
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(viewModel.localized("add_server"), systemImage: "plus") {
                            addingHost = true
                        }.alert(
                            viewModel.localized("enter_server"),
                            isPresented: $addingHost
                        ) {
                            TextField(viewModel.localized("ip_or_host"), text: $newHostIp)
                            Button(viewModel.localized("add")) {
                                addingHost = false
                                viewModel.manuallyDiscoverHost(hostOrIp: newHostIp)
                            }
                            Button(viewModel.localized("cancel"), role: .cancel) {
                                addingHost = false
                            }
                        }.alert(
                            viewModel.localized("unable_to_add_host"),
                            isPresented: $viewModel.errorAddingHost
                        ) {
                            Button(viewModel.localized("ok"), role: .cancel) {
                                viewModel.errorAddingHost = true
                            }
                        } message: {
                            Text(viewModel.addHostErrorMessage)
                        }
                    }
                }
            } detail: {
                if showDeletionTriggeredMessage {
                    Text(viewModel.localized("host_deletion_triggered"))
                }
                else if let selectedHost = Binding<TemporaryHost>($selectedHost) {
                    ComputerViewWrapper(selectedHost: $selectedHost)
                        .environmentObject(viewModel)
                } else {
                    // If the 'if let' above failed, it means the @State variable selectedHost was nil.
                    // Display the placeholder view in this case.
                    Text(viewModel.localized("no_host_selected"))
                        .navigationTitle("") // Optionally clear title when nothing is selected
                }

            }.tabItem {
                Label(viewModel.localized("computers"), systemImage: "desktopcomputer")
            }
            .task {
                viewModel.loadSavedHosts()
            }
            .onAppear {
                // Start mDNS discovery immediately when the host list appears —
                // matching the behaviour of the original iOS/iPad Moonlight app
                // (beginForegroundRefresh in viewWillAppear:).
                // This is safe to call multiple times; DiscoveryManager guards against
                // double-start internally.
                viewModel.beginRefresh()

                // Also re-start when the app returns from background (crown/home).
                // We register AFTER the direct call above so we don't double-fire on
                // a cold launch where didBecomeActive fires before onAppear.
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(viewModel.beginRefresh),
                    name: UIApplication.didBecomeActiveNotification,
                    object: nil
                )

                // Auto-select the actively streaming host, or the first paired host
                // when the view appears so the split view doesn't look empty.
                if selectedHost == nil {
                    var hostToSelect: TemporaryHost?
                    if viewModel.activelyStreaming, let appId = viewModel.currentlyStreamingAppId {
                        hostToSelect = viewModel.hosts.first(where: { $0.appList.contains(where: { $0.id == appId || $0.name == appId }) })
                    }
                    if hostToSelect == nil {
                        hostToSelect = viewModel.hosts.first(where: { $0.pairState == .paired })
                    }
                    selectedHost = hostToSelect
                }
            }
            .onChange(of: scenePhase) { oldValue, newValue in
                if oldValue == .active && (newValue == .inactive || newValue == .background) {
                    NotificationCenter.default.post(name: Notification.Name("MainViewWindowClosed"), object: nil)
                }
            }
            .onDisappear {
                viewModel.stopRefresh()
                NotificationCenter.default.removeObserver(self)
            }

            SettingsView(settings: $viewModel.streamSettings)
                .environmentObject(viewModel)
                .tabItem {
                    Label(viewModel.localized("settings"), systemImage: "gear")
                }

            UpdatesView()
                .environmentObject(viewModel)
                .tabItem {
                    Label(viewModel.localized("changelog"), systemImage: "info.circle.fill")
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
                     Label(viewModel.localized("wake_pc"), systemImage: "sun.horizon")
                 }
                 .disabled(host.mac == nil || host.mac == "00:00:00:00:00:00") // Disable if MAC is missing
             }

             // Allow pairing attempt only if host is online and not paired
             if host.state == .online && host.pairState != .paired {
                  Button {
                      viewModel.tryPairHost(host)
                  } label: {
                      Label(viewModel.localized("pair"), systemImage: "lock.open.desktopcomputer")
                  }
             }

            // Always show Delete
            Button(role: .destructive) {
                print("Setting showDeletionTriggeredMessage = true for selected host")
                showDeletionTriggeredMessage = true
                isDeletingHost = true
                hostToDelete = host
            } label: {
                Label(viewModel.localized("delete_pc"), systemImage: "trash")
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

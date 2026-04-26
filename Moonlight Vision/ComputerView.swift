//
//  ComputerView.swift
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/22/24.
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import OrderedCollections // Keep if AppsView or TemporaryHost uses it
import SwiftUI

struct ComputerView: View {
    @EnvironmentObject private var viewModel: MainViewModel

    // Stick with @Binding to ensure changes propagate back up if needed
    // (e.g., when pairing succeeds, the parent view should see the updated host).
    @Binding public var host: TemporaryHost

    // State to manage view-specific behavior like stopping automatic checks
    @State private var stopAutomaticStateUpdate = false

    var body: some View {
        VStack(spacing: 20) { // Add spacing for better layout
            // --- Display Host Name Consistently (Optional: hide during initial unknown state) ---
            // Show name unless it's the very first load (unknown state)
            if host.state != .unknown || host.updatePending { // Show even if updating, but maybe not during initial unknown
                Text(host.name)
                    .font(.largeTitle)
                    .padding(.top)
            }

            // --- Handle Main States ---
            if host.updatePending {
                // Show a generic updating indicator when manually refreshed or during initial task update
                ProgressView(viewModel.localized("updating_host", host.name))
                    .scaleEffect(1.5) // Make spinner larger
            } else {
                // Switch based on the host's primary state (Online, Offline, Unknown)
                switch host.state {
                case .online:
                    // Host is reachable, now determine pairing status
                    onlineView
                        .onAppear {
                            // Reset flag if we enter online state, ensuring task runs if needed later
                            stopAutomaticStateUpdate = false
                        }
                case .offline:
                    // Host is not reachable
                    offlineView
                case .unknown:
                    // Waiting for initial discovery or update to determine state
                    ProgressView(viewModel.localized("connecting_to_host", host.name))
                        .scaleEffect(1.5)
                // No default needed if HostState enum covers all cases explicitly
                }
            }
        }
        .navigationTitle(host.name) // Set navigation title dynamically
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                // ... (Stop Discovery Button if you have it) ...

                // Refresh Specific Host Button
                Button {
                    Task {
                        print("Manual Refresh triggered for \(host.name)")
                        stopAutomaticStateUpdate = false
                        //viewModel.resumeBackgroundDiscovery(for: host) // Optional

                        // --- Call with force: true ---
                        await viewModel.updateHost(host: host, force: true)

                    // Refresh apps if needed *after* the forced update
                    if host.state == .online && host.pairState == .paired {
                         print("Manual Refresh resulted in Online/Paired state, refreshing apps for \(host.name)")
                         await viewModel.refreshAppsFor(host: host)
                    }
                }
            } label: {
                Label(viewModel.localized("refresh_status"), systemImage: "arrow.clockwise")
                }
                .disabled(host.updatePending)
            }
        }
        .onAppear {
            print("ComputerView appearing for \(host.name). Resetting stop flag.")
            stopAutomaticStateUpdate = false
            // viewModel.resumeBackgroundDiscovery(for: host) // Optional
        }
        .task(id: host.id) {
            // Perform initial check only if needed and not stopped by user
            if !stopAutomaticStateUpdate && (host.state == .unknown || host.pairState == .unknown) {
                print("ComputerView.task: Running initial updateHost for \(host.name) (State: \(host.state), PairState: \(host.pairState)).")

                // --- Call with default force: false ---
                await viewModel.updateHost(host: host) // Force is false here

                if host.state == .online && host.pairState == .paired && host.appList.isEmpty {
                    print("ComputerView.task: Host \(host.name) is Online/Paired after update, refreshing apps.")
                    await viewModel.refreshAppsFor(host: host)
                }
            } else {
                 print("ComputerView.task: Skipping automatic updateHost for \(host.name). StopFlag: \(stopAutomaticStateUpdate), State: \(host.state), PairState: \(host.pairState)")
            }
        }
        // Refresh apps when returning online from a *non-unknown* state (e.g. offline).
        // Do NOT refresh on unknown→online: `.task` already ran `refreshAppsFor` after
        // `updateHost`, and duplicating here caused triple HTTP + AttributeGraph cycles.
        .onChange(of: host.state) { oldState, newState in
             print("Host \(host.name) state changed from \(oldState) to \(newState)")
             if newState == .online && host.pairState == .paired && oldState != .unknown {
                 if host.appList.isEmpty {
                     print("Host \(host.name) became Online/Paired (from \(oldState)), refreshing apps.")
                     Task {
                         await viewModel.refreshAppsFor(host: host)
                     }
                 }
             }
        }
        // Use the view model's pairing state for the alert, as pairing is a global action
        .alert(
            viewModel.localized("pairing"),
            isPresented: $viewModel.pairingInProgress,
            presenting: viewModel.currentPin // Use the PIN from the ViewModel
        ) { pinData in // Action buttons using the presented data (PIN)
            Button(viewModel.localized("cancel"), role: .cancel) {
                viewModel.endPairing() // Call ViewModel's cancel function
            }
        } message: { pinData in // Message using the presented data (PIN)
            // Ensure currentPin is properly published and updated in ViewModel
            Text(viewModel.localized("pairing_pin_message", pinData))
        }
    }

    // MARK: - Subviews for States

    /// View displayed when the host is online. Handles pairing status.
    @ViewBuilder // Use ViewBuilder for cleaner conditional logic if needed
    private var onlineView: some View {
        // Switch based on pairing state *only when online*
        switch host.pairState {
        case .paired:
            // Host is Online and Paired -> Show Apps
             // Ensure AppsView takes a Binding<TemporaryHost>
            AppsView(host: $host)

        case .unpaired:
            // Host is Online but Unpaired -> Show Pairing UI
            VStack(spacing: 15) {
                 Label(viewModel.localized("ready_to_pair"), systemImage: "lock.desktopcomputer")
                     .font(.title2)
                     .foregroundColor(.orange) // Use a distinct color

                Text(viewModel.localized("pairing_needed_message"))
                     .font(.body)
                     .multilineTextAlignment(.center)
                     .padding(.horizontal)

                Button(viewModel.localized("start_pairing")) {
                    // ViewModel should handle checking if host is online again if necessary,
                    // but ComputerView already knows it's online here.
                    viewModel.tryPairHost(host)
                }
                .controlSize(.large) // Make button prominent
                // The alert is attached higher up in the view hierarchy now
            }

        case .unknown:
             // Host is Online, but we haven't determined pairing status yet
             VStack(spacing: 15) {
                 Label(viewModel.localized("checking_pairing_status"), systemImage: "questionmark.circle")
                      .font(.title2)
                      .foregroundColor(.gray) // Indicate uncertainty
                 ProgressView()
                      .padding(.bottom)

                 // Option to force pairing attempt
                 Button(viewModel.localized("start_pairing_anyway")) {
                     print("User initiated pairing while pairState is unknown for \(host.name).")
                     viewModel.tryPairHost(host)
                 }
                 .controlSize(.regular)
                 // The alert is attached higher up in the view hierarchy

                 // Option to stop automatic background checks for this view instance
                 Button(viewModel.localized("stop_automatic_checks")) {
                     print("User stopped automatic checks for \(host.name).")
                     stopAutomaticStateUpdate = true // Stop this view's task modifier
                     // Optionally tell ViewModel to pause background *polling* if implemented
                     // viewModel.pauseBackgroundDiscovery(for: host)
                 }
                 .controlSize(.small)
                 .tint(.yellow) // Make stop button distinct
             }

        // No default needed if PairState enum covers all cases
        }
    }

    /// View displayed when the host is offline.
    private var offlineView: some View {
        VStack(spacing: 15) {
            Label(viewModel.localized("offline"), systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                .font(.title2)
                .foregroundColor(.red) // Clear offline indicator
            Text(viewModel.localized("offline_message"))
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            //force refresh
            Button {
                Task {
                    print("Manual Refresh triggered for \(host.name)")
                    stopAutomaticStateUpdate = false
                    //viewModel.resumeBackgroundDiscovery(for: host) // Optional

                    // --- Call with force: true ---
                    await viewModel.updateHost(host: host, force: true)

                    // Refresh apps if needed *after* the forced update
                    if host.state == .online && host.pairState == .paired {
                         print("Manual Refresh resulted in Online/Paired state, refreshing apps for \(host.name)")
                         await viewModel.refreshAppsFor(host: host)
                    }
                }
            } label: {
                Label(viewModel.localized("force_refresh_status"), systemImage: "arrow.clockwise")
            }
            .disabled(host.updatePending)
            // Wake-on-LAN button
            Button {
                viewModel.wakeHost(host)
            } label: {
                Label(viewModel.localized("wake_pc"), systemImage: "sun.horizon")
            }
            .controlSize(.large)
            // Disable if MAC address is missing or invalid
            .disabled(host.mac == nil || host.mac == "00:00:00:00:00:00")
            // Visually indicate disabled state
            .opacity((host.mac == nil || host.mac == "00:00:00:00:00:00") ? 0.5 : 1.0)
        }
        .padding(.vertical) // Add some vertical padding to the offline view
    }
}

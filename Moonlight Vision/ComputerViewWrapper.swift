//
//  ComputerViewWrapper.swift
//  Moonlight Vision
//
//  Created by camy on 4/30/25.
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Moonlight
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

struct ComputerViewWrapper: View {
    @Binding var selectedHost: TemporaryHost? // Receive the optional binding
    @EnvironmentObject private var viewModel: MainViewModel // Access VM if needed

    var body: some View {
        // Check if a host is selected *here*
        if let hostBinding = Binding($selectedHost) {
            // If a host is selected, create the non-optional binding
            // safely within this conditional block and show ComputerView.
            ComputerView(host: hostBinding)
                // ComputerView already gets viewModel via @EnvironmentObject
        } else {
            // If no host is selected, show a placeholder view.
            // This prevents ComputerView from ever being created with a nil host.
            Text("Select a computer from the list.")
                .font(.title)
                .foregroundColor(.secondary)
        }
    }
}

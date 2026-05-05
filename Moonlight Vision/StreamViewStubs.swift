//
//  StreamViewStubs.swift
//  Moonlight Vision
//
//  Created by Linggan-ua on 2026/02/28 ,based on neomoonlight.
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Stub types and shared UI components for stream view.
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI
import RealityKit
import Combine


final class HDRTestParams: ObservableObject {
    @Published var boost: Float = 1.0
    @Published var contrast: Float = 1.0
    @Published var saturation: Float = 1.0
    @Published var mode: Int32 = 1
}


@objc
class DummyControllerDelegate: NSObject, ControllerSupportDelegate {
    func gamepadPresenceChanged() {}
    func mousePresenceChanged() {}
    func streamExitRequested() {}
}


struct CenterHintOverlay: View {
    var text: String
    var icon: String
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36))
            Text(text)
                .font(.headline)
        }
        .padding(24)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .allowsHitTesting(false)
    }
}


struct DimmingPickerView: View {
    @EnvironmentObject private var viewModel: MainViewModel
    @Binding var dimLevel: Int
    @Binding var isPresented: Bool
    @Binding var environmentSphereLevel: Int
    @Binding var envPresetLevel: Int
    
    private let dimOptions: [(Int, String)] = [
        (0, "off"),
        (1, "dim_night"),
        (2, "dim_reactive_v1"),
        (4, "dim_eclipse"),
        (5, "dim_midnight"),
        (6, "dim_twilight"),
        (7, "dim_dawn"),
        (8, "dim_sunrise"),
        (9, "dim_woodland"),
        (10, "dim_reactive_v2"),
        (12, "dim_starfield"),
        (14, "dim_desert")
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(viewModel.localized("dimming"), systemImage: "moon.stars.fill")
                    .font(.headline)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(dimOptions, id: \.0) { option in
                    let isActive = dimLevel == option.0
                    Button {
                        dimLevel = option.0
                        if option.0 != 0 {
                            environmentSphereLevel = 0
                            envPresetLevel = 0
                        }
                        isPresented = false
                    } label: {
                        Text(viewModel.localized(option.1))
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .padding(.horizontal, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isActive ? Color.white.opacity(0.85) : Color.white.opacity(0.12))
                            )
                            .foregroundStyle(isActive ? .black : .white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

extension Notification.Name {
    static let ambientAverageColorUpdated = Notification.Name("ambientAverageColorUpdated")
}

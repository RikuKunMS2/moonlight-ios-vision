//
//  StreamModeSelectionOverlay.swift
//  Moonlight Vision
//
//  Overlay for selecting stream mode (UIKit / RealityKit Volume / RealityKit Immersive) when launching.
//

import SwiftUI

/// Stream mode options when launching a stream
public enum StreamModeOption {
    case uikit          // UIKit flat/plane mode
    case realitykitVolume  // RealityKit volume window
    case realitykitImmersive // RealityKit immersive mode
}

struct StreamModeSelectionOverlay: View {
    @EnvironmentObject private var viewModel: MainViewModel
    let app: TemporaryApp
    let onSelect: (StreamModeOption) -> Void
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(spacing: 28) {
            Text(viewModel.localized("select_stream_mode"))
                .font(.title2)
                .fontWeight(.semibold)
            
            Text(app.name ?? viewModel.localized("unknown"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            HStack(spacing: 24) {
                // UIKit flat mode
                StreamModeCard(
                    icon: "rectangle.portrait",
                    imageName: "StreamModeUIKit",
                    title: viewModel.localized("stream_mode_uikit"),
                    subtitle: viewModel.localized("stream_mode_uikit_desc")
                ) {
                    onSelect(.uikit)
                }
                
                // RealityKit volume window
                StreamModeCard(
                    icon: "square.stack.3d.up.fill",
                    imageName: "StreamModeVolume",
                    title: viewModel.localized("stream_mode_volume"),
                    subtitle: viewModel.localized("stream_mode_volume_desc")
                ) {
                    onSelect(.realitykitVolume)
                }
                
                // RealityKit immersive
                StreamModeCard(
                    icon: "viewfinder",
                    imageName: "StreamModeImmersive",
                    title: viewModel.localized("stream_mode_immersive"),
                    subtitle: viewModel.localized("stream_mode_immersive_desc")
                ) {
                    onSelect(.realitykitImmersive)
                }
            }
            .padding(.horizontal)
            
            Button(action: onDismiss) {
                Text(viewModel.localized("cancel"))
            }
            .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(maxWidth: 520)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// A selectable card with icon illustration
private struct StreamModeCard: View {
    let icon: String
    let imageName: String?
    let title: String
    let subtitle: String
    let action: () -> Void
    
    init(icon: String, imageName: String? = nil, title: String, subtitle: String, action: @escaping () -> Void) {
        self.icon = icon
        self.imageName = imageName
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                Group {
                    if let name = imageName {
                        Image(name)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 48))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .frame(height: 80)
                
                Text(title)
                    .font(.headline)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .padding(.vertical, 20)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

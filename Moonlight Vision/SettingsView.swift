//

import SwiftUI

struct SettingsView: View {
    @Binding public var settings: TemporarySettings

    var body: some View {
        VStack {
            HStack {
                Text("Touch Mode")
                Picker("", selection: $settings.absoluteTouchMode) {
                    Text("Touchpad").tag(false)
                    Text("Touchscreen").tag(true)
                }
            }
            HStack {
                Text("On Screen Controls")
                Picker("", selection: $settings.onscreenControls) {
                    Text("Off").tag(0)
                    Text("Auto").tag(1)
                    Text("Simple").tag(2)
                    Text("Full").tag(3)
                }
            }
            Toggle(isOn: $settings.optimizeGames) {
                Text("Optimize Game Settings")
            }
            HStack {
                Text("Multi-Controller Mode")
                Picker("", selection: $settings.multiController) {
                    Text("Single").tag(false)
                    Text("Auto").tag(true)
                }
            }
            Toggle(isOn: $settings.swapABXYButtons) {
                Text("Swap A/B and X/Y Buttons")
            }
            Toggle(isOn: $settings.playAudioOnPC) {
                Text("Play Audio on PC")
            }
            HStack {
                Text("Preferred Codec")
                Picker("", selection: $settings.preferredCodec) {
                    Text("H.264").tag(PreferredCodec.h264)
                    Text("HEVC").tag(PreferredCodec.hevc)
                    Text("AV1").tag(PreferredCodec.av1)
                    Text("Auto").tag(PreferredCodec.auto)
                }
            }
            Toggle(isOn: $settings.enableHdr) {
                Text("Enable HDR")
            }
            HStack {
                Text("Frame Pacing")
                Picker("", selection: $settings.useFramePacing) {
                    Text("Lowest Latency").tag(false)
                    Text("Smoothest Video").tag(true)
                }
            }
            Toggle(isOn: $settings.btMouseSupport) {
                Text("Citrix X1 Mouse Support")
            }
            Toggle(isOn: $settings.statsOverlay) {
                Text("Statistics Overlay")
            }
        }.onDisappear {
            settings.save()
        }
    }
}

#Preview {
    @State var settings = TemporarySettings()
    return SettingsView(settings: $settings)
}

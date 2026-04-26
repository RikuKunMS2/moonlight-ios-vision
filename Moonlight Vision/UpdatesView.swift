//
//  UpdatesView.swift
//  Moonlight
//
//  Created by camy on 2/2/25.
//  Copyright © 2025 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

struct UpdatesView: View {
    @EnvironmentObject private var viewModel: MainViewModel
    
    var body: some View {
        GeometryReader { geometry in // 1. GeometryReader to get screen width
            let screenWidth = geometry.size.width
            let screenHeight = geometry.size.height
            let horizontalPadding = screenWidth * 0.30 // 20% horizontal padding
            let verticalPaddingForForm = screenHeight * 0.20 // 20% top padding for Form

            Form {
                Section { // Section for the title (no header)
                    HStack { // 2. HStack to apply padding to title
                        Spacer() // Push title to center if needed
                        Text(viewModel.localized("changelog"))
                            .font(.largeTitle)
                            .multilineTextAlignment(.center) // Ensure title text is centered within its area
                        Spacer() // Push title to center if needed
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 20.0) // Corrected and kept top padding for the title section
                }
                .listRowBackground(Color.clear) // Remove background from this section


                Section(header: Text(viewModel.localized("latest_updates"))) { // Section for latest updates
                    VStack(alignment: .leading) {
                        Text("Version 11.0.21 (April 25, 2026)")
                            .font(.headline)
                        Text("- Audio Pipeline Refactor: Complete migration of the spatial audio pipeline (OutputAU) to pure Objective-C.")
                            .font(.body)
                        Text("- Vision Pro Spatial Audio: Restored functional audio streaming by properly activating AVAudioSession and integrating native SpatialAudioComponent for RealityKit. Fixed Opus decoding integration and eliminated \"Session lookup failed\" crashes.")
                            .font(.body)
                        Text("- SharePlay & Spatial Personas: Integrated SharePlay-based co-watching using Spatial Personas for shared immersive viewing experiences.")
                            .font(.body)
                        Text("- Reactive Lighting (Ambilight): Added a user-configurable Reactive Lighting toggle within the immersive control panel.")
                            .font(.body)
                        Text("- HDR Consistency & Calibration: Re-enabled 1:1 HDR EDR mapping for perfect RealityKit HDR and introduced a Calibration Mode toggle in the immersive control panel.")
                            .font(.body)
                        Text("- UIKit Stream Recovery: Added an \"Open Main Menu\" recovery button to the error overlay in UIKitStreamView to escape stuck window states on failed stream resumptions.")
                            .font(.body)
                    }
                    .padding(.vertical)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading) {
                        Text("Version 11.0.20 (Commit b191da8)")
                            .font(.headline)
                        Text("- Concurrency and Network Handling: Moved blocking HTTP network calls (updateHost, refreshAppsFor) to background threads using Swift continuations. Wrapped state updates in ObservableConnectionManager with @mainactor.")
                            .font(.body)
                        Text("- Memory Management: Implemented logic to unload 3D assets, including the Studio USDZ and skybox textures, when the application enters the background or switches to passthrough mode.")
                            .font(.body)
                        Text("- HDR and Color Processing: Added pqExposure to settings. Updated DrawableVideoDecoder and Metal shaders for Rec.709, BT.2020, and SMPTE-C color spaces. Added explicit 10-bit format checks.")
                            .font(.body)
                        Text("- Window Lifecycle and Stability: Added detection for zombie streaming windows and redirection to main menu. Modified stream teardown sequence to use NotificationCenter. Changed shared singletons from @StateObject to @ObservedObject.")
                            .font(.body)
                        Text("- Performance Optimization: Throttled RealityKit mesh generation. Reduced the mDNS discovery polling rate.")
                            .font(.body)
                        Text("- Stream Lifecycle and Window Management: Added StreamModeSelectionOverlay (UIKit, RealityKit Volume, RealityKit Immersive). Resume and Stop buttons on main menu. Centralized stream state management (StreamLifecycleState).")
                            .font(.body)
                        Text("- Input and Control: Replaced InputCaptureView. Added GazeInputController for eye-tracking and pinch-to-click. Added Touch Mode. Support for swapping A/B and X/Y buttons. Fallback logic for controller haptics.")
                            .font(.body)
                        Text("- AV1 Video and HDR: Added AV1Parser.swift. Updated Shaders.metal for HDR (PQ curve, EDR, BT.2020, color grading). Set HDR setting default to 1.0. Shader-based rounded corners.")
                            .font(.body)
                        Text("- Environments and Audio: Added skyboxes and gradient textures for background dimming. Added screen tilt controls. Anchors spatial audio to the 3D scene entity (fixAudioForScene).")
                            .font(.body)
                        Text("- Credit this update to linggan-ua. Note: A later commit will address contribution attribution data accidentally cleared from file headers.")
                            .font(.body)
                    }
                    .padding(.vertical)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading) { // Original VStack for text alignment
                        Text("Version 11.0.17 (Nov 24, 2025)")
                                                    .font(.headline)
                        Text("- In theory improved the av1 processing pipeline so that it no longer has perfomrance issues  but I don't have an m5 to test")
                            .font(.body)
                        Text("- special thanks to u/webheadVR for helping me test av1 and av1 hdr, along with logging data from an m5 device. AV1 should now be working and m5 devices in general should have everything working now, but please contact https://ko-fi.com/lumanaire to report issues")
                            .font(.body)
                        Text("- optimizations to help reduce the shimmering effect in reality kit views")
                            .font(.body)
                        Text("- fixed some localization strings")
                            .font(.body)
                    }
                    .padding(.vertical) // Keep vertical padding
                    .frame(maxWidth: .infinity, alignment: .leading) // Ensure VStack takes full width and aligns content to leading
                    VStack(alignment: .leading) { // Original VStack for text alignment
                        Text("Version 11.0.16 (Nov 23, 2025)")
                                                    .font(.headline)
                        Text("- Added head tracked / non head tracked audio button (thanks to neo moonlight for inspiring this feature)")
                            .font(.body)
                        Text("- fixed reality kit av1 hdr i think, I really don't know because I don't have an m5 unit, unless someone wants to send me one lol please check my ko-fi")
                            .font(.body)
                    

                    }
                    .padding(.vertical) // Keep vertical padding
                    .frame(maxWidth: .infinity, alignment: .leading) // Ensure VStack takes full width and aligns content to leading
                    VStack(alignment: .leading) { // Original VStack for text alignment
                        Text("Version 11.0.15 (Nov 22, 2025)")
                                                    .font(.headline)
                        Text("- Linggan-ua also fixed the parameters saving in the reality kit (the side bar sliders and stuff). This has some knock on effects though, if you have a clipping issue where the stream is kind of clipped, its because the position is set in a way that exceeds the volume size, so just re-adjust it. https://github.com/linggan-ua for his contributions in getting this fixed")
                            .font(.body)
                        Text("- fixed reality kit mouse input")
                            .font(.body)
                    

                    }
                    .padding(.vertical) // Keep vertical padding
                    .frame(maxWidth: .infinity, alignment: .leading) // Ensure VStack takes full width and aligns content to leading
                    VStack(alignment: .leading) { // Original VStack for text alignment
                        Text("Version 11.0.14 (Nov 19, 2025)")
                                                    .font(.headline)
                        Text("- Really really reworked how the home button works and how the resume works so that its a lot less jank special thanks to https://github.com/linggan-ua for his contributions in getting this fixed")
                            .font(.body)
                        Text("- linggan-ua added localization options, right now we support chinese but other contributers are now free to pr additional language support")
                            .font(.body)
                        Text("- AV1 is now supported in reality kit mode, apparently I wrote the code but never bothered to finish it because it wasn't supported at the time and av1 was just returning nil oops. I don't have an m5 version to test so if its still broken please ping me")
                            .font(.body)
                        Text("- Added support for higher bitrate configurations, this is not tested, you may have issues depending on your network configuration and I don't know what the limits of m2/m5 when it comes to processing higher bitrates")
                            .font(.body)
                        Text("- Added an option to reality kit mode that allows for an immersive view to be setup and change stream view to any size, use the lock and unlock to reposition easily")
                            .font(.body)
                        Text("- So we were saving settings on dismisal of the window, so if you like force quit or did something weird with window management it wouldn't save your preferences in the settings menu. This is now fixed, also I fixed some of the stupid defaults like no one wants on screen controls right?")
                            .font(.body)
                        Text("- Redid the complicated math for a better curved screen so that its not distored or strectched, I don't really know when I messed that up I thought it was fine but then it was weird so I fixed it.")
                            .font(.body)
                        Text("- Attempted to make the volume position controls less jank, they should automatically set their own limits to stop accidently clipping the stream view.")
                            .font(.body)
                        Text("- Fixed the color space transform for HDR which should lead to more accurate colors.")
                                                    .font(.body)
                                                Text("- Added a luminance value slider to help calibrate the image between different battery levels, enviorments and uOled Displays (each avp is tuned kind of differently and your battery being low actually makes the HDR worse so charge your device please)")
                                                    .font(.body)
                                                Text("- Added a keyboard button to bring up a virtual keyboard, its kind of jank though, you have to in ui kit mode touch the screen to pop it up, in reality kit mode the keyboard should automatically come up.")
                                                    .font(.body)
                                                Text("- Added an invisible layer in front of the uikit volume that captures and sends mouse and keyboard to the reality kit stream. It might be slightly off and have the same eye tracking moving the cursor jank that uikit has but at least it's there. The touch pinch to click doesn't work due to me having issues with that implentation i'm working on it I promise.")
                                                    .font(.body)

                    }
                    .padding(.vertical) // Keep vertical padding
                    .frame(maxWidth: .infinity, alignment: .leading) // Ensure VStack takes full width and aligns content to leading
                    VStack(alignment: .leading) { // Original VStack for text alignment
                        Text("Version 11.0.12 (Nov 18, 2025)")
                                                    .font(.headline)
                                                Text("- Added the Low Latency Streaming Entitlement (the awdl thing) to improve network performance on wifi channels that are not on ch149(us)/ch44(eu)/ch6(2.4ghz)")
                                                    .font(.body)

                    }
                    .padding(.vertical) // Keep vertical padding
                    .frame(maxWidth: .infinity, alignment: .leading) // Ensure VStack takes full width and aligns content to leading
                    VStack(alignment: .leading) { // Original VStack for text alignment
                        Text("Version 11.0.11 (Oct 25, 2025)")
                            .font(.headline)
                        Text("- Fixed the memory resumption bug (previously the app had no idea how to handle the Vision OS 26 resumption of app on memory exit mode) if you have an issue with an empty window press and hold the crown and capture buttons to force quit, but hopefully this isn't an issue anymore.")
                            .font(.body)
                        Text("- Implemented fix for controller crashing from JFuellem (thank you so much) that changes a sync to an async (oops!)")
                            .font(.body)
                        Text("- Apparently AV1 on the new m5 vision pro works in UI Kit mode but not in Reality Kit Mode, we are looking into this.")
                            .font(.body)
                        Text("- Added HOME button that helps bring back up the connection menu, as the new (frankly annoying) vision OS 26 just HIDES the app instead of quitting it or closing the window for real.")
                            .font(.body)

                    }
                    .padding(.vertical) // Keep vertical padding
                    .frame(maxWidth: .infinity, alignment: .leading) // Ensure VStack takes full width and aligns content to leading
                    VStack(alignment: .leading) { // Original VStack for text alignment
                        Text("Version 11.0.08 (April 30, 2025)")
                            .font(.headline)
                        Text("- Fixed unpair state on relaunch or open app due to datamanger issue")
                            .font(.body)
                        Text("- Added SBS options")
                            .font(.body)

                    }
                    .padding(.vertical) // Keep vertical padding
                    .frame(maxWidth: .infinity, alignment: .leading) // Ensure VStack takes full width and aligns content to leading
                    VStack(alignment: .leading) { // Original VStack for text alignment
                        Text("Version 11.0.6 (April 30, 2025)")
                            .font(.headline)
                        Text("- Automatic Network discovery was causing a lot of issues, redid a lot of it, it should be much better, and less crashy.")
                            .font(.body)
                        Text("- Deleting PCs should no longer cause a crash")
                            .font(.body)
                        Text("- Detection for PC off states should help stabilize the app when there are multiple hosts saved, or avaialble or offline")
                            .font(.body)
                        Text("- CLOSE YOUR STREAM before restarting or unplugging, otherwise you will have to use force close, which can be triggered by holding down the crown and capture buttons for a few seconds to force close the app. I can't find an API for a scene or state case that is 'on startup launch' so I don't know how to fix this issue.")
                            .font(.body)
                        Text("- I can't help you with Tailscale, it's not something I've tested, so YMMV when using this")
                            .font(.body)
                        Text("- IF YOU ARE ON APOLLO YOU MUST ENABLE ALL PERMISSIONS OR YOU WILL NOT BE ABLE TO CONNECT")
                            .font(.body)
                        Text("- I changed the home button in reality kit to a controller button because its meant to be an XBOX HOME BUTTON not a go back to main menu, to get back to the menu just close the volume.")
                            .font(.body)

                    }
                    .padding(.vertical) // Keep vertical padding
                    .frame(maxWidth: .infinity, alignment: .leading) // Ensure VStack takes full width and aligns content to leading
                    VStack(alignment: .leading) { // Original VStack for text alignment
                        Text("Version 11.0.3 (February 20, 2025)")
                            .font(.headline)
                        Text("- I wanted to give special thanks to tht7 (https://www.reddit.com/user/tht7), ALVR for Vision Pro's shinyquagsire23 and Giovanni Petrantoni (sinkingsugar) from Formabble https://formabble.com, dereklucas (https://derekplucas.com) for their contributions to Moonlight XrOS")
                            .font(.body)
                        Text("- Reality Kit HDR Support is now in beta, it mostly works but YMMV on color accuracy. More options to control HDR will likely be added later. Special thanks to ALVR for Vision Pro's shinyquagsire23 and Giovanni Petrantoni from Formabble (sinkingsugar) for bringing fixes to HDR to Moonlight XrOS")
                            .font(.body)
                        Text("- SBS Support added to Reality Kit Mode (it is a new button in the reality kit volume side bar) Thanks to dereklucas for this contribution.")
                            .font(.body)
                        Text("- tht7 added support for AppIntents! (Shortcut support) that allow users to directly launch into the StreamView if you've already paired (by accessing saved apps directly without opening the mainview). You should now be able to apps like 'Steam Big Picture' directly to their home screen, giving the new illusion of native-ness (tht7)")
                            .font(.body)
                        Text("- Fixed error messages so that app won't crash on connection or disconnection issues (tht7)")
                            .font(.body)
                        Text("- Many optimizations for opening streams (tht7) it is now so much faster to connect to a server")
                            .font(.body)
                        Text("- Fixed issues with double volumes opening on slow connections (tht7).")
                            .font(.body)
                        Text("- UI Optimizations (default to selecting to computer for example) (tht7)")
                            .font(.body)
                        Text("- The Wizard of ALVR, shinyquagsire23 made significant perfomrance optimizations")
                            .font(.body)
                        Text("- Edge shimmering on reality kit view should be resolved (shinyquagsire23)")
                            .font(.body)
                    }
                    .padding(.vertical) // Keep vertical padding
                    .frame(maxWidth: .infinity, alignment: .leading) // Ensure VStack takes full width and aligns content to leading
                    VStack(alignment: .leading) { // Original VStack for text alignment
                        Text("Version 11.0.1 (February 5, 2025)")
                            .font(.headline)
                        Text("- New error messages, this should help prevent crashes on disconnects!")
                            .font(.body)
                        Text("- Fixed some audio issues when switching between apps.")
                            .font(.body)
                        Text("- Changed some default settings so that the volume in reality kit is easier to move and resize. Please note that using the dimming feature will remove the handle, so to change it again after turn off the dimming")
                            .font(.body)
                        Text("- Fixed issues with the game controller losing focus when switching between apps, also improved reliability when the vision pro is low on resources (so that inputs do not get dropped).")
                            .font(.body)
                        Text("- We are aware of some devices having color inconsitency, we are unsure why this is, some users report more vibrant colors and some report less vibrant colors. I do not know what to make of this yet.")
                            .font(.body)
                        Text("- The Wizard of ALVR, shinyquagsire23 made some contributions, they are not in this version but they should be in the next version 11.0.2, and are being reviewed, but should improve edge shimmering issues AND fixes for HDR. The next update should also be more performant, bringing better performance when using 200mbps")
                            .font(.body)
                    }
                    .padding(.vertical) // Keep vertical padding
                    .frame(maxWidth: .infinity, alignment: .leading) // Ensure VStack takes full width and aligns content to leading
                    VStack(alignment: .leading) { // Original VStack for text alignment
                        Text("Version 11.0.0 (February 1, 2025)")
                            .font(.headline)
                        Text("- Initial support for Reality Kit Volume (for curved screens) thanks to https://www.reddit.com/user/tht7/ for his hard work on the new feature for Moonlight XrOS!")
                            .font(.body)
                        Text("- Use the text toggle to SCAN for computers. You might need to toggle it on to finish paring process, I'm not sure. I know if I leave it constantly scanning, you will run into performance issues.")
                            .font(.body)
                        Text("- If you use the Reality Kit height adjust slider, the buttons to control it will remain AT THE BOTTOM of the volume's plane, we cannot change this, so just look down if you set it higher.")
                            .font(.body)
                        Text("- UIKit has a new aspect ratio button, so if you have a weird window aspect ratio, just click the button and it should fix it, if it doesn't work, try closing the stream and opening it again, then clicking the button, generally you'll notice a large size window on connect when it works, i'm not quite sure why its so finicky, we're still working on stablity hence the testflight.")
                            .font(.body)
                        Text("- RealityKit mode DOES NOT SUPPORT mouse and keyboard, only controllers.")
                            .font(.body)
                        Text("- This is fixed now, performance should be good tested up to 120, i think 200mbp is fine too but YMMV: Realitykit is unstable past 50mbs, please set your bandwidth to 50mbs or lower for performance, we are working on optimizing this.")
                            .font(.body)
                        Text("- Changelog tab added to track updates.")
                            .font(.body)
                        Text("- Keep in mind you can enable two finger to enlarge window to make uikit windows larger than what the handle lets you make it, you will have to enable that in the settings.")
                            .font(.body)

                    }
                    .padding(.vertical) // Keep vertical padding
                    .frame(maxWidth: .infinity, alignment: .leading) // Ensure VStack takes full width and aligns content to leading
                }

                Section(header: Text(viewModel.localized("noted_bugs"))) { // Section for older updates
                    VStack(alignment: .leading) {
                        Text("- If you get a blackscreen trying to resume a volume, this has to do with resumption, I am trying to figure out a better alert system for when this happens. Just force quit the app.")
                            .font(.body)
                            .foregroundColor(.white)
                        Text("- The curve is not 100% accurate, it has some incorrect stretching, we are looking into how to update the rendering so it's not so warped.")
                            .font(.body)
                            .foregroundColor(.white)
                        Text("- HDR is noteably broken on UiKit, Colors might not be perfect on Reality Kit, we are looking into adding some additional options to help adjust this.")
                            .font(.body)
                            .foregroundColor(.white)
                        Text("- Controller Vibration isn't working, we are looking into this.")
                            .font(.body)
                            .foregroundColor(.white)
                        Text("- According to user reports, PS4 touch pad does not work, we added a 'home' button in reality kit but it's not in reality kit yet. This is an SDL issue, Moonlight uses SDL2 but the latest version is SDL3, would take some large effort to update everything to be SDL3 compliant.")
                            .font(.body)
                            .foregroundColor(.white)

                    }
                    .padding(.vertical)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                Section(header: Text(viewModel.localized("feature_requests"))) { // Section for older updates
                    VStack(alignment: .leading) {
                        Text("- Virtual Keyboard Button.")
                            .font(.body)
                            .foregroundColor(.white)
                        Text("- Microphone Support.")
                            .font(.body)
                            .foregroundColor(.white)
                        Text("- 7.1 Audio + Ability to turn on and off immersive audio")
                            .font(.body)
                            .foregroundColor(.white)
                        Text("- According to user reports, PS4 touch pad does not work, we added a 'home' button in reality kit but it's not in reality kit yet. This is an SDL issue, Moonlight uses SDL2 but the latest version is SDL3, would take some large effort to update everything to be SDL3 compliant.")
                            .font(.body)
                            .foregroundColor(.white)

                    }
                    .padding(.vertical)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section(header: Text(viewModel.localized("more_information"))) { // Optional section for more links etc.
                    VStack(alignment: .leading) {
                        Text(viewModel.localized("official_website"))
                            .font(.body)
                        Link("Moonlight Game Streaming Project Website", destination: URL(string: "https://moonlight-stream.org/")!)
                            .font(.body)
                        Link("Moonlight XrOS Github", destination: URL(string: "https://github.com/RikuKunMS2/moonlight-ios-vision/tree/vision-testflight")!)
                            .font(.body)
                        Link("Regular Updates", destination: URL(string: "http://ko-fi.com/lumanaire")!)
                            .font(.body)
                        Link("Moonlight Discord (use channel #ios-appletv-help)", destination: URL(string: "https://moonlight-stream.org/discord")!)
                            .font(.body)

                    }
                    .padding(.vertical)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .glassBackgroundEffect()
            .padding(.top, 20.0) // Corrected and kept top padding for the title section
        }
    }
}


#Preview {
    UpdatesView()
}

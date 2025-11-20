//
//  UIKitStreamView.swift
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/27/24.
//  Copyright © 2024 Moonlight Game Streaming Project.
//

import SwiftUI

struct UIKitStreamView: View {
    @Binding var streamConfig: StreamConfiguration?

    @EnvironmentObject private var viewModel: MainViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    // This state tracks if *we* triggered the close.
    @State private var isClosingForHome = false

    var body: some View {
        if let configBinding = Binding($streamConfig) {
            _UIKitStreamView(streamConfig: configBinding)
                .ornament(attachmentAnchor: .scene(.top), contentAlignment: .bottom) {
                    StreamControls(
                        horizontal: true,
                        streamConfig: configBinding,
                        // This action just disconnects the stream
                        // and opens the main menu.
                        isKeyboardActive: false, 
                        closeAction: {
                            // 1. Tell the app we are no longer streaming.
                            viewModel.activelyStreaming = false
                            
                            // 2. Open the main view.
                            openWindow(id: "mainView")
                            
                            // 3. Find the view controller and tell it to stop.
                            if let streamVC = _UIKitStreamView.controllerReference.object {
                                streamVC.stopStream()
                            }
                            
                            // 4. We DO NOT set streamConfig = nil.
                        },
                        toggleKeyboardAction: {
                                                    if let streamVC = _UIKitStreamView.controllerReference.object {
                                                        streamVC.toggleKeyboard()
                                                    }
                                                }
                    ) {
                        _UIKitStreamViewWindowButton(streamConfig: configBinding, controllerReference: _UIKitStreamView.controllerReference)
                    }
                }
                .onAppear {
                    // This is the "resume from sleep" fix
                    if !viewModel.activelyStreaming {
                        print("UIKitStreamView: Detected appearance without active stream state...")
                        
                        isClosingForHome = true // Act as if home was pressed
                        openWindow(id: "mainView")
                        streamConfig = nil
                        dismissWindow(id: "classicStreamingWindow")
                    } else {
                        // This is a normal stream start
                        isClosingForHome = false // Ensure flag is reset
                        dismissWindow(id: "mainView")
                    }
                }
        } else {
            // This 'else' block is rendered when streamConfig becomes nil.
            // Its .onAppear acts as the .onDisappear for the stream view.
            EmptyView()
                .onAppear {
                    // Check if we got here by pressing the Home button.
                    if isClosingForHome {
                        // Safely open the main view *after* this window is gone.
                        openWindow(id: "mainView")
                    }
                    
                    // Always make sure this window is dismissed.
                    dismissWindow(id: "classicStreamingWindow")
                }
        }
    }
}

struct _UIKitStreamViewWindowButton: View {
    @Binding var streamConfig: StreamConfiguration
    @State private var currentWindow: UIWindow? = nil // State to hold the window reference
    let controllerReference: Reference<StreamFrameViewController> // Receive the reference

    var body: some View {
        Button {
            if let window = currentWindow {
                applyAspectRatioLock(streamConfig: streamConfig, targetWindow: window) // Pass the window
                AudioHelpers.fixAudioForSurroundForUIKitWindow(window) // TODO(shinyquagsire23): Make this configurable
            } else {
                print("Error: No window reference available to apply aspect ratio lock.")
                // Optionally provide user feedback here, e.g., an alert
            }
        } label: {
            Label {
                Text("Fix Aspect Ratio")
            } icon: {
                Image(systemName: "aspectratio")
            }
        }
        .onAppear {
            // Find the window when the button appears (or when the view is updated)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { // Small delay
                findWindow()
            }
        }
        .onChange(of: streamConfig) { _ in // Update if streamConfig changes (though window likely stays the same)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { // Small delay
                findWindow()
            }
        }
    }

    private func findWindow() {
        print("Attempting to find window...")
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            print("Warning: Could not get the first connected scene.")
            return
        }

        print("Connected scenes count: \(UIApplication.shared.connectedScenes.count)")
        print("Window scene windows count: \(scene.windows.count)")

        // More robust approach: Try to find the window from the StreamFrameViewController's view
        if let streamViewController = controllerReference.object { // Access the StreamFrameViewController through the reference
            if let streamView = streamViewController.view {
                var viewToFindWindow: UIView? = streamView
                while viewToFindWindow != nil {
                    if let window = viewToFindWindow?.window {
                        print("Found window by traversing view hierarchy: \(window)")
                        currentWindow = window
                        AudioHelpers.fixAudioForSurroundForUIKitWindow(window)
                        return
                    }
                    viewToFindWindow = viewToFindWindow?.superview
                }
            } else {
                print("Warning: streamViewController.view is nil")
            }
        } else {
            print("Warning: controllerReference.object is nil")
        }


        print("Warning: Could not find window associated with StreamFrameViewController using view hierarchy traversal.")
        currentWindow = nil // Ensure currentWindow is nil if not found.
        // Optionally provide user feedback here if window is not found
    }
}


struct _UIKitStreamView: UIViewControllerRepresentable {
    typealias UIViewControllerType = StreamFrameViewController

    @Binding var streamConfig: StreamConfiguration
    static let controllerReference = Reference<UIViewControllerType>() // Make it static

    static var reference: Reference<UIViewControllerType> { // Provide access to the reference
        return controllerReference
    }

    func makeUIViewController(context: Context) -> UIViewControllerType {
        let streamView = StreamFrameViewController()
        streamView.streamConfig = streamConfig
        streamView.connectedCallback = {
            print("Connected in Swift!")
            AudioHelpers.fixAudioForSurroundForCurrentWindow() // TODO(shinyquagsire23): Make this configurable
        };
        streamView.disconnectedCallback = {
            print("Disconnected in Swift!")
        };
        _UIKitStreamView.controllerReference.object = streamView // Use the static reference
        return streamView
    }

    func updateUIViewController(_ viewController: UIViewControllerType, context: Context) {
        viewController.streamConfig = streamConfig // Ensure streamConfig updates
        _UIKitStreamView.controllerReference.object = viewController // Update in case view controller instance changes (though unlikely in this setup)
    }
}

class Reference<T: AnyObject> {
    weak var object: T?
}

// MARK: - Helper Functions

func applyAspectRatioLock(streamConfig: StreamConfiguration, targetWindow: UIWindow?) {
    guard let window = targetWindow else {
        print("Error: No target window provided to apply aspect ratio lock.")
        return
    }

    let streamWidth = CGFloat(streamConfig.width)
    let streamHeight = CGFloat(streamConfig.height)
    let streamAspectRatio = streamWidth / streamHeight

    print("Applying Aspect Ratio Lock - Stream Width: \(streamWidth), Stream Height: \(streamHeight), Stream AR: \(streamAspectRatio)")

    let maxWidth: CGFloat = 2000 // Increased maxWidth for potentially larger screens
    var desiredSize = CGSize.zero

    for desiredWidthInt in (1...Int(maxWidth)).reversed() {
        let desiredWidth = CGFloat(desiredWidthInt)
        let desiredHeightFloat = desiredWidth / streamAspectRatio
        let desiredHeightInt = Int(round(desiredHeightFloat))

        if desiredHeightInt > 0 {
            desiredSize = CGSize(width: desiredWidth, height: CGFloat(desiredHeightInt))
            //print("Calculated Desired Size - Width: \(desiredSize.width), Height: \(desiredSize.height)")
            break
        }
    }

    guard let windowScene = window.windowScene else {
        print("Error: Could not get window scene from target window.")
        return
    }

    let geometryRequest = UIWindowScene.GeometryPreferences.Vision(
        size: desiredSize,
        resizingRestrictions: .uniform
    )

    //print("Applying Geometry Request for Aspect Ratio Lock.")

    // Apply to the provided window.
    //print("Applying to the provided window.")

    //print("Window Information Before Request:")
    let windowBounds = window.bounds
    let windowWidth = windowBounds.width
    let windowHeight = windowBounds.height
    let windowAspectRatio = windowWidth / windowHeight
    let identifier = window.accessibilityIdentifier ?? "nil"
    let rootViewControllerClassName = String(describing: window.rootViewController?.classForCoder)

    //print("\nWindow Information (Before Geometry Request):")
    //print("Window Width: \(windowWidth)")
    //print("Window Height: \(windowHeight)")
    //print("Window Aspect Ratio: \(windowAspectRatio)")
    //print("Window Accessibility Identifier: \(identifier)")
    //print("Window Root View Controller Class: \(rootViewControllerClassName)")

    windowScene.requestGeometryUpdate(geometryRequest)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { // Short delay for logging
        //print("\nWindow Information After Request:")
        let updatedBounds = window.bounds
        let updatedWidth = updatedBounds.width
        let updatedHeight = updatedBounds.height
        let updatedAspectRatio = updatedWidth / updatedHeight
        let identifier = window.accessibilityIdentifier ?? "nil"
        let rootViewControllerClassName = String(describing: window.rootViewController?.classForCoder)

        //print("\nWindow Size (After Delay):")
        //print("Updated Window Width: \(updatedWidth)")
        //print("Updated Window Height: \(updatedHeight)")
        //print("Updated Aspect Ratio: \(updatedAspectRatio)")
        //print("Window Accessibility Identifier: \(identifier)")
        //print("Window Root View Controller Class: \(rootViewControllerClassName)")
    }
}

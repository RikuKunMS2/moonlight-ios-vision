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
    @Environment(\.scenePhase) private var scenePhase

    @State private var hasPerformedTeardown = false
    @State private var needsResume = false
    @State private var reloadToken = UUID()
    @State private var backgroundTask: Task<Void, Never>?
    @State private var windowSizeMonitorTask: Task<Void, Never>? = nil
    @State private var lastSavedWindowSize: CGSize? = nil

    var body: some View {
        Group {
            if viewModel.activelyStreaming,
               let configBinding = Binding($streamConfig) {
                _UIKitStreamView(streamConfig: configBinding)
                    .id(reloadToken)
                    .ornament(attachmentAnchor: .scene(.top), contentAlignment: .bottom) {
                        StreamControls(
                            horizontal: true,
                            streamConfig: configBinding,
                            isKeyboardActive: false, 
                            closeAction: {
                                handleHomeButtonClose()
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
                        hasPerformedTeardown = false
                        dismissWindow(id: "mainView")
                        startWindowSizeMonitoring()
                    }
                    .onDisappear {
                        stopWindowSizeMonitoring()
                        handleWindowDisappearance()
                    }
                    .onChange(of: scenePhase) { _, phase in
                        switch phase {
                        case .background:
                            // Only pause when truly backgrounded (e.g., immersive scene or headset removal)
                            prepareForBackground()
                        case .active:
                            resumeIfNeeded()
                        default:
                            break
                        }
                    }
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text(viewModel.localized("stream_stopped"))
                        .font(.title2)
                    Text(viewModel.localized("stream_stopped_message"))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button {
                        openWindow(id: "mainView")
                    } label: {
                        Label(viewModel.localized("open_main_menu"), systemImage: "house.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.thinMaterial)
            }
        }
    }

    private func handleHomeButtonClose() {
        tearDownStream(openMainWindow: true)
    }

    private func handleWindowDisappearance() {
        guard !hasPerformedTeardown else { return }
        guard !needsResume else { return }
        tearDownStream(openMainWindow: true)
    }

    private func tearDownStream(openMainWindow: Bool) {
        guard !hasPerformedTeardown else { return }
        hasPerformedTeardown = true
        needsResume = false

        viewModel.activelyStreaming = false

        if let streamVC = _UIKitStreamView.controllerReference.object {
            streamVC.stopStream()
        }

        // Save window size if remember settings is enabled
        if viewModel.streamSettings.rememberStreamSettings {
            saveWindowSizeForRestore()
        }

        // Always save the stream config for auto-resume
        if let config = streamConfig {
            viewModel.savedStreamConfigForResume = config
        }

        streamConfig = nil
        if openMainWindow {
            DispatchQueue.main.async {
                openWindow(id: "mainView")
            }
        }
    }
    
    private func saveWindowSizeForRestore() {
        // Try to find the window and save its size
        if let streamVC = _UIKitStreamView.controllerReference.object,
           let window = streamVC.view.window ?? streamVC.view?.superview?.window {
            let currentSize = window.bounds.size
            saveWindowSizeToUserDefaults(currentSize)
        }
    }
    
    private func saveWindowSizeToUserDefaults(_ size: CGSize) {
        guard viewModel.streamSettings.rememberStreamSettings else { return }
        
        // Only save if size has changed significantly (avoid unnecessary writes)
        if let lastSize = lastSavedWindowSize {
            let widthDiff = abs(size.width - lastSize.width)
            let heightDiff = abs(size.height - lastSize.height)
            // Only save if change is more than 1 pixel
            if widthDiff < 1.0 && heightDiff < 1.0 {
                return
            }
        }
        
        let defaults = UserDefaults.standard
        defaults.set(size.width, forKey: "uikitWindowWidth")
        defaults.set(size.height, forKey: "uikitWindowHeight")
        lastSavedWindowSize = size
        print("Saved UIKit window size to UserDefaults: \(size)")
    }
    
    private func startWindowSizeMonitoring() {
        stopWindowSizeMonitoring() // Stop any existing monitor
        
        guard viewModel.streamSettings.rememberStreamSettings else { return }
        
        windowSizeMonitorTask = Task {
            var lastCheckedSize: CGSize? = nil
            
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000) // Check every 0.5 seconds
                
                guard !Task.isCancelled else { break }
                
                if let streamVC = _UIKitStreamView.controllerReference.object,
                   let window = streamVC.view.window ?? streamVC.view?.superview?.window {
                    let currentSize = window.bounds.size
                    
                    // Check if size has changed
                    if let lastSize = lastCheckedSize {
                        let widthDiff = abs(currentSize.width - lastSize.width)
                        let heightDiff = abs(currentSize.height - lastSize.height)
                        
                        // If size changed significantly (more than 1 pixel), save it
                        if widthDiff > 1.0 || heightDiff > 1.0 {
                            await MainActor.run {
                                saveWindowSizeToUserDefaults(currentSize)
                            }
                        }
                    } else {
                        // First check, just record the size
                        lastCheckedSize = currentSize
                    }
                }
            }
        }
    }
    
    private func stopWindowSizeMonitoring() {
        windowSizeMonitorTask?.cancel()
        windowSizeMonitorTask = nil
    }
    
    private func restoreWindowSizeIfNeeded() {
        guard viewModel.streamSettings.rememberStreamSettings else { return }
        
        let defaults = UserDefaults.standard
        guard let savedWidth = defaults.object(forKey: "uikitWindowWidth") as? CGFloat,
              let savedHeight = defaults.object(forKey: "uikitWindowHeight") as? CGFloat else {
            return // No saved size
        }
        
        let savedSize = CGSize(width: savedWidth, height: savedHeight)
        print("Restoring UIKit window size: \(savedSize)")
        
        // Try to find the window and restore its size
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let streamVC = _UIKitStreamView.controllerReference.object,
               let window = streamVC.view.window ?? streamVC.view?.superview?.window,
               let windowScene = window.windowScene {
                let geometryRequest = UIWindowScene.GeometryPreferences.Vision(
                    size: savedSize,
                    resizingRestrictions: .uniform
                )
                windowScene.requestGeometryUpdate(geometryRequest)
                print("Applied restored window size")
            }
        }
    }

    private func prepareForBackground() {
        guard !hasPerformedTeardown else { return }
        guard streamConfig != nil else { return }
        
        // Save current window size before backgrounding
        saveCurrentWindowSize()
        
        // Cancel any pending background task
        backgroundTask?.cancel()
        
        // Set needsResume flag
        needsResume = true
        
        // Stop the stream
        if let streamVC = _UIKitStreamView.controllerReference.object {
            streamVC.stopStream()
        }
    }
    
    private func saveCurrentWindowSize() {
        // Try to find the window and save its size
        if let streamVC = _UIKitStreamView.controllerReference.object,
           let window = streamVC.view.window ?? streamVC.view?.superview?.window {
            let currentSize = window.bounds.size
            viewModel.savedStreamWindowSize = currentSize
            print("Saved window size before backgrounding: \(currentSize)")
        }
    }

    private func resumeIfNeeded() {
        guard needsResume else { return }
        guard streamConfig != nil else { return }
        
        // Cancel any pending background task
        backgroundTask?.cancel()
        
        // Only resume if we were actually backgrounded (not just briefly inactive)
        // Add a small delay to ensure we're truly back from background
        backgroundTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second delay
            
            guard !Task.isCancelled else { return }
            guard needsResume else { return }
            
            await MainActor.run {
                needsResume = false
                reloadToken = UUID()
            }
        }
    }
}

struct _UIKitStreamViewWindowButton: View {
    @EnvironmentObject private var viewModel: MainViewModel
    @Binding var streamConfig: StreamConfiguration
    @State private var currentWindow: UIWindow? = nil // State to hold the window reference
    let controllerReference: Reference<StreamFrameViewController> // Receive the reference

    var body: some View {
        Button {
            if let window = currentWindow {
                // When manually triggered, don't use saved size - recalculate
                applyAspectRatioLock(streamConfig: streamConfig, targetWindow: window, useSavedSize: false)
                AudioHelpers.fixAudioForSurroundForUIKitWindow(window) // TODO(shinyquagsire23): Make this configurable
            } else {
                print("Error: No window reference available to apply aspect ratio lock.")
                // Optionally provide user feedback here, e.g., an alert
            }
        } label: {
            Label {
                Text(viewModel.localized("fix_aspect_ratio"))
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
        streamView.connectedCallback = { [weak streamView] in
            print("Connected in Swift!")
            AudioHelpers.fixAudioForSurroundForCurrentWindow() // TODO(shinyquagsire23): Make this configurable
            // Automatically apply aspect ratio lock when stream starts
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard
                    let window = streamView?.view.window ?? streamView?.view?.superview?.window
                else {
                    return
                }
                // Check if we should use saved window size or calculate new size
                let useSavedSize = MainViewModel.shared.streamSettings.rememberStreamSettings
                applyAspectRatioLock(streamConfig: streamConfig, targetWindow: window, useSavedSize: useSavedSize)
            }
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

@MainActor
func applyAspectRatioLock(streamConfig: StreamConfiguration, targetWindow: UIWindow?, useSavedSize: Bool = true) {
    guard let window = targetWindow else {
        print("Error: No target window provided to apply aspect ratio lock.")
        return
    }

    let streamWidth = CGFloat(streamConfig.width)
    let streamHeight = CGFloat(streamConfig.height)
    let streamAspectRatio = streamWidth / streamHeight

    print("Applying Aspect Ratio Lock - Stream Width: \(streamWidth), Stream Height: \(streamHeight), Stream AR: \(streamAspectRatio)")

    var desiredSize = CGSize.zero
    
    // If we have a saved window size and useSavedSize is true, use it
    if useSavedSize {
        // First check MainViewModel's saved size (for background resume)
        if let savedSize = MainViewModel.shared.savedStreamWindowSize {
            let savedAspectRatio = savedSize.width / savedSize.height
            let aspectRatioDifference = abs(savedAspectRatio - streamAspectRatio) / streamAspectRatio
            
            if aspectRatioDifference < 0.05 {
                desiredSize = savedSize
                print("Using saved window size from MainViewModel: \(savedSize)")
                MainViewModel.shared.savedStreamWindowSize = nil
            }
        }
        
        // If no size from MainViewModel, check UserDefaults for persistent saved size
        if desiredSize == .zero {
            let defaults = UserDefaults.standard
            if let savedWidth = defaults.object(forKey: "uikitWindowWidth") as? CGFloat,
               let savedHeight = defaults.object(forKey: "uikitWindowHeight") as? CGFloat {
                let savedSize = CGSize(width: savedWidth, height: savedHeight)
                let savedAspectRatio = savedSize.width / savedSize.height
                let aspectRatioDifference = abs(savedAspectRatio - streamAspectRatio) / streamAspectRatio
                
                if aspectRatioDifference < 0.05 {
                    desiredSize = savedSize
                    print("Using saved window size from UserDefaults: \(savedSize)")
                } else {
                    print("Saved size aspect ratio mismatch, recalculating. Saved AR: \(savedAspectRatio), Stream AR: \(streamAspectRatio)")
                }
            }
        }
    }
    
    // If we don't have a saved size or it doesn't match, calculate new size
    if desiredSize == .zero {
        let maxWidth: CGFloat = 2000 // Increased maxWidth for potentially larger screens
        
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

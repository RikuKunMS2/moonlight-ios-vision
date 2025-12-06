//
//  UIKitStreamView.swift
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/27/24.
//  Copyright © 2024 Moonlight Game Streaming Project.
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
                    .clipShape(RoundedRectangle(cornerRadius: CGFloat(viewModel.streamSettings.uikitWindowCornerRadius), style: .continuous))
                    .preferredSurroundingsEffect(
                        // Apply dimming effect when dimPassthrough is enabled
                        viewModel.streamSettings.dimPassthrough ? .systemDark : nil
                    )
                    .persistentSystemOverlays(viewModel.streamSettings.dimPassthrough ? .hidden : .automatic)
                    .ornament(attachmentAnchor: .scene(.top), contentAlignment: .bottom) {
                        StandardControlPanelView(
                            closeAction: {
                                handleHomeButtonClose()
                            },
                            toggleKeyboardAction: {
                                if let streamVC = _UIKitStreamView.controllerReference.object {
                                    streamVC.toggleKeyboard()
                                }
                            },
                            isKeyboardActive: false,
                            needsHdr: viewModel.streamSettings.enableHdr,
                            isRealityKit: false,
                            windowButtonAction: {
                                if let streamVC = _UIKitStreamView.controllerReference.object,
                                   let window = streamVC.view.window ?? streamVC.view?.superview?.window {
                                    applyAspectRatioLock(streamConfig: configBinding.wrappedValue, targetWindow: window, useSavedSize: false)
                                    AudioHelpers.fixAudioForSurroundForUIKitWindow(window)
                                }
                            }
                        )
                        .environmentObject(viewModel)
                        .padding(.bottom, 20)
                    }
                    .onAppear {
                        hasPerformedTeardown = false
                        
                        // Zombie / Resume Fix:
                        // If we appear but shouldn't be streaming, close immediately.
                        if !viewModel.activelyStreaming {
                            print("[UIKitStreamView] Zombie state detected onAppear. Closing.")
                            // We don't show the "Stream Stopped" error here because the user likely just
                            // restarted the app or came back from a long sleep.
                            openWindow(id: "mainView")
                            
                            // Dismiss after small delay to ensure main view registers
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                dismissWindow(id: "classicStreamingWindow")
                                streamConfig = nil
                            }
                        } else {
                            dismissWindow(id: "mainView")
                            startWindowSizeMonitoring()
                        }
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
                // Stream Stopped / Error UI [PRESERVED]
                // This handles edge cases where the stream dies but the window remains.
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text(viewModel.localized("stream_stopped"))
                        .font(.title2)
                    Text(viewModel.localized("stream_stopped_message"))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button {
                        // Manual Close Button Action
                        openWindow(id: "mainView")
                        dismissWindow(id: "classicStreamingWindow")
                        streamConfig = nil
                    } label: {
                        Label(viewModel.localized("open_main_menu"), systemImage: "house.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.thinMaterial)
                // Ensure we catch zombies here too if they linger
                .onAppear {
                    // Optional: You could add auto-close logic here if you wanted,
                    // but keeping it manual is safer for debugging errors.
                }
            }
        }
    }

    // MARK: - Window Management Logic

    private func handleHomeButtonClose() {
        print("[UIKitStreamView] Home button pressed.")
        
        // 1. Stop Data Stream
        viewModel.activelyStreaming = false
        if let streamVC = _UIKitStreamView.controllerReference.object {
            streamVC.stopStream()
        }
        
        // 2. Open Main Window FIRST (Critical for visionOS window management)
        openWindow(id: "mainView")
        
        // 3. Dismiss THIS window after a short delay
        // This prevents the OS from ignoring the dismiss if it thinks this is the only window.
        // During this 0.5s, the user might briefly see the "Stream Stopped" UI, which is expected behavior.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            dismissWindow(id: "classicStreamingWindow")
            
            // 4. Clear config cleanup
            self.streamConfig = nil
        }
        
        // Save settings if needed
        if viewModel.streamSettings.rememberStreamSettings {
            saveWindowSizeForRestore()
        }
    }

    private func handleWindowDisappearance() {
        // This handles when the user closes the window via the "X" bar or system gesture
        guard !hasPerformedTeardown else { return }
        guard !needsResume else { return }
        
        // If we are disappearing but activelyStreaming is true, it means the user closed the window manually.
        // We should clean up the stream logic.
        if viewModel.activelyStreaming {
            tearDownStream(openMainWindow: true)
        }
    }

    private func tearDownStream(openMainWindow: Bool) {
        guard !hasPerformedTeardown else { return }
        hasPerformedTeardown = true
        needsResume = false

        viewModel.activelyStreaming = false

        if let streamVC = _UIKitStreamView.controllerReference.object {
            streamVC.stopStream()
        }

        if viewModel.streamSettings.rememberStreamSettings {
            saveWindowSizeForRestore()
        }

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
        if let streamVC = _UIKitStreamView.controllerReference.object,
           let window = streamVC.view.window ?? streamVC.view?.superview?.window {
            let currentSize = window.bounds.size
            saveWindowSizeToUserDefaults(currentSize)
        }
    }
    
    private func saveWindowSizeToUserDefaults(_ size: CGSize) {
        guard viewModel.streamSettings.rememberStreamSettings else { return }
        
        if let lastSize = lastSavedWindowSize {
            let widthDiff = abs(size.width - lastSize.width)
            let heightDiff = abs(size.height - lastSize.height)
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
        stopWindowSizeMonitoring()
        guard viewModel.streamSettings.rememberStreamSettings else { return }
        
        windowSizeMonitorTask = Task {
            var lastCheckedSize: CGSize? = nil
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { break }
                
                if let streamVC = _UIKitStreamView.controllerReference.object,
                   let window = streamVC.view.window ?? streamVC.view?.superview?.window {
                    let currentSize = window.bounds.size
                    
                    if let lastSize = lastCheckedSize {
                        let widthDiff = abs(currentSize.width - lastSize.width)
                        let heightDiff = abs(currentSize.height - lastSize.height)
                        
                        if widthDiff > 1.0 || heightDiff > 1.0 {
                            await MainActor.run {
                                saveWindowSizeToUserDefaults(currentSize)
                            }
                        }
                    } else {
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
    
    private func prepareForBackground() {
        guard !hasPerformedTeardown else { return }
        guard streamConfig != nil else { return }
        
        saveCurrentWindowSize()
        backgroundTask?.cancel()
        needsResume = true
        
        if let streamVC = _UIKitStreamView.controllerReference.object {
            streamVC.stopStream()
        }
    }
    
    private func saveCurrentWindowSize() {
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
        
        backgroundTask?.cancel()
        
        backgroundTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            
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
    @State private var currentWindow: UIWindow? = nil
    let controllerReference: Reference<StreamFrameViewController>

    var body: some View {
        Button {
            if let window = currentWindow {
                applyAspectRatioLock(streamConfig: streamConfig, targetWindow: window, useSavedSize: false)
                AudioHelpers.fixAudioForSurroundForUIKitWindow(window)
            } else {
                print("Error: No window reference available to apply aspect ratio lock.")
            }
        } label: {
            Label {
                Text(viewModel.localized("fix_aspect_ratio"))
            } icon: {
                Image(systemName: "aspectratio")
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { findWindow() }
        }
        .onChange(of: streamConfig) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { findWindow() }
        }
    }

    private func findWindow() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }

        if let streamViewController = controllerReference.object {
            if let streamView = streamViewController.view {
                var viewToFindWindow: UIView? = streamView
                while viewToFindWindow != nil {
                    if let window = viewToFindWindow?.window {
                        currentWindow = window
                        AudioHelpers.fixAudioForSurroundForUIKitWindow(window)
                        return
                    }
                    viewToFindWindow = viewToFindWindow?.superview
                }
            }
        }
        currentWindow = nil
    }
}


struct _UIKitStreamView: UIViewControllerRepresentable {
    typealias UIViewControllerType = StreamFrameViewController

    @Binding var streamConfig: StreamConfiguration
    static let controllerReference = Reference<UIViewControllerType>()

    static var reference: Reference<UIViewControllerType> {
        return controllerReference
    }

    func makeUIViewController(context: Context) -> UIViewControllerType {
        let streamView = StreamFrameViewController()
        streamView.streamConfig = streamConfig
        streamView.connectedCallback = { [weak streamView] in
            print("Connected in Swift!")
            AudioHelpers.fixAudioForSurroundForCurrentWindow()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard let window = streamView?.view.window ?? streamView?.view?.superview?.window else { return }
                let useSavedSize = MainViewModel.shared.streamSettings.rememberStreamSettings
                applyAspectRatioLock(streamConfig: streamConfig, targetWindow: window, useSavedSize: useSavedSize)
            }
        };
        streamView.disconnectedCallback = {
            print("Disconnected in Swift!")
        };
        _UIKitStreamView.controllerReference.object = streamView
        return streamView
    }

    func updateUIViewController(_ viewController: UIViewControllerType, context: Context) {
        viewController.streamConfig = streamConfig
        _UIKitStreamView.controllerReference.object = viewController
    }
}

class Reference<T: AnyObject> {
    weak var object: T?
}

// MARK: - Helper Functions

@MainActor
func applyAspectRatioLock(streamConfig: StreamConfiguration, targetWindow: UIWindow?, useSavedSize: Bool = true) {
    guard let window = targetWindow else { return }

    let streamWidth = CGFloat(streamConfig.width)
    let streamHeight = CGFloat(streamConfig.height)
    let streamAspectRatio = streamWidth / streamHeight

    var desiredSize = CGSize.zero
    
    if useSavedSize {
        if let savedSize = MainViewModel.shared.savedStreamWindowSize {
            let savedAspectRatio = savedSize.width / savedSize.height
            let aspectRatioDifference = abs(savedAspectRatio - streamAspectRatio) / streamAspectRatio
            
            if aspectRatioDifference < 0.05 {
                desiredSize = savedSize
                MainViewModel.shared.savedStreamWindowSize = nil
            }
        }
        
        if desiredSize == .zero {
            let defaults = UserDefaults.standard
            if let savedWidth = defaults.object(forKey: "uikitWindowWidth") as? CGFloat,
               let savedHeight = defaults.object(forKey: "uikitWindowHeight") as? CGFloat {
                let savedSize = CGSize(width: savedWidth, height: savedHeight)
                let savedAspectRatio = savedSize.width / savedSize.height
                let aspectRatioDifference = abs(savedAspectRatio - streamAspectRatio) / streamAspectRatio
                
                if aspectRatioDifference < 0.05 {
                    desiredSize = savedSize
                }
            }
        }
    }
    
    if desiredSize == .zero {
        let maxWidth: CGFloat = 2000
        for desiredWidthInt in (1...Int(maxWidth)).reversed() {
            let desiredWidth = CGFloat(desiredWidthInt)
            let desiredHeightFloat = desiredWidth / streamAspectRatio
            let desiredHeightInt = Int(round(desiredHeightFloat))

            if desiredHeightInt > 0 {
                desiredSize = CGSize(width: desiredWidth, height: CGFloat(desiredHeightInt))
                break
            }
        }
    }

    guard let windowScene = window.windowScene else { return }

    let geometryRequest = UIWindowScene.GeometryPreferences.Vision(
        size: desiredSize,
        resizingRestrictions: .uniform
    )

    windowScene.requestGeometryUpdate(geometryRequest)
}

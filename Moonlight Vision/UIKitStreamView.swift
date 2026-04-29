//
//  UIKitStreamView.swift
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/27/24.
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

struct UIKitStreamView: View {
    @Binding var streamConfig: StreamConfiguration?

    @EnvironmentObject private var viewModel: MainViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var hasPerformedTeardown = false
    @State private var needsResume = false
    @State private var reloadToken = UUID()
    @State private var backgroundTask: Task<Void, Never>?
    @State private var windowSizeMonitorTask: Task<Void, Never>? = nil
    @State private var lastSavedWindowSize: CGSize? = nil
    @State private var lastStreamErrorMessage: String? = nil
    @State private var uikitReconnectAttemptCount: Int = 0
    @State private var isUIKitReconnecting: Bool = false
    @State private var uikitStatsOverlayText: String = ""
    @State private var isKeyboardActive: Bool = false
    @State private var showCenterHint: Bool = false
    @State private var centerHintText: String = ""
    @State private var centerHintIcon: String = "info.circle"
    @State private var centerHintTask: Task<Void, Never>?
    private let uikitMaxReconnectAttempts = 3
    private let uikitReconnectDelaySeconds: TimeInterval = 2.5

    var body: some View {
        Group {
            if viewModel.activelyStreaming,
               let configBinding = Binding($streamConfig) {
                _UIKitStreamView(streamConfig: configBinding)
                    .id(reloadToken)
                    .onAppear { lastStreamErrorMessage = nil }
                    .clipShape(RoundedRectangle(cornerRadius: CGFloat(viewModel.streamSettings.uikitWindowCornerRadius), style: .continuous))
                    .preferredSurroundingsEffect(
                        // Apply dimming effect when dimPassthrough is enabled
                        viewModel.streamSettings.dimPassthrough ? .systemDark : nil
                    )
                    .persistentSystemOverlays(viewModel.streamSettings.dimPassthrough ? .hidden : .automatic)
                    .overlay {
                        if isUIKitReconnecting {
                            uikitReconnectingOverlay
                        }
                        if showCenterHint {
                            CenterHintOverlay(
                                text: centerHintText,
                                icon: centerHintIcon
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .center)))
                            .animation(.easeOut(duration: 0.25), value: showCenterHint)
                            .allowsHitTesting(false)
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("UIKitStatsOverlayTextUpdated"))) { notification in
                        uikitStatsOverlayText = notification.userInfo?["text"] as? String ?? ""
                    }
                    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("UIKitKeyboardActiveChanged"))) { notification in
                        let active = (notification.userInfo?["active"] as? Bool) ?? false
                        isKeyboardActive = active
                        centerHintTask?.cancel()
                        if active {
                            centerHintText = viewModel.localized("uikit_keyboard_hint")
                            centerHintIcon = "hand.tap.fill"
                            showCenterHint = true
                            centerHintTask = Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        showCenterHint = false
                                    }
                                }
                            }
                        } else {
                            showCenterHint = false
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("UIKitInputModeHintRequested"))) { notification in
                        guard let text = notification.userInfo?["text"] as? String,
                              let icon = notification.userInfo?["icon"] as? String else { return }
                        centerHintTask?.cancel()
                        centerHintText = text
                        centerHintIcon = icon
                        showCenterHint = true
                        centerHintTask = Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                withAnimation(.easeOut(duration: 0.25)) {
                                    showCenterHint = false
                                }
                            }
                        }
                    }
                    .ornament(attachmentAnchor: .scene(.top), contentAlignment: .bottom) {
                        VStack(spacing: 12) {
                            StandardControlPanelView(
                            homeAction: { 
                                viewModel.isHidingForResume = true
                                viewModel.savedStreamConfigForResume = configBinding.wrappedValue
                                openWindow(id: "mainView")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    dismissWindow(id: "classicStreamingWindow")
                                }
                            },
                            closeAction: { handleHomeButtonClose() },
                            toggleKeyboardAction: {
                                if let streamVC = _UIKitStreamView.controllerReference.object {
                                    streamVC.toggleKeyboard()
                                }
                            },
                            isKeyboardActive: isKeyboardActive,
                            toggleInputModeAction: {
                                if let streamVC = _UIKitStreamView.controllerReference.object {
                                    streamVC.setAbsoluteTouchMode(viewModel.streamSettings.absoluteTouchMode)
                                    let text = viewModel.streamSettings.absoluteTouchMode
                                        ? viewModel.localized("input_mode_gaze_input")
                                        : viewModel.localized("input_mode_trackpad")
                                    let icon = viewModel.streamSettings.absoluteTouchMode ? "eye.fill" : "rectangle"
                                    NotificationCenter.default.post(
                                        name: Notification.Name("UIKitInputModeHintRequested"),
                                        object: nil,
                                        userInfo: ["text": text, "icon": icon]
                                    )
                                }
                            },
                            needsHdr: viewModel.streamSettings.enableHdr,
                            isRealityKit: false,
                            windowButtonAction: {
                                if let streamVC = _UIKitStreamView.controllerReference.object,
                                   let window = streamVC.view.window ?? streamVC.view?.superview?.window {
                                    applyAspectRatioLock(streamConfig: configBinding.wrappedValue, targetWindow: window, useSavedSize: false)
                                    let currentMode = SpatialAudioMode(rawValue: viewModel.streamSettings.spatialAudioMode) ?? .window
                                    AudioHelpers.applySpatialAudioMode(currentMode, window: window)
                                }
                            }
                        )
                        .environmentObject(viewModel)
                            if viewModel.streamSettings.statsOverlay {
                                uikitStatsOverlay
                                    .layoutPriority(1)
                            }
                        }
                        .padding(.top, 20)
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
                    .onChange(of: viewModel.shouldCloseStream) { _, val in
                        if val { handleCloseFromViewModel() }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("RequestStreamCloseFromMainMenu"))) { _ in
                        handleCloseFromViewModel()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ResumeStreamFromMenu"))) { _ in
                        dismissWindow(id: "mainView")
                        let currentMode = SpatialAudioMode(rawValue: viewModel.streamSettings.spatialAudioMode) ?? .window
                        AudioHelpers.applySpatialAudioMode(currentMode)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MainViewWindowClosed"))) { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            let currentMode = SpatialAudioMode(rawValue: MainViewModel.shared.streamSettings.spatialAudioMode) ?? .window
                            AudioHelpers.applySpatialAudioMode(currentMode)
                        }
                    }
            } else {
                // Stream Stopped / Error UI [PRESERVED]
                ZStack {
                    VStack(spacing: 20) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                        Text(viewModel.localized("stream_stopped"))
                            .font(.title2)
                        Text(viewModel.localized("stream_stopped_message"))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        Button {
                            lastStreamErrorMessage = nil
                            viewModel.streamState = .stopping
                            viewModel.savedStreamConfigForResume = nil
                            openWindow(id: "mainView")
                            dismissWindow(id: "classicStreamingWindow")
                            streamConfig = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                NotificationCenter.default.post(name: Notification.Name("StreamDidTeardownNotification"), object: nil)
                            }
                        } label: {
                            Label(viewModel.localized("open_main_menu"), systemImage: "house.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.thinMaterial)
                    
                    if let errorMsg = lastStreamErrorMessage {
                        uikitErrorOverlay(message: errorMsg)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("UIKitStreamErrorNotification"))) { notification in
            if let msg = notification.userInfo?["message"] as? String {
                lastStreamErrorMessage = msg
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("UIKitConnectionTerminatedForRetry"))) { notification in
            DispatchQueue.main.async { handleUIKitConnectionTerminatedForRetry(notification: notification) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("StreamFirstFrameShownNotification"))) { _ in
            if uikitReconnectAttemptCount > 0 {
                uikitReconnectAttemptCount = 0
                isUIKitReconnecting = false
                _UIKitStreamView.controllerReference.object?.uikitReconnectingForRetry = false
            }
        }
    }
    
    private func handleUIKitConnectionTerminatedForRetry(notification: Notification) {
        guard viewModel.activelyStreaming else { return }
        let msg = (notification.userInfo?["message"] as? String) ?? viewModel.localized("unknown_error")
        
        if uikitReconnectAttemptCount < uikitMaxReconnectAttempts {
            let configToUse = self.streamConfig
            Task {
                var isOnline = false
                if let config = configToUse, let hostAddress = config.host,
                   let host = viewModel.hosts.first(where: { $0.activeAddress == hostAddress || $0.address == hostAddress || $0.localAddress == hostAddress || $0.externalAddress == hostAddress }) {
                    let httpManager = HttpManager(host: host)
                    let serverInfoResponse = ServerInfoResponse()
                    let request = HttpRequest(
                        for: serverInfoResponse,
                        with: httpManager?.newServerInfoRequest(false),
                        fallbackError: 401,
                        fallbackRequest: httpManager?.newHttpServerInfoRequest()
                    )
                    
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        DispatchQueue.global(qos: .userInitiated).async {
                            httpManager?.executeRequestSynchronously(request)
                            continuation.resume()
                        }
                    }
                    isOnline = serverInfoResponse.isStatusOk()
                } else {
                    isOnline = true
                }
                
                await MainActor.run {
                    guard self.viewModel.activelyStreaming else { return }
                    if isOnline {
                        self.uikitReconnectAttemptCount += 1
                        self.isUIKitReconnecting = true
                        let streamVC = _UIKitStreamView.controllerReference.object
                        streamVC?.uikitReconnectingForRetry = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + self.uikitReconnectDelaySeconds) {
                            guard self.viewModel.activelyStreaming else {
                                self.isUIKitReconnecting = false
                                _UIKitStreamView.controllerReference.object?.uikitReconnectingForRetry = false
                                return
                            }
                            NotificationCenter.default.post(name: Notification.Name("UIKitRequestStreamRestart"), object: nil)
                        }
                    } else {
                        self.uikitReconnectAttemptCount = 0
                        self.isUIKitReconnecting = false
                        _UIKitStreamView.controllerReference.object?.uikitReconnectingForRetry = false
                        self.lastStreamErrorMessage = msg
                        _UIKitStreamView.controllerReference.object?.stopStream()
                        NotificationCenter.default.post(name: Notification.Name("UIKitRetriesExhausted"), object: nil)
                    }
                }
            }
        } else {
            uikitReconnectAttemptCount = 0
            isUIKitReconnecting = false
            _UIKitStreamView.controllerReference.object?.uikitReconnectingForRetry = false
            lastStreamErrorMessage = msg
            _UIKitStreamView.controllerReference.object?.stopStream()
            NotificationCenter.default.post(name: Notification.Name("UIKitRetriesExhausted"), object: nil)
        }
    }
    
    @ViewBuilder
    private func uikitErrorOverlay(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.32))
            Text(viewModel.localized("stream_error"))
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                lastStreamErrorMessage = nil
                viewModel.savedStreamConfigForResume = nil
                openWindow(id: "mainView")
                dismissWindow(id: "classicStreamingWindow")
                streamConfig = nil
                viewModel.streamState = .stopping
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(name: Notification.Name("StreamDidTeardownNotification"), object: nil)
                }
            } label: {
                Label(viewModel.localized("open_main_menu"), systemImage: "house.fill")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .padding(20)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    
    @ViewBuilder
    private var uikitReconnectingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(.white)
            Text(viewModel.localized("reconnecting"))
                .font(.headline)
                .foregroundStyle(.white)
            Text(String(format: viewModel.localized("reconnect_attempt"), uikitReconnectAttemptCount, uikitMaxReconnectAttempts))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.6))
    }
    
    /// Stats panel - RealityKit style, in ornament layer below control panel, never on screen content
    /// fixedSize(vertical: true) prevents compression when control panel collapses
    @ViewBuilder
    private var uikitStatsOverlay: some View {
        VStack(spacing: 6) {
            Text(uikitStatsOverlayText.isEmpty ? "Collecting stats..." : uikitStatsOverlayText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(10)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .allowsHitTesting(false)
    }

    // MARK: - Window Management Logic

    private func handleHomeButtonClose() {
        print("[UIKitStreamView] Home button pressed.")
        performUIKitTeardown()
    }

    private func handleCloseFromViewModel() {
        performUIKitTeardown()
    }

    private func performUIKitTeardown() {
        guard !hasPerformedTeardown else { return }
        hasPerformedTeardown = true
        needsResume = false

        let wasHidingForResume = viewModel.isHidingForResume
        let isCurrentSession = (viewModel.currentStreamConfig.sessionUUID == streamConfig?.sessionUUID)
        if isCurrentSession {
            if wasHidingForResume {
                viewModel.isHidingForResume = false
            } else {
                viewModel.streamState = .stopping
                viewModel.activelyStreaming = false
            }
        }

        if let streamVC = _UIKitStreamView.controllerReference.object {
            streamVC.stopStream()
        }

        if viewModel.streamSettings.rememberStreamSettings {
            saveWindowSizeForRestore()
        }

        if !wasHidingForResume {
            viewModel.savedStreamConfigForResume = nil
        }

        streamConfig = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            dismissWindow(id: "classicStreamingWindow")
            NotificationCenter.default.post(name: Notification.Name("StreamDidTeardownNotification"), object: nil)
        }
    }

    private func handleWindowDisappearance() {
        // This handles when the user closes the window via the "X" bar or system gesture
        guard !hasPerformedTeardown else { return }

        // If we are disappearing but activelyStreaming is true, it means the user closed the window manually.
        // We should clean up the stream logic.
        if viewModel.activelyStreaming {
            performUIKitTeardown()
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
            guard !Task.isCancelled else { return }
            guard needsResume else { return }
            
            await MainActor.run {
                needsResume = false
                if let streamVC = _UIKitStreamView.controllerReference.object {
                    streamVC.streamConfig = streamConfig
                    streamVC.startStream()
                } else {
                    reloadToken = UUID()
                }
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
                let currentMode = SpatialAudioMode(rawValue: viewModel.streamSettings.spatialAudioMode) ?? .window
                AudioHelpers.applySpatialAudioMode(currentMode, window: window)
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
                        let currentMode = SpatialAudioMode(rawValue: viewModel.streamSettings.spatialAudioMode) ?? .window
                        AudioHelpers.applySpatialAudioMode(currentMode, window: window)
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
            let currentMode = SpatialAudioMode(rawValue: MainViewModel.shared.streamSettings.spatialAudioMode) ?? .window
            AudioHelpers.applySpatialAudioMode(currentMode)
            
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

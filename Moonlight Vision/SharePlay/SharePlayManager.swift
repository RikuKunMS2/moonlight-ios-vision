//
//  SharePlayManager.swift
//  Moonlight Vision
//
//  Created by Lumanaire (RikuKunMS2).
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation
import GroupActivities
import SwiftUI

struct StreamTransformMessage: Codable {
    var scale: Float
    var positionX: Float
    var positionY: Float
    var positionZ: Float
    var curvature: Float
    var tiltAngle: Float
}

@MainActor
class SharePlayManager: ObservableObject {
    static let shared = SharePlayManager()
    
    @Published var session: GroupSession<MoonlightStreamActivity>?
    private var messenger: GroupSessionMessenger?
    private var tasks = Set<Task<Void, Never>>()
    private var isReceivingTransform = false
    
    init() {
        Task {
            await startObservingSessions()
        }
    }
    
    func startSharePlay() {
        Task {
            do {
                _ = try await MoonlightStreamActivity().activate()
            } catch {
                print("Failed to activate SharePlay activity: \(error)")
            }
        }
    }
    
    private func startObservingSessions() async {
        for await session in MoonlightStreamActivity.sessions() {
            self.session = session
            await configureSystemCoordinator(for: session)
            let messenger = GroupSessionMessenger(session: session)
            self.messenger = messenger
            
            // Cancel and clear old tasks before starting new ones for the new session
            for task in tasks {
                task.cancel()
            }
            tasks.removeAll()
            
            let messageTask = Task {
                for await (message, _) in messenger.messages(of: StreamTransformMessage.self) {
                    self.handleTransformMessage(message)
                }
            }
            tasks.insert(messageTask)
            
            session.join()
            
            // Observe session state changes
            let task = Task {
                for await state in session.$state.values {
                    if case .invalidated = state {
                        self.session = nil
                        self.messenger = nil
                        // Clean up tasks to prevent memory leaks
                        for task in self.tasks {
                            task.cancel()
                        }
                        self.tasks.removeAll()
                        break
                    }
                }
            }
            tasks.insert(task)
        }
    }
    
    private func configureSystemCoordinator(for session: GroupSession<MoonlightStreamActivity>) async {
        #if os(visionOS)
        if #available(visionOS 1.0, *) {
            if let systemCoordinator = await session.systemCoordinator {
                var configuration = SystemCoordinator.Configuration()
                configuration.spatialTemplatePreference = .sideBySide
                configuration.supportsGroupImmersiveSpace = true
                systemCoordinator.configuration = configuration
            }
        }
        #endif
    }
    
    func broadcastTransform(scale: Float, positionX: Float, positionY: Float, positionZ: Float, curvature: Float, tiltAngle: Float) {
        guard let messenger = messenger else { return }
        let message = StreamTransformMessage(scale: scale, positionX: positionX, positionY: positionY, positionZ: positionZ, curvature: curvature, tiltAngle: tiltAngle)
        Task {
            do {
                try await messenger.send(message)
            } catch {
                print("Failed to send transform message: \(error)")
            }
        }
    }
    
    func broadcastCurrentTransform() {
        guard messenger != nil, !isReceivingTransform else { return }
        broadcastTransform(
            scale: StreamControlState.shared.immersiveScale,
            positionX: StreamControlState.shared.immersivePositionX,
            positionY: StreamControlState.shared.immersivePositionY,
            positionZ: StreamControlState.shared.immersivePositionZ,
            curvature: MainViewModel.shared.streamSettings.realitykitRendererCurvature,
            tiltAngle: StreamControlState.shared.tiltAngle
        )
    }
    
    private func handleTransformMessage(_ message: StreamTransformMessage) {
        isReceivingTransform = true
        StreamControlState.shared.immersiveScale = message.scale
        StreamControlState.shared.immersivePositionX = message.positionX
        StreamControlState.shared.immersivePositionY = message.positionY
        StreamControlState.shared.immersivePositionZ = message.positionZ
        StreamControlState.shared.tiltAngle = message.tiltAngle
        MainViewModel.shared.streamSettings.realitykitRendererCurvature = message.curvature
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.isReceivingTransform = false
        }
    }
}

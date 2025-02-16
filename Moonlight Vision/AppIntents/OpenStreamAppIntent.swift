//
//  OpenStreamAppIntent.swift
//  Moonlight
//
//  Created by tht7 on 06/02/2025.
//  Copyright © 2025 Moonlight Game Streaming Project. All rights reserved.
//
import AppIntents

@MainActor
struct OpenMoonlightApp: AppIntent {
    
    public static var openAppWhenRun: Bool = true
    
    @Parameter(title: "Host")
    var host: TemporaryHost
    
    @Parameter(title: "Steamed App")
    var app: TemporaryApp
    
    @Parameter(title: "Renderer")
    var renderer: Renderer

    static var title: LocalizedStringResource = "Start streaming app"


    @MainActor
    func perform() async throws -> some IntentResult {
        app.setHost(host)
        let config = MainViewModel.shared.stream(app: app)
        let activity = NSUserActivity(activityType: "dummy")
//        activity.userInfo = ["some key": config!]
        activity.targetContentIdentifier = "dummy" // IMPORTANT
        try! activity.setTypedPayload(config!)
        MainViewModel.shared.streamSettings.renderer = self.renderer
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity, options: nil)
        print("perform intent")
        return .result()
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Stream from \(\.$host), stream app \(\.$app) with renderer \(\.$renderer)")
    }
  
    init() {
        self.renderer = MainViewModel.shared.streamSettings.renderer
    }

    init(app: TemporaryApp) {
        self.renderer = MainViewModel.shared.streamSettings.renderer
        self.app = app
    }
}

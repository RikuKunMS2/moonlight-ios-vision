//
//  OpenStreamAppIntent.swift
//  Moonlight Vision
//
//  Created by tht7 on 06/02/2025.
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Moonlight
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import AppIntents

@MainActor
struct OpenMoonlightApp: AppIntent {
    
    public static var openAppWhenRun: Bool = true
    
    @Parameter(title: "Host")
    var host: TemporaryHost
    
    @Parameter(title: "Steamed App")
    var app: TemporaryApp
    

    static var title: LocalizedStringResource = "Start streaming app"


    @MainActor
    func perform() async throws -> some IntentResult {
        app.setHost(host)
        let config = MainViewModel.shared.stream(app: app)
        let activity = NSUserActivity(activityType: "dummy")
//        activity.userInfo = ["some key": config!]
        activity.targetContentIdentifier = "dummy" // IMPORTANT
        try! activity.setTypedPayload(config!)
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity, options: nil)
        print("perform intent")
        return .result()
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Stream from \(\.$host), stream app \(\.$app)")
    }
  
    init() {
    }

    init(app: TemporaryApp) {
        self.app = app
    }
}

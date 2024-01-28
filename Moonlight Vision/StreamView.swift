//
//  StreamView.swift
//  Moonlight Vision
//
//  Created by Alex Haugland on 1/27/24.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

struct StreamView: UIViewControllerRepresentable {
    typealias UIViewControllerType = StreamFrameViewController
    
    @Binding var streamConfig: StreamConfiguration
    
    let controllerReference = Reference<UIViewControllerType>()
    
    
    func makeUIViewController(context: Context) -> UIViewControllerType {
        let streamView = StreamFrameViewController()
        streamView.streamConfig = streamConfig
        controllerReference.object = streamView
        return streamView
    }
    
    func updateUIViewController(_ viewController: UIViewControllerType, context: Context) {
        controllerReference.object = viewController
    }
}

class Reference<T: AnyObject> {
    weak var object: T?
}

//#Preview {
//    StreamView(streamConfig: StreamConfiguration())
//}

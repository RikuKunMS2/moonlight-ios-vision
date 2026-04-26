//
//  VelocitySlider.swift
//  Moonlight Vision
//
//  Created by Lumanaire (RikuKunMS2).
//  Updated by Lumanaire (RikuKunMS2) on 4/26/26.
//  Notice: If you are missing from the contributor list, please contact Lumanaire (RikuKunMS2).
//
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

struct VelocitySlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let defaultValue: Float
    let format: String
    var multiplier: Float = 1
    var disabled: Bool = false
    let step: Float
    
    @State private var isDragging: Bool = false
    @State private var dragOffset: CGFloat = 0
    @State private var accumulatedTime: TimeInterval = 0
    @State private var lastUpdateTime: TimeInterval = 0
    
    private let maxDragDistance: CGFloat = 100.0
    private let maxUnitsPerSecond: Float = 0.02
    
    var body: some View {
        GridRow {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
                .padding(.trailing, 8)
            
            HStack(spacing: 8) {
                // Custom Velocity Track
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Track background
                        Capsule()
                            .fill(Color.white.opacity(0.2))
                            .frame(height: 6)
                        
                        // Active portion based on actual value (just for visual reference)
                        let percent = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                        Capsule()
                            .fill(Color.white.opacity(0.6))
                            .frame(width: max(0, percent * geo.size.width), height: 6)
                        
                        // The joystick thumb
                        Circle()
                            .fill(Color.white)
                            .frame(width: 24, height: 24)
                            // Position thumb based on current value, but offset it visually when dragging
                            .offset(x: max(0, min(geo.size.width - 24, percent * (geo.size.width - 24))) + dragOffset)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { gesture in
                                        if disabled { return }
                                        if !isDragging {
                                            isDragging = true
                                            lastUpdateTime = Date().timeIntervalSince1970
                                        }
                                        // Constrain visual drag
                                        dragOffset = max(-maxDragDistance, min(maxDragDistance, gesture.translation.width))
                                    }
                                    .onEnded { _ in
                                        isDragging = false
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                            dragOffset = 0
                                        }
                                    }
                            )
                    }
                    .frame(height: 24) // Thumb size
                }
                .frame(height: 24)
                
                // Restore default value button
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        value = defaultValue
                    }
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .disabled(disabled || abs(value - defaultValue) < step * 0.5)
                .opacity((disabled || abs(value - defaultValue) < step * 0.5) ? 0.3 : 1.0)
            }
            
            Text(String(format: format, value * multiplier))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
                .frame(width: 60, alignment: .trailing)
        }
        .opacity(disabled ? 0.5 : 1.0)
        // Timer for velocity updates
        .onReceive(Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()) { _ in
            guard isDragging, abs(dragOffset) > 2 else { return }
            
            let currentTime = Date().timeIntervalSince1970
            let dt = currentTime - lastUpdateTime
            lastUpdateTime = currentTime
            
            // Calculate speed factor from 0.0 to 1.0
            let speedFactor = Float(abs(dragOffset) / maxDragDistance)
            let direction: Float = dragOffset > 0 ? 1.0 : -1.0
            
            // maxUnitsPerSecond is 0.10
            let unitsThisFrame = maxUnitsPerSecond * speedFactor * Float(dt)
            
            // Accumulate units until we hit the "step" threshold (0.01)
            accumulatedTime += TimeInterval(unitsThisFrame)
            
            let stepDouble = TimeInterval(step)
            if abs(accumulatedTime) >= stepDouble {
                let stepsToApply = Int(abs(accumulatedTime) / stepDouble)
                let change = Float(stepsToApply) * step * direction
                
                let newValue = min(max(value + change, range.lowerBound), range.upperBound)
                if value != newValue {
                    value = newValue
                }
                
                // Keep remainder
                if accumulatedTime > 0 {
                    accumulatedTime -= Double(stepsToApply) * stepDouble
                } else {
                    accumulatedTime += Double(stepsToApply) * stepDouble
                }
            }
        }
    }
}

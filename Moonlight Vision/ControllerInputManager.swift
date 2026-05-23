//
//  ControllerInputManager.swift
//  Moonlight Vision
//
//  Maps gamepad joystick/triggers/buttons to mouse movement/buttons for controller mouse mode.
//

import GameController
import SwiftUI

final class ControllerInputManager: ObservableObject {
    @Published var mouseSpeed: Int = 1  // 0=slow, 1=medium, 2=fast
    @Published var isActive: Bool = false
    var isControlPanelOpen: Bool = false

    private var displayLink: CADisplayLink?
    // Proxy breaks the CADisplayLink → self retain cycle.
    // CADisplayLink retains the proxy strongly; the proxy only has a weak
    // reference back to self, so self can deallocate even while the link runs.
    private var linkProxy: DisplayLinkProxy?
    private var mouseButtonState: UInt8 = 0
    // Mouse button action constants matching Limelight.h defines
    private let buttonActionPress: Int8 = 0x07   // BUTTON_ACTION_PRESS
    private let buttonActionRelease: Int8 = 0x08 // BUTTON_ACTION_RELEASE
    private let buttonLeft: Int32 = 0x01         // BUTTON_LEFT
    private let buttonRight: Int32 = 0x03        // BUTTON_RIGHT

    private var leftTriggerWasPressed: Bool = false
    private var rightTriggerWasPressed: Bool = false
    private var leftShoulderWasPressed: Bool = false
    private var rightShoulderWasPressed: Bool = false
    private var buttonAWasPressed: Bool = false
    private var buttonBWasPressed: Bool = false

    // Long-press detection for opening control panel
    private var longPressTimer: Timer?
    private var longPressActive: Bool = false
    private let longPressDuration: TimeInterval = 0.65

    private let speedMultipliers: [Float] = [0.5, 1.0, 2.0]

    init() {
        setupControllerObservers()
    }

    deinit {
        displayLink?.invalidate()
        displayLink = nil
        resetMouseButtons()
        longPressTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func start() {
        guard !isActive else { return }
        // Defensive: invalidate any stale display link that wasn't properly cleaned up.
        displayLink?.invalidate()
        isActive = true
        let proxy = DisplayLinkProxy(target: self)
        linkProxy = proxy
        displayLink = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        displayLink?.add(to: .main, forMode: .default)
    }

    func stop() {
        isActive = false
        displayLink?.invalidate()
        displayLink = nil
        linkProxy = nil
        resetMouseButtons()
        longPressTimer?.invalidate()
        longPressTimer = nil
    }

    func cycleSpeed() {
        mouseSpeed = (mouseSpeed + 1) % 3
    }

    // MARK: - Controller observers

    private func setupControllerObservers() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(controllerDidConnect),
            name: .GCControllerDidConnect, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(controllerDidDisconnect),
            name: .GCControllerDidDisconnect, object: nil
        )
        for controller in GCController.controllers() {
            setupLongPress(for: controller)
        }
    }

    @objc private func controllerDidConnect(_ note: Notification) {
        if let controller = note.object as? GCController {
            setupLongPress(for: controller)
        }
    }

    @objc private func controllerDidDisconnect(_ note: Notification) {
        longPressTimer?.invalidate()
        longPressTimer = nil
        longPressActive = false
        if GCController.controllers().isEmpty {
            stop()
        }
    }

    private func setupLongPress(for controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        gamepad.buttonOptions?.valueChangedHandler = { [weak self] (_, _, pressed) in
            guard let self else { return }
            if pressed && !self.longPressActive {
                self.longPressActive = true
                self.longPressTimer?.invalidate()
                self.longPressTimer = Timer.scheduledTimer(withTimeInterval: self.longPressDuration, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    if self.longPressActive {
                        NotificationCenter.default.post(
                            name: Notification.Name("ToggleControlPanel"),
                            object: nil
                        )
                    }
                    self.longPressActive = false
                }
            } else if !pressed {
                self.longPressActive = false
                self.longPressTimer?.invalidate()
                self.longPressTimer = nil
            }
        }
    }

    // MARK: - Per-frame tick

    fileprivate func tick() {
        guard isActive, let gamepad = GCController.controllers().first?.extendedGamepad else { return }

        let speed = speedMultipliers[mouseSpeed]

        // Joystick → mouse movement
        let leftX = gamepad.leftThumbstick.xAxis.value
        let leftY = gamepad.leftThumbstick.yAxis.value
        let rightX = gamepad.rightThumbstick.xAxis.value
        let rightY = gamepad.rightThumbstick.yAxis.value

        let combinedX = leftX + rightX
        let combinedY = leftY + rightY

        let baseRate: Float = 12.0
        let deltaX = Int16(combinedX * baseRate * speed)
        let deltaY = Int16(-combinedY * baseRate * speed)

        if deltaX != 0 || deltaY != 0 {
            LiSendMouseMoveEvent(deltaX, deltaY)
            NotificationCenter.default.post(name: Notification.Name("HardwareInputDetected"), object: nil)
        }

        // LT (leftTrigger) → left mouse button
        // RT (rightTrigger) → left mouse button
        handleTriggerButton(
            pressed: gamepad.leftTrigger.value > 0.15,
            wasPressed: &leftTriggerWasPressed,
            button: buttonLeft
        )
        handleTriggerButton(
            pressed: gamepad.rightTrigger.value > 0.15,
            wasPressed: &rightTriggerWasPressed,
            button: buttonLeft
        )

        // LB (leftShoulder) → right mouse button
        handleDigitalButton(
            pressed: gamepad.leftShoulder.isPressed,
            wasPressed: &leftShoulderWasPressed,
            button: buttonRight
        )

        // RB (rightShoulder) → right mouse button
        handleDigitalButton(
            pressed: gamepad.rightShoulder.isPressed,
            wasPressed: &rightShoulderWasPressed,
            button: buttonRight
        )

        // A button → left mouse button (only when control panel is NOT open)
        if !isControlPanelOpen {
            handleDigitalButton(
                pressed: gamepad.buttonA.isPressed,
                wasPressed: &buttonAWasPressed,
                button: buttonLeft
            )
        } else if buttonAWasPressed {
            // Release A-button mouse click if panel was opened while held
            LiSendMouseButtonEvent(buttonActionRelease, buttonLeft)
            buttonAWasPressed = false
        }

        // B button → right mouse button
        handleDigitalButton(
            pressed: gamepad.buttonB.isPressed,
            wasPressed: &buttonBWasPressed,
            button: buttonRight
        )

        // Defensively clear the gamepad-level handler every frame so
        // ControllerSupport can't sneak gamepad events to the host
        // if it re-registers its handler via a notification path.
        if gamepad.valueChangedHandler != nil {
            gamepad.valueChangedHandler = nil
        }
    }

    private func handleTriggerButton(pressed: Bool, wasPressed: inout Bool, button: Int32) {
        if pressed != wasPressed {
            if pressed {
                LiSendMouseButtonEvent(buttonActionPress, button)
            } else {
                LiSendMouseButtonEvent(buttonActionRelease, button)
            }
            wasPressed = pressed
            NotificationCenter.default.post(name: Notification.Name("HardwareInputDetected"), object: nil)
        }
    }

    private func handleDigitalButton(pressed: Bool, wasPressed: inout Bool, button: Int32) {
        if pressed != wasPressed {
            if pressed {
                LiSendMouseButtonEvent(buttonActionPress, button)
            } else {
                LiSendMouseButtonEvent(buttonActionRelease, button)
            }
            wasPressed = pressed
            NotificationCenter.default.post(name: Notification.Name("HardwareInputDetected"), object: nil)
        }
    }

    private func resetMouseButtons() {
        if leftTriggerWasPressed {
            LiSendMouseButtonEvent(buttonActionRelease, buttonLeft)
            leftTriggerWasPressed = false
        }
        if rightTriggerWasPressed {
            LiSendMouseButtonEvent(buttonActionRelease, buttonLeft)
            rightTriggerWasPressed = false
        }
        if leftShoulderWasPressed {
            LiSendMouseButtonEvent(buttonActionRelease, buttonRight)
            leftShoulderWasPressed = false
        }
        if rightShoulderWasPressed {
            LiSendMouseButtonEvent(buttonActionRelease, buttonRight)
            rightShoulderWasPressed = false
        }
        if buttonAWasPressed {
            LiSendMouseButtonEvent(buttonActionRelease, buttonLeft)
            buttonAWasPressed = false
        }
        if buttonBWasPressed {
            LiSendMouseButtonEvent(buttonActionRelease, buttonRight)
            buttonBWasPressed = false
        }
    }
}

// MARK: - CADisplayLink proxy (breaks retain cycle)

private final class DisplayLinkProxy {
    weak var target: ControllerInputManager?
    init(target: ControllerInputManager) {
        self.target = target
    }
    @objc func tick() {
        target?.tick()
    }
}

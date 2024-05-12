# Moonlight iOS/tvOS

[![AppVeyor Build Status](https://ci.appveyor.com/api/projects/status/kwv8vpwr457lqn25/branch/master?svg=true)](https://ci.appveyor.com/project/cgutman/moonlight-ios/branch/master)

[Moonlight for iOS/tvOS](https://moonlight-stream.org) is an open source client for [Sunshine](https://github.com/LizardByte/Sunshine) and NVIDIA GameStream. Moonlight for iOS/tvOS allows you to stream your full collection of games and apps from your powerful desktop computer to your iOS device or Apple TV.

Moonlight also has a [PC client](https://github.com/moonlight-stream/moonlight-qt) and [Android client](https://github.com/moonlight-stream/moonlight-android).

Check out [the Moonlight wiki](https://github.com/moonlight-stream/moonlight-docs/wiki) for more detailed project information, setup guide, or troubleshooting steps.

[![Moonlight for iOS and tvOS](https://moonlight-stream.org/images/App_Store_Badge_135x40.svg)](https://apps.apple.com/us/app/moonlight-game-streaming/id1000551566)

## Building
* Install Xcode from the [App Store page](https://apps.apple.com/us/app/xcode/id497799835)
* Run `git clone -b visionos --recursive https://github.com/RikuKunMS2/moonlight-ios-vision.git`
  *  If you've already cloned the repo without `--recursive`, run `git submodule update --init --recursive`
* Open Moonlight.xcodeproj in Xcode (it would download by default to your user folder on MacOS)
* To run on a real device, you will need to locally modify the signing options and add your device:
    * Go to the top menu bar, then in 'Window' open Devices and Simulators
    * Add your Vision Pro
    * In the project select to the folder icon in the sidebar to browser files
    * Click on "Moonlight" at the top of the left sidebar
    * Under "Targets", select "Moonlight Vision"
    * Click on the "Signing & Capabilities" tab
    * In the "Team" dropdown, select your name. If your name doesn't appear, you may need to sign into Xcode with your Apple account.
    * Change the "Bundle Identifier" to something different (unique). You can add your name or some random letters to make it unique.
    * Select your Vision Pro (not the simlator or 'any device' but the one your registered earlier) in the top bar as a target and click the Play button to run. It will start the build and install it to your headset
    * If you didn't pay for a developer account you will have to re-install it using x-code every 7 days.

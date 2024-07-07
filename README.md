# Moonlight iOS/tvOS

[![AppVeyor Build Status](https://ci.appveyor.com/api/projects/status/kwv8vpwr457lqn25/branch/master?svg=true)](https://ci.appveyor.com/project/cgutman/moonlight-ios/branch/master)

[Moonlight for iOS/tvOS](https://moonlight-stream.org) is an open source client for [Sunshine](https://github.com/LizardByte/Sunshine) and NVIDIA GameStream. Moonlight for iOS/tvOS allows you to stream your full collection of games and apps from your powerful desktop computer to your iOS device or Apple TV.

Moonlight also has a [PC client](https://github.com/moonlight-stream/moonlight-qt) and [Android client](https://github.com/moonlight-stream/moonlight-android).

Check out [the Moonlight wiki](https://github.com/moonlight-stream/moonlight-docs/wiki) for more detailed project information, setup guide, or troubleshooting steps.

[![Moonlight for iOS and tvOS](https://moonlight-stream.org/images/App_Store_Badge_135x40.svg)](https://apps.apple.com/us/app/moonlight-game-streaming/id1000551566)

## Requirements
* XCode developer account (to get the XCode Beta)
* Tested on Vision OS 2.0 Beta 2
* XCode Beta

## Building
* Install Xcode beta from the [App Store page](https://developer.apple.com/download/all/?q=xcode)
* You need to be signed into a developer account to download (and build) you don’t have to pay, just do all the steps right up to paying and then don’t pay
* You should delete your old xcode and rename xcode-beta to xcode
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

# Updates
* tried my best to stop scrolling from moving the trackpad / mouse cursor to where you’re looking 
* added a small delay to also allow you to right click after scrolling, but since the cursor moves it’s not that useful. If you don’t like it ping me on discord or ko-fi
* GC Mouse is still broken, until Apple themselves fix it there won’t be a way to really support native right click and magic trackpads to my understanding, even UTM hasn’t been able to fix this to my understanding.
* Game controllers now fixed but the app only works on vision OS 2.0 beta and up
* Docking mode during stream view is not possible due to support only being for AVPlayerViewController and I quote "Today, AVPlayerViewController scenes are the only scenes adhere to docking." source: https://developer.apple.com/documentation/RealityKit/DockingRegionComponent


## FAQ
* how do I enable mouse support? SET THE SCREEN MODE TO TOUCHSCREEN in the moonlight settings in the app. confusing I know, but until apple fixes actual mouse supports its going to have to be set to touch screen mode.
* How do I right click?: You press and hold on the trackpad for more than half a second and it will right click, both magic trackpad and eye clicking will do the same thing
* Why does my cursor snap to where I'm looking: I have no idea, this is an OS level thing that I don't think we have control over, oh boy I sure wish I could adjust the snapping delay though ha!

## New Planned Features
* Better magic trackpad support for right clicking + more
* Microphone forwarding via VBAN to Voicemeter on windows

# Donations
* Some people expressed interest in donations so:
* I set up a ko-fi for [donations](https://ko-fi.com/lumanaire)!
https://ko-fi.com/lumanaire

Thanks again for your support :)


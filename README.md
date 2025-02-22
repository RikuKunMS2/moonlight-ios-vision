# Moonlight XrOS

[Moonlight for VisionOs/iOS/tvOS](https://moonlight-stream.org) is an open source client for [Sunshine](https://github.com/LizardByte/Sunshine) and NVIDIA GameStream. Moonlight for iOS/tvOS allows you to stream your full collection of games and apps from your powerful desktop computer to your iOS device or Apple TV.

It also supports a Sunshine fork called [Apollo](https://github.com/ClassicOldSong/Apollo) which on Windows supports a Built-in Virtual Display with HDR support that matches the resolution/framerate config of your client automatically.

Moonlight also has a [PC client](https://github.com/moonlight-stream/moonlight-qt) and [Android client](https://github.com/moonlight-stream/moonlight-android).

Check out [the Moonlight wiki](https://github.com/moonlight-stream/moonlight-docs/wiki) for more detailed project information, setup guide, or troubleshooting steps. Also check out the [discord](https://moonlight-stream.org/discord)

[![Moonlight for iOS and tvOS](https://moonlight-stream.org/images/App_Store_Badge_135x40.svg)](https://apps.apple.com/us/app/moonlight-game-streaming/id1000551566) 

The Vision OS Version is not available in the App Store, to download the latest stable-ish build please install it via Testflight
[![Moonlight XrOS](https://i.imgur.com/DHhfmmK.png)](https://testflight.apple.com/join/poWcaME5) 

## Features

* Curved Screen Support (Reality Kit Mode)
* * To actiavte change the Renderer in settings to Reality Kit (note mouse and keyboard not supported in this mode at the moment)

![Curved Screen Support](https://preview.redd.it/moonlight-xros-1-year-anniversary-update-curved-screen-v0-xyro5aozeyge1.jpg?width=2254&format=pjpg&auto=webp&s=df631301423de93f161111df41543154e8fd5b04)

* SBS 3d support (in Reality Kit Mode only, it is one of the side buttons)

## ChangeLog (Version 11.0.3)

* I wanted to give special thanks to [tht7](https://www.reddit.com/user/tht7), ALVR for Vision Pro's [shinyquagsire23](https://github.com/shinyquagsire23), Giovanni Petrantoni (sinkingsugar) from [Formabble](https://formabble.com/) and [dereklucas](https://derekplucas.com) for their contributions to Moonlight XrOS"
* Reality Kit HDR Support is now in beta, it mostly works but YMMV on color accuracy. More options to control HDR will likely be added later. (sinkingsugar)
* SBS Support added to Reality Kit Mode (it is a new button in the reality kit volume side bar) (dereklucas)
* support for AppIntents! (Shortcut support) that allow users to directly launch into the StreamView if you've already paired (by accessing saved apps directly without opening the mainview). You should now be able to apps like 'Steam Big Picture' directly to their home screen (tht7)
* Fixed error messages so that app won't crash on connection or disconnection issues (tht7)
* Many optimizations for opening streams so it is now so much faster to connect to a server (tht7)
* Fixed issues with double volumes opening on slow connections (tht7)
* UI Optimizations (default to selecting to computer for example) (tht7)
* Perfomrance optimizations (shinyquagsire23)
* Edge shimmering on reality kit view should be resolved (shinyquagsire23)

## Noted Bugs

* Sometimes selecting a differing computer host doesn't load the app data, you may have to go back to the settings tab and back to refresh it.
* HDR is noteably broken on UiKit, Colors might not be perfect on Reality Kit, we are looking into adding some additional options to help adjust this
* Deleting a PC causes a crash when PC scanning is on (or an app scan is trying to refresh), after deleting a computer (for example if you need to repair after installing Apollo or Sunshine) just force quit and re-open and you will be fine
* Even though you've already paired a computer, you may see the same computer host again with .local in the name if you turn on scanning
* The app can get really slow if you have multiple hosts saved that aren't online (as it is trying to refresh to see available apps)
* Moonlight XrOS does not know when a computer is ONLINE, only that it's been saved and paired or it hasn't been paired yet
* Controller Vibration isn't working, we are looking into this
* According to user reports, PS4 touch pad does not work

# Building From Source

## Requirements
* XCode 16.2
* Tested on Vision OS 2.2, 2.3 and 2.4 Betas
  
## Build Instructions
* Install the latest version of Xcode
* Run `git clone -b vision-testflight --recursive https://github.com/RikuKunMS2/moonlight-ios-vision.git`
  *  If you've already cloned the repo without `--recursive`, run `git submodule update --init --recursive`
  *  If you are building someone else's fork replace the part after the -b and the user name in the github link.
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

## FAQ
* How do I right click?: You press and hold on the trackpad for more than half a second and it will right click, both magic trackpad and eye clicking will do the same thing
* Why does my cursor snap to where I'm looking: I have no idea, this is an OS level thing that I don't think we have control over, oh boy I sure wish I could adjust the snapping delay though ha!


## Feature Requests / Planned Features:
* Check Ko-Fi for updates

# Donations
* Some people expressed intrest in donations so:
* I set up a ko-fi for donations!
https://ko-fi.com/lumanaire

Thanks again for your support :)

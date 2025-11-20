# Moonlight XrOS

[Moonlight for VisionOs/iOS/tvOS](https://moonlight-stream.org) is an open source client for [Sunshine](https://github.com/LizardByte/Sunshine) and NVIDIA GameStream. Moonlight for iOS/tvOS allows you to stream your full collection of games and apps from your powerful desktop computer to your iOS device or Apple TV.

It also supports a Sunshine fork called [Apollo](https://github.com/ClassicOldSong/Apollo) which on Windows supports a Built-in Virtual Display with HDR support that matches the resolution/framerate config of your client automatically.

Moonlight also has a [PC client](https://github.com/moonlight-stream/moonlight-qt) and [Android client](https://github.com/moonlight-stream/moonlight-android).

Check out [the Moonlight wiki](https://github.com/moonlight-stream/moonlight-docs/wiki) for more detailed project information, setup guide, or troubleshooting steps. Also check out the [discord](https://moonlight-stream.org/discord)

[![Moonlight for iOS and tvOS](https://moonlight-stream.org/images/App_Store_Badge_135x40.svg)](https://apps.apple.com/us/app/moonlight-game-streaming/id1000551566) 

The Vision OS Version is not available in the App Store, to download the latest stable-ish build please install it via Testflight

[![Moonlight XrOS](https://i.imgur.com/DHhfmmK.png)](https://testflight.apple.com/join/poWcaME5) 

## Features

* **Curved Screen Support (Reality Kit Mode)**:
    * To activate, change the Renderer in settings to Reality Kit.
    * *Update:* distortion math has been redone for better accuracy.

![Curved Screen Support](https://preview.redd.it/moonlight-xros-1-year-anniversary-update-curved-screen-v0-xyro5aozeyge1.jpg?width=2254&format=pjpg&auto=webp&s=df631301423de93f161111df41543154e8fd5b04)

* **Immersive View Resizing**: Change stream view to any size; use the lock and unlock feature to reposition easily.
* **SBS 3D Support**: Available in Reality Kit Mode (toggle button in side bar).
* **HDR Support**: Includes a luminance value slider to calibrate for battery levels and environment.
* **AV1 Support**: Now supported in Reality Kit mode (Note: untested on M5).

## ChangeLog (Version 11.0.14 - Nov 19, 2025)

* **AV1 Support:** AV1 is now supported in Reality Kit mode.
* **Bitrate:** Added support for higher bitrate configurations (untested—performance depends on network and M2/M5 limits).
* **Immersive View:** Added option to setup an immersive view and change stream view to any size (use lock/unlock to reposition).
* **Settings Fix:** Fixed an issue where settings weren't saving on window dismissal/force quit.
* **Curved Screen:** Redid the math for curved screens to eliminate distortion and stretching.
* **Volume Controls:** Reduced jank in volume position controls; they now set limits to avoid clipping the stream view.
* **HDR:** * Fixed color space transform for more accurate colors.
    * Added a **Luminance Value Slider** to help calibrate the image for different battery levels and environments.
* **Input:** * Added a **Virtual Keyboard Button**. In UIKit mode, touch screen to pop up. In Reality Kit mode, it should appear automatically.
    * Added an invisible layer in front of the UIKit volume to capture mouse/keyboard for Reality Kit (Work in progress).

### Previous Updates Highlights
* **v11.0.12:** Added Low Latency Streaming Entitlement (AWDL) to improve network performance on non-standard WiFi channels.
* **v11.0.11:** Fixed memory resumption bugs, controller crashes, and added a HOME button to help recover the connection menu.
* **v11.0.6:** Major network discovery overhaul to reduce crashes.

## Noted Bugs

* **Empty Spinning Volume on Resume:** Sometimes resuming a volume causes a weird empty object screen. If this happens, force quit the app (Hold Crown + Capture buttons). Also sometimes the main menu doesn't come back up, I think this has to do with a race condtiion between app backgrounding/closing before the flag can update that it was closed or something, a fix for this should be coming soon but its hard because we don't know exactly what's causing this issue
* **HDR:** Doesn't work super well on UIKit. Colors might not be perfect on Reality Kit (use the new Luminance slider to adjust).
* **Computer Status:** Moonlight XrOS does not strictly know when a computer is ONLINE, only that it has been saved/paired.
* **Controller Vibration:** Currently not working; under investigation.
* **PS4 Touch Pad:** Does not work (SDL issue).
* **General Jank:** Deleting a PC while scanning *should* be fixed, but if issues persist, force quit and relaunch. Eye position mouse moving is weird that's an OS level thing I don't think I can fix how the cursor pointer snaps when you let go of your mouse / lift your finger off the trackpad

## FAQ
* **UIKit vs Reality Kit?**
    * Use **UIKit** if you need reliable Mouse + Keyboard support.
    * Use **Reality Kit** for Curved Screens, 3D SBS, and AR features. (Note: Mouse/Keyboard in Reality Kit is experimental).
* **How do I activate Curved Screens?**
    * In settings, change the renderer to Reality Kit Mode then connect to your host.
* **How do I Pair?**
    * Use the `+` button, or toggle the "Scan for Hosts" text in the computers list.
    * *Tip:* If you have performance issues, try not to leave scanning on constantly.
* **How do I use SBS?**
    * In Reality Kit mode, use the rectangle button toggle above the height adjust.
* **How do I use Ultrawide Mode?**
    * In settings set the resolution to 5120x1440, then set up [Apollo](https://github.com/ClassicOldSong/Apollo) or a virtual display driver on Windows.
	* also like, make sure in apollo after pairing your client has full permissions, otherwise you'll get a launch issue
    * In UIKit: Use the aspect ratio button to fix black bars.
    * In Reality Kit: Should be automatic.
* **Why is my connection choppy?**
    * it has the new entitlement to kill awdl but if you're doing something like... i dunno say air dropping in the background or maybe using hand off instead of directly connecting your mouse and keyboard you may have issues, so use ch 149 5ghz in us 
* **Recommended Settings:**
    * **Resolution:** 4K
    * **Aspect Ratio:** 16:9
    * **Framerate:** 60fps (120fps is tested)
    * **Bitrate:** 50mbps (Higher is supported now but untested)
    * **Renderer:** Reality Kit

## Feature Requests / Planned Features:
* Microphone Support.
* 7.1 Audio + Ability to toggle immersive audio.
* Updates to SDL3 (to fix PS4 touchpad issues).

# Donations
* Some people expressed interest in donations so I set up a ko-fi:
https://ko-fi.com/lumanaire

Thanks again for your support :)

# Building From Source

## Requirements
* Latest XCode 
* Tested on Vision OS 26.2 Beta
  
## Build Instructions
* Install the latest version of Xcode
* Run `git clone -b vision-testflight --recursive https://github.com/RikuKunMS2/moonlight-ios-vision.git`
  * If you've already cloned the repo without `--recursive`, run `git submodule update --init --recursive`
  * If you are building someone else's fork replace the part after the -b and the user name in the github link.
* Open Moonlight.xcodeproj in Xcode
* To run on a real device, you will need to locally modify the signing options and add your device:
    * Go to 'Window' -> Devices and Simulators
    * Add your Vision Pro
    * Click on "Moonlight" at the top of the left sidebar
    * Under "Targets", select "Moonlight Vision"
    * Click on the "Signing & Capabilities" tab
    * Select your Team (Sign into Apple account if needed)
    * Change the "Bundle Identifier" to something unique.
    * Select your registered Vision Pro in the target bar and click Play.
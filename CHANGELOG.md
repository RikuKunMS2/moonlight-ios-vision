#Change Log

## Version 11.0.21 (April 25, 2026)

### Audio Pipeline Refactor
- Complete migration of the spatial audio pipeline (`OutputAU`) to pure Objective-C.
- Restored functional audio streaming by properly activating `AVAudioSession` and integrating native `SpatialAudioComponent` for RealityKit.
- Fixed Opus decoding integration and eliminated "Session lookup failed" crashes.

### Vision Pro Spatial Audio & Immersion
- Integrated SharePlay-based co-watching using Spatial Personas for shared immersive viewing experiences.
- Added a user-configurable Reactive Lighting (Ambilight) toggle within the immersive control panel.
- Re-enabled 1:1 HDR EDR mapping for perfect RealityKit HDR and introduced a Calibration Mode toggle in the immersive control panel.

### UIKit Stream Recovery
- Added an "Open Main Menu" recovery button to the error overlay in UIKitStreamView to escape stuck window states on failed stream resumptions.

---

## Commit b191da8
*Note: A later commit will address contribution attribution data accidentally cleared from file headers.*
### Concurrency and Network Handling
- Moved blocking HTTP network calls (`updateHost`, `refreshAppsFor`) to background threads using Swift continuations.
- Wrapped state updates in `ObservableConnectionManager` with `@mainactor` to ensure execution on the main thread.

### Memory Management
- Implemented logic to unload 3D assets, including the Studio USDZ and skybox textures, when the application enters the background or switches to passthrough mode.

### HDR and Color Processing
- Added `pqExposure` (PQ HDR exposure trim) to the settings state, UI panels, and user defaults.
- Updated `DrawableVideoDecoder` and Metal shaders to calculate Rec.709, BT.2020, and SMPTE-C color spaces.
- Added explicit 10-bit format checks in the decoder to determine PQ transfer functions and range (full vs. video).

### Window Lifecycle and Stability
- Added detection for "zombie" streaming windows (scenes restored by visionOS after a reboot without an active stream) and redirection to the main menu.
- Modified the stream teardown sequence to use `NotificationCenter`, allowing stream views to dismiss themselves.
- Changed shared singletons from `@StateObject` to `@ObservedObject` to address runtime crashes.

### Performance Optimization
- Throttled RealityKit mesh generation during slider adjustments to 15 times per second.
- Reduced the mDNS discovery polling rate for paired hosts to decrease HTTP request frequency.

### Stream Lifecycle and Window Management
- Added `StreamModeSelectionOverlay` to allow selection of launch modes: UIKit, RealityKit Volume, or RealityKit Immersive.
- Modified `AppsView` and `MainViewModel` to display "Resume" and "Stop" buttons on the main menu when a stream is running in the background.
- Centralized stream state management (`StreamLifecycleState`) to handle reconnections, teardown timing, backgrounding, and error recovery.

### Input and Control
- Replaced `InputCaptureView` with a new implementation.
- Added `GazeInputController` for eye-tracking and pinch-to-click functionality, including long-press for right-click.
- Added "Touch Mode" for relative mouse movements.
- Added support for swapping A/B and X/Y buttons.
- Implemented fallback logic for controller haptics on visionOS when specific motor localities are unsupported.

### AV1 Video and HDR
- Added `AV1Parser.swift` for manual parsing of AV1 bitstreams and `av1C` codec configuration.
- Updated `Shaders.metal` to support HDR, including SMPTE ST.2084 (PQ) curve decoding to EDR, BT.2020 color space matrix conversions, and color grading adjustments for warmth, contrast, and saturation.
- Set HDR setting default to 1.0.
- Added shader-based rounded corners for the streaming view.

### Environments and Audio
- Added logic to load skyboxes and gradient textures for background dimming.
- Added screen tilt controls.
- Anchors spatial audio to the 3D scene entity (`fixAudioForScene`) to align sound source with the virtual screen.

---

## Changelog 202511230321

---

## English

### Added

#### Localization Support
- **First Launch Language Selection**: Added language selection prompt on first app launch, supporting English and Simplified Chinese
- **Settings Language Selector**: Added language selector in settings menu, allowing users to change interface language at any time
- **Language Preference Persistence**: Language settings are automatically saved and persist across app restarts
- **Comprehensive UI Localization**: All user interface text now supports both English and Simplified Chinese, including:
  - Main menu and navigation
  - Settings and preferences
  - Error messages and alerts
  - Stream controls and status messages
  - Pairing and connection prompts
  - Window close instructions
- **Dynamic Language Switching**: Language changes take effect immediately without requiring app restart
- **Standard Localization Implementation**: Uses `.strings` files for localization

#### Stream Window Management
- **Background/Resume Handling**:
  - UIKit Mode: Properly handles app backgrounding and resuming, stream pauses when backgrounded and automatically resumes when reactivated
  - RealityKit Mode: Supports immersive scene and background resume, correctly manages stream state
- **Automatic Aspect Ratio Lock (UIKit)**: Automatically applies aspect ratio lock when stream starts, preventing black bars when resizing windows
- **Window Size Memory Feature**:
  - UIKit Mode: Remembers user-adjusted window size and automatically restores it on next stream start
  - Real-time window size change monitoring, automatically saves to persistent storage
  - Uses unified toggle with RealityKit settings

#### RealityKit Enhancements
- **Settings Persistence**: Remembers user's RealityKit settings, including:
  - Screen curvature
  - Height
  - Depth offset
  - Immersive scale
  - Immersive position
  - Immersion amount
- **Settings Memory Toggle**: Provides toggle option for users to choose whether to remember RealityKit settings
- **HDR Slider Visibility Optimization**: "Boost / Luminance" slider now only appears when HDR is enabled
- **Stream Termination Overlay**: Displays overlay interface when stream stops, provides button to return to main menu, prevents automatic resume of closed streams after Vision Pro restart

#### Unified Settings Management
- **Unified Memory Feature Toggle**: UIKit and RealityKit use the same "Remember Stream Settings" toggle
  - UIKit: Controls window size memory
  - RealityKit: Controls all RealityKit-related settings memory

### Fixed

- **Fixed Black Screen on Stream Window Return**: Fixed issue where stream window turns black after returning from background or immersive scenes, stream now properly resumes when window is reactivated
- **Fixed RealityKit Background Resume**: Fixed issue where RealityKit mode gets stuck on loading screen after returning from immersive scene or headset standby
- **Fixed Auto-Resume Logic**: Unified auto-resume behavior for UIKit and RealityKit, ensures stream properly resumes when reopening stream window after closing

### Changed

- **Improved Window Size Restoration Logic**: Optimized window size restoration mechanism, supports restoration from both UserDefaults and temporary state
- **Optimized Settings Save Mechanism**: Improved settings save logic, reduces unnecessary write operations, improves performance

### Technical Details

- Added `LanguagePromptView.swift`: First launch language selection interface
- Added `LocalizationHelper.swift`: Localization helper utilities (later integrated into MainViewModel)
- Added `en.lproj/Localizable.strings` and `zh-Hans.lproj/Localizable.strings`: Localization string resources
- Updated `TemporarySettings.swift`: Added language settings, unified memory feature toggle, RealityKit settings persistence
- Updated `MainViewModel.swift`: Added language management, localization methods, window state management
- Updated `UIKitStreamView.swift`: Added background resume, window size monitoring, automatic aspect ratio lock
- Updated `RealityKitStreamView.swift`: Added background resume, settings persistence, stream termination overlay
- Updated `SettingsView.swift`: Added language selector, unified settings toggle, localized all text
- Updated `MoonlightVisionApp.swift`: Unified auto-resume logic

### Notes

- All new features have been tested to ensure compatibility with existing functionality
- Settings persistence uses dual storage with UserDefaults and DataManager to ensure data safety

---

## 简体中文

### 新增功能

#### 本地化支持
- **首次启动语言选择提示**：应用首次启动时显示语言选择界面，支持英文和简体中文
- **设置菜单语言选择器**：在设置菜单中添加语言选择器，可随时更改界面语言
- **语言偏好持久化**：语言设置会自动保存，应用重启后保持用户选择
- **全面界面本地化**：所有用户界面文本现在支持英文和简体中文，包括：
  - 主菜单和导航
  - 设置和偏好选项
  - 错误消息和警告
  - 串流控制和状态消息
  - 配对和连接提示
  - 窗口关闭说明
- **动态语言切换**：语言更改立即生效，无需重启应用
- **标准本地化实现**：使用 `.strings` 文件进行本地化

#### 串流窗口管理
- **后台/恢复处理**：
  - UIKit 模式：正确处理应用后台化和恢复，串流在后台时暂停，恢复时自动继续
  - RealityKit 模式：支持沉浸式场景和后台恢复，串流状态正确管理
- **自动宽高比锁定（UIKit）**：串流启动时自动应用宽高比锁定，避免调整窗口大小时出现黑边
- **窗口大小记忆功能**：
  - UIKit 模式：记住用户调整的窗口大小，下次启动串流时自动恢复
  - 实时监听窗口大小变化，自动保存到持久化存储
  - 与 RealityKit 设置使用统一的开关控制

#### RealityKit 增强功能
- **设置持久化**：记住用户的 RealityKit 设置，包括：
  - 屏幕曲面度
  - 高度
  - 深度偏移
  - 沉浸式缩放
  - 沉浸式位置
  - 沉浸度
- **设置记忆开关**：提供开关选项，用户可选择是否记住 RealityKit 设置
- **HDR 滑块可见性优化**："Boost / Luminance" 滑块现在只在 HDR 启用时显示
- **串流终止遮罩**：当串流停止时显示遮罩界面，提供返回主菜单的按钮，防止 Vision Pro 重启后自动恢复已关闭的串流

#### 统一设置管理
- **统一记忆功能开关**：UIKit 和 RealityKit 使用同一个"记住串流设置"开关
  - UIKit：控制窗口大小记忆
  - RealityKit：控制所有 RealityKit 相关设置记忆

### 修复问题

- **修复串流窗口变黑问题**：修复从后台或沉浸式场景返回后串流窗口变黑的问题，窗口重新激活时串流正常恢复
- **修复 RealityKit 后台恢复**：修复 RealityKit 模式在进入沉浸式场景或摘下头显待机后返回时卡在加载界面的问题
- **修复自动恢复逻辑**：统一 UIKit 和 RealityKit 的自动恢复行为，确保关闭串流窗口后重新打开时能正确恢复串流

### 改进

- **改进窗口大小恢复逻辑**：优化窗口大小恢复机制，支持从 UserDefaults 和临时状态两种方式恢复
- **优化设置保存机制**：改进设置保存逻辑，减少不必要的写入操作，提高性能

### 技术细节

- 添加 `LanguagePromptView.swift`：首次启动语言选择界面
- 添加 `LocalizationHelper.swift`：本地化辅助工具（后整合到 MainViewModel）
- 添加 `en.lproj/Localizable.strings` 和 `zh-Hans.lproj/Localizable.strings`：本地化字符串资源
- 更新 `TemporarySettings.swift`：添加语言设置、统一记忆功能开关、RealityKit 设置持久化
- 更新 `MainViewModel.swift`：添加语言管理、本地化方法、窗口状态管理
- 更新 `UIKitStreamView.swift`：添加后台恢复、窗口大小监听、自动宽高比锁定
- 更新 `RealityKitStreamView.swift`：添加后台恢复、设置持久化、串流终止遮罩
- 更新 `SettingsView.swift`：添加语言选择器、统一设置开关、本地化所有文本
- 更新 `MoonlightVisionApp.swift`：统一自动恢复逻辑

### 说明

- 所有新功能都经过测试，确保与现有功能兼容
- 设置持久化使用 UserDefaults 和 DataManager 双重存储，确保数据安全

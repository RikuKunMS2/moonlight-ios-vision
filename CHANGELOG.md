# Changelog 202511230321

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

# Changelog - Moonlight Vision Pro Improvements

# 更新日志 - Moonlight Vision Pro 改进

## Bug Fixes / 错误修复

### Fixed Black Screen Recovery Issue / 修复黑屏恢复问题
- **RealityKit Mode**: Fixed stream window turning black after returning from background or immersive scenes. Stream now properly resumes when the window becomes active again.
- **UIKit Mode**: Applied the same black screen recovery fix to UIKit streaming mode. Stream properly resumes after backgrounding or closing/reopening the app.
- **RealityKit 模式**: 修复了从后台或沉浸式场景返回后串流窗口变黑的问题。窗口重新激活时串流现在可以正常恢复。
- **UIKit 模式**: 将相同的黑屏恢复修复应用到 UIKit 串流模式。后台运行或关闭/重新打开应用后串流可以正常恢复。

### Fixed Window Lifecycle Management / 修复窗口生命周期管理
- **Home Button Handling**: Fixed crashes and orphaned windows when pressing the Home button during streaming. Windows now properly pause the stream instead of crashing.
- **Window Dismissal**: Improved window dismissal logic to prevent residual window bars and unresponsive states. Implemented user-driven manual window closure with clear instructions.
- **Background/Resume**: Properly handle app backgrounding and resumption. Streams pause when backgrounded and resume when the app becomes active again.
- **Home 按钮处理**: 修复了串流期间按下 Home 按钮时的崩溃和残留窗口问题。窗口现在会正确暂停串流而不是崩溃。
- **窗口关闭**: 改进了窗口关闭逻辑，防止残留窗口横条和无响应状态。实现了用户驱动的窗口手动关闭，并提供清晰的说明。
- **后台/恢复**: 正确处理应用后台化和恢复。应用进入后台时串流暂停，应用重新激活时恢复。

### Fixed Stream Conflict Handling / 修复串流冲突处理
- **Duplicate Stream Prevention**: Added detection for active stream windows. When attempting to start a new stream while an old one is still open, users are prompted with options: return to existing window, force quit old stream, or cancel.
- **Manual Window Closure**: Old stream windows display a clear message asking users to manually close them before starting a new stream. This prevents multiple stream windows and app crashes.
- **状态检测**: 添加了活动串流窗口的检测。当尝试启动新串流而旧窗口仍打开时，用户会收到提示：返回现有窗口、强制结束旧串流或取消。
- **手动窗口关闭**: 旧串流窗口显示清晰消息，要求用户手动关闭后再启动新串流。这防止了多个串流窗口和应用崩溃。

## New Features / 新功能

### Audio Session Management / 音频会话管理
- **Three Audio Modes**: Added three configurable audio session modes in Settings:
  - **Microphone Exclusive (Default)**: Traditional exclusive audio session that mutes other system media
  - **Allow Mixing with Other Audio**: Allows Moonlight audio to mix with other apps' audio
  - **Exclusive Only When Microphone Active**: Only uses exclusive mode when microphone is active, allowing mixing otherwise
- **三种音频模式**: 在设置中添加了三种可配置的音频会话模式：
  - **麦克风独占（默认）**: 传统的独占音频会话，会静音其他系统媒体
  - **允许与其他音频混音**: 允许 Moonlight 音频与其他应用的音频混音
  - **仅在使用麦克风时才切换到独占模式**: 仅在麦克风激活时使用独占模式，其他时候允许混音

### Window Corner Radius Customization / 窗口圆角自定义
- Added a slider in Settings to adjust the corner radius of streaming windows (both UIKit and RealityKit modes)
- Range: 0-60 pixels, default: 0 pixels (for maximum clarity)
- Changes apply immediately to active streams
- **Note**: Corner radius may slightly affect rendering sharpness. Default is set to 0 for maximum clarity.
- **窗口圆角调整**: 在设置中添加了滑块来调整串流窗口的圆角（UIKit 和 RealityKit 模式均支持）
- **范围**: 0-60 像素，默认：0 像素（以获得最佳清晰度）
- **即时生效**: 更改会立即应用到活动串流
- **注意**: 圆角可能会略微影响渲染清晰度。默认设置为 0 以获得最佳清晰度。

### Language Selection / 语言选择
- **First Launch Prompt**: Added a language selection prompt on first app launch, allowing users to choose between English and Simplified Chinese
- **Settings Integration**: Added language picker in Settings menu for changing language at any time
- **Persistent Storage**: Language preference is saved and persists across app restarts
- **首次启动提示**: 在首次启动应用时添加了语言选择提示，允许用户在英文和简体中文之间选择
- **设置集成**: 在设置菜单中添加了语言选择器，可随时更改语言
- **持久化存储**: 语言偏好设置会被保存，并在应用重启后保持

### Comprehensive Localization / 全面本地化
- **Complete UI Translation**: All user-facing text in the app now supports both English and Simplified Chinese:
- **完整界面翻译**: 应用中所有面向用户的文本现在都支持英文和简体中文：
  - 主菜单和导航
  - 设置和偏好
  - 错误消息和提示
  - 串流控制和状态消息
  - 配对和连接提示
  - 窗口关闭说明
- **动态语言切换**: 语言更改立即生效，无需重启应用

### Aspect Ratio Lock / 宽高比锁定
- **UIKit Mode**: Automatically applies aspect ratio lock when stream starts, eliminating the need for manual button presses to avoid black bars when resizing windows
- **UIKit 模式**: 串流启动时自动应用宽高比锁定，无需手动按按钮即可避免调整窗口大小时出现黑边

## Technical Improvements / 技术改进

### Code Organization / 代码组织
- Refactored stream lifecycle management into separate methods for better maintainability
- Improved state management with proper `@State` and `@Published` properties
- Added helper methods for audio session configuration and language localization
- **代码重构**: 将串流生命周期管理重构为独立方法，提高可维护性
- **状态管理**: 使用适当的 `@State` 和 `@Published` 属性改进状态管理
- **辅助方法**: 添加了音频会话配置和语言本地化的辅助方法

### Error Handling / 错误处理
- Improved error messages with localized text
- Better handling of edge cases in window lifecycle
- More robust stream state management
- **错误处理改进**: 使用本地化文本改进错误消息
- **边缘情况处理**: 更好地处理窗口生命周期中的边缘情况
- **状态管理**: 更健壮的串流状态管理

## Files Modified / 修改的文件

### Swift Files / Swift 文件
- `Moonlight Vision/MainViewModel.swift` - Added language management, audio session helpers, stream conflict detection
- `Moonlight Vision/MainContentView.swift` - Added language prompt, improved window dismissal logic
- `Moonlight Vision/RealityKitStreamView.swift` - Fixed black screen recovery, added manual close prompt, corner radius support
- `Moonlight Vision/UIKitStreamView.swift` - Fixed black screen recovery, added aspect ratio auto-lock, manual close prompt
- `Moonlight Vision/AppsView.swift` - Added stream conflict detection and alerts
- `Moonlight Vision/SettingsView.swift` - Added audio session mode picker, corner radius slider, language picker
- `Moonlight Vision/ComputerView.swift` - Localized all user-facing text
- `Moonlight Vision/StreamControls.swift` - Localized control buttons
- `Moonlight Vision/UpdatesView.swift` - Localized section headers
- `Moonlight Vision/LanguagePromptView.swift` - New file for first-launch language selection
- `Limelight/TemporarySettings.swift` - Added audio session mode enum, window corner radius, app language settings

### Objective-C Files / Objective-C 文件
- `Moonlight iOS/ViewControllers/StreamFrameViewController.m` - Localized "Starting..." message

### Project Files / 项目文件
- `Moonlight.xcodeproj/project.pbxproj` - Added LanguagePromptView.swift to project

## Testing Recommendations / 测试建议

1. **Black Screen Recovery**: Test by backgrounding the app, entering immersive scenes, and closing/reopening windows
2. **Stream Conflicts**: Test by starting a stream, pressing Home, then attempting to start another stream
3. **Audio Modes**: Test each audio session mode with system media playing
4. **Language Switching**: Test switching languages in Settings and verify all text updates
5. **Corner Radius**: Test adjusting corner radius with active streams
6. **Window Lifecycle**: Test various scenarios: Home button, app backgrounding, window dismissal

## 测试建议

1. **黑屏恢复**: 通过后台化应用、进入沉浸式场景、关闭/重新打开窗口进行测试
2. **串流冲突**: 通过启动串流、按 Home 键、然后尝试启动另一个串流进行测试
3. **音频模式**: 在系统媒体播放时测试每种音频会话模式
4. **语言切换**: 在设置中测试切换语言并验证所有文本更新
5. **圆角调整**: 在活动串流时测试调整圆角
6. **窗口生命周期**: 测试各种场景：Home 按钮、应用后台化、窗口关闭

## Notes for Maintainers / 维护者注意事项

- All new features are backward compatible
- Language preference defaults to English if not set
- Audio session mode defaults to exclusive (existing behavior)
- Window corner radius defaults to 0 pixels (for maximum clarity)
- **Important**: Window corner radius implementation uses `.clipShape()` which may slightly affect rendering sharpness. This is a limitation of SwiftUI/UIKit rendering system. Users can set it to 0 for maximum clarity.
- All localization uses a helper method pattern for consistency

## 维护者注意事项

- 所有新功能都向后兼容
- 如果未设置，语言偏好默认为英文
- 音频会话模式默认为独占（现有行为）
- 窗口圆角默认 0 像素（以获得最佳清晰度）
- **重要**: 窗口圆角实现使用 `.clipShape()`，可能会略微影响渲染清晰度。这是 SwiftUI/UIKit 渲染系统的限制。用户可将其设置为 0 以获得最佳清晰度。
- 所有本地化使用辅助方法模式以保持一致性

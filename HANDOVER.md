# 交接文档：刘老师 · 录课台（LLSStudio）

写给接手的工程师或 Agent。目标：不用重新摸索，就能定位问题、改代码、验证、打包。

---

## 0. 三十秒了解这个项目

- 这是一个 **macOS 原生录课工具**：屏幕 + 摄像头同时录制，配提词器（悬浮在屏幕顶部），录完能进编辑器手动合成导出。
- 代码来自开源项目 `nolangz/CueRecord`（Apache-2.0）的 fork，已经改成自己的产品身份：中文名「刘老师 · 录课台」，英文/机器名 `LLSStudio`。
- 当前版本 **2.2.1 (build 9)**，57 个 Swift 文件，`Vendor/` 里约 370 MB 语音模型与动态库（走 Git LFS）。
- 用户是课程作者，不是工程师。**交付必须是能双击运行的 `.app` / `.dmg`，不是源码。**

---

## 1. 环境与仓库

| 项 | 值 |
|---|---|
| 工作副本 | `/Volumes/work/code/CueRecord` |
| origin | `https://github.com/lhg-projects/lls-studio.git`（分支 `main`） |
| upstream | `https://github.com/nolangz/CueRecord.git`（只读参考，不要往上推） |
| Xcode | 16.4 (`/Applications/Xcode-16.4.0.app`)，Swift 6.1，部署目标 macOS 14.1 |
| 运行系统 | macOS 15.3.1 (24D70)，Apple Silicon |
| 构建产物 | `build/DerivedData/Build/Products/Release/LLSStudio.app` |
| 安装位置 | `~/Applications/LLSStudio.app`（用户级，不需要 sudo） |
| 冻结来源 | `5f01087` 是 fork 后的第一个提交（上游 v2.0.4 + Xcode 16.4 适配） |

日常命令：

```bash
cd /Volumes/work/code/CueRecord
git lfs install && git lfs pull        # 首次，否则 Vendor 里是几百字节的指针文件
./scripts/run-recording-core-tests.sh  # 22 项核心测试，必须全 PASS
./scripts/build-local.sh               # 只构建
./scripts/build-local.sh --install     # 构建并装到 ~/Applications
```

门禁：**这两条命令不通过，不算改完**。这是仓库 `AGENTS.md` 明文要求的。

---

## 2. 用户是谁，什么算「完成」

- 用户是「刘老师」，做 AI 实操课程，这个软件是他录课的生产工具。
- 他对代码没有耐心，要的是**能用**。所以：改完要自己跑起来验证，再告诉他一句话结论 + 怎么用。
- 他明确讨厌：反复要权限、启动就崩、中英混杂、把简单问题说复杂。
- 交付习惯：桌面放一份 `.dmg`，`~/Applications` 装一份能直接运行的。

---

## 3. 代码地图

### 3.1 录制主链路

| 文件 | 职责 |
|---|---|
| `CueRecord/Recording/RecordingController.swift` | 录制总控：开录/停录、设备刷新、权限请求编排、状态机 |
| `CueRecord/Recording/Core/Recording/ScreenRecorder.swift` | 屏幕与系统音频采集（ScreenCaptureKit），产出 `ScreenRecord_*.mov` |
| `CueRecord/Recording/Core/Camera/CameraManager.swift` | 摄像头采集与热切换，产出 `*_camera.mov` |
| `CueRecord/Recording/Core/Audio/AudioManager.swift` | 麦克风设备与电平 |
| `CueRecord/Recording/Core/Recording/RecordingSync.swift` | 多轨时间对齐（关键：起录门槛在 `AudioStartGate`） |
| `CueRecord/Recording/Core/Recording/RecordingArtifactOrganizer.swift` | 录制产物归档、命名、`raw_data/` 组织 |
| `CueRecord/Recording/Core/Recording/RecordingOutputValidator.swift` | 产物完整性校验（时长、轨道、可解码） |
| `CueRecord/Recording/Core/Recording/RecordingEditorPresentation.swift` | 「录完是否自动弹编辑器」的判定（曾经重复弹窗的元凶） |

**录制模型是「原始多轨 + 手动合成」**：一次录制落盘为屏幕轨、摄像头轨、`_overlay.json`、`_metrics.json`；用户在编辑器里导出时才合成为 `_composited.mov`。不要假设录完就有一个合成好的文件。

### 3.2 提词器与浮窗

| 文件 | 职责 |
|---|---|
| `CueRecord/NotchOverlayController.swift` | 刘海浮窗（`NotchOverlayView`）+ 独立悬浮窗（`FloatingOverlayView`）+ 面板管理 |
| `CueRecord/NotchSettings.swift` | 全部外观设置（宽度、字号、背景模式、跟随鼠标…） |
| `CueRecord/Teleprompter/CueTextTokenizer.swift` | 讲稿分词与换行标记 |
| `CueRecord/Teleprompter/SpeechTrackingMatcher.swift` | 语音与文字的模糊对齐（中英混排） |

浮窗背景三档：`OverlayBackgroundMode` = `solid` / `blur` / `clear`。`clear` 不画底板、不画毛玻璃、不画观众脸背景，只画文字并叠一圈暗影保证浅底可读。

### 3.3 语音与 AI

| 文件 | 职责 |
|---|---|
| `CueRecord/SpeechRecognizer.swift` | SherpaOnnx 流式语音识别，输出 `lastSpokenText`、`shouldDismiss`、`shouldAdvancePage` |
| `CueRecord/AI/ScriptAI.swift` | OpenAI 兼容 chat/completions 客户端、Keychain 密钥存取、AI 断句 |
| `CueRecord/AI/AIModelCatalog.swift` | provider 目录（默认 `deepseek`）、模型选择持久化 |
| `CueRecord/AI/AIVoiceAssistant.swift` | 语音口令：规则层（离线）+ 模型层（DeepSeek）双层解析 |
| `CueRecord/AI/AIScriptComposerSheet.swift` | AI 断句界面 |

语音口令的动作映射在 `NotchOverlayView` 的 `.onChange(of: speechRecognizer.lastSpokenText)` 里：翻页 → `shouldAdvancePage`，结束 → `shouldDismiss`，跳页 → `content.jumpToPageIndex`，暂停/继续 → `isPaused`。

### 3.4 本地化

- `CueRecord/InterfaceLanguage.swift`：`zhHans` 字典（384 条）+ `InterfaceLanguageSettings.shared.text(_:)`。
- 界面文案一律走 `Text(InterfaceLanguageSettings.shared.text("English Source"))`，字面量保持英文做 key。
- 默认语言是**简体中文**（`InterfaceLanguageSettings` 兜底值），不是跟随系统。

### 3.5 构建与打包

| 文件 | 职责 |
|---|---|
| `scripts/build-local.sh` | 本地 Release 构建 + 稳定签名 + 安装到 `~/Applications` |
| `scripts/run-recording-core-tests.sh` | 核心测试编译运行（swiftc 直编，不经 xcodebuild） |
| `build.sh` | 带 Developer ID 签名/公证的正式打包，需要 Apple 开发者账号 |
| `BRAND.md` | 品牌规范：名字、配色、图标四元素、文案规则 |
| `Info.plist` | 文档类型、权限用途说明；注意部分 key 由 `INFOPLIST_KEY_*` 构建设置生成，改 plist 不一定生效 |

---

## 4. 坑位清单（真实踩过，按踩坑频率排序）

### 4.1 权限相关（最耗时间的一类）

**坑 1：adhoc 签名的「代码要求」是自身 cdhash，每次重建都会变。**
后果：macOS 把新包当另一个应用，用户已授权的屏幕录制/摄像头/麦克风全部失效，表现为「我明明开了它还一直要」。
诊断：`codesign -d -r- App.app` —— 如果输出 `designated => cdhash H"xxxx"`，就是这个问题。
已修：`scripts/build-local.sh` 构建后重签，把代码要求固定为 `designated => identifier "com.liulaoshi.llsstudio"`。

**坑 2：`CODE_SIGNING_REQUIRED=NO` 会让 entitlements 根本不写进签名。**
后果：hardened runtime 应用缺 `com.apple.security.device.camera`，系统**连弹窗都不弹**，静默拒绝。
诊断：`codesign -d --entitlements :- App.app` —— 只剩 `get-task-allow` 就是没签进去。
已修：构建脚本改为正常签名，并显式传 `CODE_SIGN_ENTITLEMENTS`、`ENABLE_HARDENED_RUNTIME=YES`；entitlements 里加 `disable-library-validation` 以允许加载 `Vendor/` 下的第三方 dylib。

**坑 3：只查权限不请求权限。**
后果：`AVCaptureDevice.authorizationStatus` 是 `notDetermined` 时，代码只读状态就返回，系统永远不会弹窗，摄像头窗一直黑着。
已修：`CameraManager.checkCameraAvailability()` 在 `notDetermined` 时主动请求一次（带去重标记，避免循环）。

**坑 4：屏幕录制授权只对新启动的进程生效。**
后果：用户在系统设置勾了开关，当前进程仍返回未授权 → 应用再请求 → 再弹窗 → 死循环。
已修：`PermissionsManager` 里 `hasPromptedScreenRecording` 保证每次启动最多弹一次；引导页不再自动弹窗；界面给「重启应用」按钮（`relaunchApplication()`）。

排查权限问题时最有用的一条命令：

```bash
log show --predicate 'process == "tccd"' --last 5m --style compact | grep -i "llsstudio" | tail -20
```

看 `AUTHREQ_PROMPTING`（弹窗了）、`requires entitlement ... but it is missing`（被静默拒绝）、`AUTHREQ_RESULT`（用户选择）。

### 4.2 崩溃类

**坑 5：`zhHans` 字典字面量重复 key → 启动即崩。**
Swift 对字典字面量的重复 key 不在编译期报错，运行时 `SIGTRAP`，堆栈指向 `one-time initialization for zhHans`。
已修 + 加了回归测试 `LocalizationDictionaryHasNoDuplicateKeys`（扫源码文本查重）。**加词条前先跑这条测试。**

**坑 6：`@Observable` / `@Bindable` 属性错位。**
在 `class NotchSettings` 前插入新类型时，容易把 `@Observable` 留在新类型上，报 `'init(wrappedValue:)' is unavailable`。看到这个错，先看属性归属对不对。

### 4.3 构建与工具链

**坑 7：`build-local.sh --install` 先 `rm -rf` 目标再 `ditto` 复制。**
命令在两步之间被打断（超时、Ctrl-C），`~/Applications/LLSStudio.app` 会消失。恢复就是重跑一次构建。

**坑 8：`Vendor/` 是 Git LFS，没 pull 就是指针文件。**
构建脚本会检查 5 个关键资产的文件大小，小于 100 KB 直接报错退出。

**坑 9：`Info.plist` 里的权限说明可能被构建设置覆盖。**
`INFOPLIST_KEY_NSMicrophoneUsageDescription` 等 key 在 `project.pbxproj` 里，改仓库根目录的 `Info.plist` 不一定生效。改完用 `PlistBuddy` 读构建产物确认。

### 4.4 不能改的标识（数据契约）

改了会丢用户数据，收益为零：

| 标识 | 位置 |
|---|---|
| `.cuerecord` 元数据目录 | 工程目录内 |
| `.cuerecord` / `takeone` / `cueshot` 扩展名 | `Info.plist`、代码 |
| UTI `com.nolanlai.cuerecord.document` | `Info.plist` |
| URL scheme `cuerecord://` | `Info.plist` |
| Keychain service `com.nolanlai.cuerecord.ai-provider` / `.deepseek` | `ScriptAI.swift` |
| Swift 类型名 `CueRecord*` | 全项目 |

判断标准：**用户看得见的跟品牌走，用户数据依赖的一个字节都不动。**

---

## 5. 怎么调试（照这个来）

### 5.1 拿到应用自己的日志

应用大量使用 `print()`（关键字：`📷` 摄像头、`📺` 屏幕录制、`🎤` 麦克风、`🔐` 权限、`⚠️` 异常）。这些不会进统一日志系统，必须挂 stdout：

```bash
open --env NSUnbufferedIO=YES --stdout /tmp/app.log --stderr /tmp/app.log ~/Applications/LLSStudio.app
sleep 10 && grep -aE "📷|📺|🔐|⚠️" /tmp/app.log
```

`NSUnbufferedIO=YES` 不能省，否则日志全被缓冲，文件是空的。
直接运行二进制（`~/Applications/LLSStudio.app/Contents/MacOS/LLSStudio`）也能看到日志，但那是**从终端启动**，TCC 会把「responsible process」记到终端或上层应用头上，摄像头/屏幕录制这类权限的表现会和在 Finder 里双击不一致。**验证权限问题必须用 `open` 或双击。**

### 5.2 崩溃

```bash
ls -t ~/Library/Logs/DiagnosticReports/LLSStudio* | head -3
```

读 `.ips`：第一条 JSON 是头部，第二条是正文；找 `exception.type`、`termination`、以及触发线程的 `Swift runtime failure` 那行符号。

### 5.3 权限状态

```bash
tccutil reset Camera com.liulaoshi.llsstudio         # 单项重置
tccutil reset ScreenCapture com.liulaoshi.llsstudio
tccutil reset Microphone com.liulaoshi.llsstudio
```
`~/Library/Application Support/com.apple.TCC/TCC.db` 没有完全磁盘访问权限读不了，别浪费时间。

### 5.4 设置项

偏好文件：`~/Library/Preferences/com.liulaoshi.llsstudio.plist`。

```bash
defaults read com.liulaoshi.llsstudio overlayBackgroundMode
defaults write com.liulaoshi.llsstudio overlayBackgroundMode -string clear
```

---

## 6. 测试

```bash
./scripts/run-recording-core-tests.sh
```

22 项，覆盖：音频起录门槛、录制目标解析、像素格式策略、多轨同步、产物归档与校验、路径策略、工程清单冲突、临时 Vault、Vault 修复、讲稿分词与换行、节奏标记、跨行锚点匹配、编辑器弹出判定、AI 语音口令解析、本地化词条查重。

当前状态：全 PASS。新增功能请同步加测试，测试文件在 `Tests/RecordingCoreTests/main.swift`，脚本里要记得把新源文件加进 `swiftc` 列表。

---

## 7. 已知限制 / 待办

| 项 | 说明 |
|---|---|
| 独立悬浮窗未接语音口令 | 口令接线只在 `NotchOverlayView`（刘海浮窗）；`FloatingOverlayView` 没接 |
| 切换语言不实时刷新 | 走单例读取文案的视图要等重建才更新；设置页本身监听语言变化 |
| DMG 未公证 | 本地 adhoc 签名，用户自己机器能跑；发给别人需要 Developer ID + 公证 |
| 组织改名未做 | `lhg-projects` → `lls-projects` 需要 `admin:org` 权限，命令见 `lls-handbook/decisions/` |
| 语音口令默认关闭 | 设置 → 语音 → 语音口令，用户需手动打开 |
| 旧版 vault 丢失 | 换 Bundle ID 后是独立应用，旧路径 `~/Desktop/练习-第1课` 已不存在 |

---

## 8. 相关文档（都在 GitHub）

| 文档 | 位置 | 内容 |
|---|---|---|
| 品牌规范 | `lls-studio/BRAND.md` | 名字、配色、图标语义、文案规则 |
| 工程约束总纲 | `lls-handbook/README.md` | 命名规则、工程约束、写作约束、交付格式、十条自检 |
| 改名决策记录 | `lls-handbook/decisions/2026-10-21-rename-to-lls-studio.md` | 为什么改名、已完成项、剩余步骤 |
| 变更单 | `lls-handbook/changes/2026-10-21-chinese-default-and-voice-ai.md` | 中文默认、汉化、DeepSeek 接入的具体改法 |

---

## 9. 接手后建议的第一步

1. `git lfs pull`，然后跑一次 `./scripts/run-recording-core-tests.sh` 和 `./scripts/build-local.sh --install`，确认基线是绿的。
2. 用 `open --env NSUnbufferedIO=YES --stdout ...` 启动，录一条 30 秒的测试，看 `_composited.mov` 能不能导出来。这是这个软件的核心价值，坏了其他都白搭。
3. 复现用户报告的问题时，先看 `📷📺🔐` 三类日志，再看 `tccd` 日志，最后才怀疑业务代码——过去两天里，权限与签名问题占了全部故障的七成。

---

## 10. 未解决问题：录制结束时内存暴涨（2026-10-22 报障）

**现象**：用户录完一条视频后，系统弹「应用程序内存不足」，活动监视器显示本应用占用 **75.39 GB**。

**已排除**（静态排查 + 实测）：

| 嫌疑 | 结论 |
|---|---|
| `CameraFrameBuffer` | 容量 8 的有界队列，不是 |
| `pendingAudioBuffers` | 上限 48，超出即丢弃，不是 |
| 摄像头写入路径 | `isReadyForMoreMediaData` 未就绪即丢帧，有界 |
| 导出合成循环 | 同样检查就绪状态，且 `alwaysCopiesSampleData = false`，不是 |
| 摄像头浮窗每帧新建 `CIContext` | **确有浪费**（900 帧约涨 37 MB），已改为共用 `CameraFrameProcessor.sharedContext`，但这个量级解释不了 75 GB |

**75 GB 的量级推算**：4K BGRA 一帧约 33 MB，75 GB ≈ 2300 帧 ≈ 30fps 下 77 秒的帧堆在内存里。指向「某个队列在积压」或「某个大缓冲被复用失败」，而不是逐帧小对象泄漏。

**已埋好的探针**（`CueRecord/Support/MemoryFootprint.swift`，输出 `📊 标签: xx MB`）：

- `录制 开始` / `录制 停止（停止前）`
- `后处理/导出 开始 (状态文案)` / `后处理/导出 完成`
- `录制中（每 600 帧）`
- `摄像头浮窗渲染（每 300 帧）`

**复现方式**（必须拿到这段日志才能定位）：

```bash
pkill -f "LLSStudio.app/Contents/MacOS/LLSStudio"
open --env NSUnbufferedIO=YES --stdout /tmp/mem.log --stderr /tmp/mem.log ~/Applications/LLSStudio.app
# 录一条 2 分钟，带上摄像头浮窗，正常停止
grep -a "📊" /tmp/mem.log
```

判断方法：看 `录制 停止` 前后到 `后处理 完成` 之间的跳变。如果涨在「录制中」，是采集/编码队列积压；如果涨在「后处理」阶段，是导出链路的缓冲问题。

**下一步建议**：拿到日志后，在 `ScreenRecorder.appendScreenFrame` 与 `renderEditedVideo` 两处各加一次 `MemoryFootprint.log`，把范围收敛到函数级。

---

## 11. 当前状态（2026-10-23 交接）

### 已完成并验证

| 功能 | 说明 |
|---|---|
| 品牌与身份 | 刘老师 · 录课台 / LLSStudio / com.liulaoshi.llsstudio，图标、文案、权限说明全部落地 |
| 权限体系 | 代码要求固定为 bundle id（重装不丢权限）；entitlements 真正签入；摄像头首次使用主动请求 |
| 导出 | 时钟驱动 30fps CFR（修掉屏幕静止时人像冻结）；16:9 裁切默认开启；1080p 默认 |
| 内存 | 导出循环加 autoreleasepool，峰值稳定在 400 MB 左右，不再随片长增长 |
| 提词器 | 字号 16–96 数值可调、六款系统字体按族名解析、虚线框、底板透明度、实时预览、手动滚动、框内滚轮接管 |
| 颜色 | 已读/未读不做区分，代码内写死满不透明度（不再读设置） |
| 暂停 | 控制条结束键左侧；三路丢帧 + 时间基准平移，暂停段不进成片；计时冻结 |
| 草稿/导入 | 「打开草稿」（⇧⌘O，可选中文件夹，自动回溯 raw_data）、「导入视频」（⇧⌘I） |

### 待验证 / 未解决

1. **暂停是否真的剪掉那段**：需实测「录 10s → 暂停 20s → 录 10s → 导出」，成片应约 20s。若为 40s，说明只停了计时没停写入，查 `ScreenRecorder.setPaused` 与三处 `guard !isPaused`。（2026-10-23 深夜静态复核：三路丢帧齐全、基准平移数学自洽、帧处理与 `setPaused` 都串行在 MainActor，时序安全；但实机测试仍必须做。）
2. **某条录制导出黑屏**：**已定位，见第 12 节**。不是合成端丢帧；是那条录制的屏幕轨 AVAssetWriter 中途失败（moov 未写入，文件不可解码），导出时读不出画面所以全黑。
3. **暂停期间摄像头仍在采集**（有意设计，避免恢复时曝光跳变）。若用户报告恢复瞬间跳变，改为暂停时停采集。

---

## 12. 黑屏视频：已定位（2026-10-23 深夜，接手 Agent 复盘）

**结论**：用户看到的黑屏成片，源头是 2026-10-23 15:20 那条录制**屏幕轨文件损坏**，与导出/合成代码无关。

| 项 | 值 |
|---|---|
| 损坏文件 | `~/Documents/Obsidian Vault/Imported Markdown/Imported Markdown - 收件箱总览/ScreenRecord_2026-10-23_15-20-25.mov`（87 MB） |
| 症状 | `ffprobe` 报 `moov atom not found`，完全不可解码 |
| 应用自证 | 同目录 `_metrics.json`：`health: "damaged"`、`Output has no video track`、`screenFramesAppended: 1860` |
| 同场摄像头轨 | 正常可播，36.35s（说明采集与摄像头 writer 都活着，只有屏幕 writer 失败） |
| 其余全部录制 | `blackdetect` 扫描零黑帧段，全部健康 |

**故障链**：屏幕轨 `AVAssetWriter` 录制中途进入 `.failed` → `finishWriting` 不写 moov → `finishVideoWriting` 只 `print` 一行错误后返回 nil（`ScreenRecorder.swift` 约 2690–2740 行）→ 校验器把 damaged 写进 metrics，**但没有任何 UI 代码读 health**，用户不知情 → 事后在编辑器里导出，屏幕轨读不出 → 成片全黑。

**未决**：writer 为什么进 `.failed`。当日 15:20 跑的是白天未提交的中间构建，writer.error 只打进了已丢失的 stdout。该条录制帧数据显示中间约 9.6 秒摄像头连续丢帧（46s 墙钟 − 36.35s 成轨），形态像一次暂停，而暂停功能当晚才提交——**暂停是首要嫌疑但无实证**（当前已提交代码里暂停时序经复核是安全的，见第 11 节）。

**修复清单**（按优先级）：
1. 停录后若 `health != healthy`，立即弹窗告知「此条录制损坏：<原因>」，不要静默；
2. 编辑器对屏幕轨不可解码的 take 禁止导出并标注，而不是渲染出黑片；
3. `writerInput.append` 失败当场打印 `writer.error`（现在只在 finish 时打，日志早已冲掉）；
4. 实机复现：带 stdout 日志录一条「10s 录 → 暂停 10s → 恢复 10s → 停止」，grep `视频文件保存失败` / `帧写入失败`，一次测试同时验证第 11 节第 1、2 两项。

**素材已抢救（2026-10-23 深夜）**：用 untrunc 从 mdat 找回 1856/1860 个视频包，产出 `ScreenRecord_2026-10-23_15-20-25.mov_fixed.mov`（与原文件同目录，87 MB，H.264 2940×1912）。`blackdetect` 零黑段，抽帧目检画面完好。注意：fixed 文件的容器时长 66s 由音轨主导，视频包实际跨度约 38s，若音画有偏移需在导出时重对齐。

修复工具备忘（`/tmp` 重启即失）：
- 第三方 tap `sidneys/homebrew/untrunc` 公式已失效（SHA256 不符），且本机 Homebrew freetype 链接了不存在的 `libhvf.dylib`，走动态库必挂；
- 可行路径：`git clone https://github.com/anthwlock/untrunc && cd untrunc && brew install nasm && make untrunc-41`（自带脚本下载 ffmpeg 4.1 源码静态编译，约 5 分钟）；
- 用法：`./untrunc-41 <同参数健康轨> <损坏轨>`，输出 `<损坏轨>_fixed.mov`。

---

## 13. 2026-10-24：借鉴 Screen Studio 落地的七项能力（2.7.0）

来源：`lhg-projects/lhg-screen-studio` 蒸馏包（14 项能力 + 5 张任务卡）。每项独立提交，均可 `git log` 回溯：

| 提交 | 能力 | 说明 |
|---|---|---|
| `9aac222` | 信任四件套 | 开录磁盘体检（<5GB 拒录）、损坏即时弹窗、坏轨禁止导出、writer.error 当场入日志 |
| `dd71558` | 崩溃恢复清单 | 开录登记 / 暂停更新 / 停录移除 / 启动提示恢复，存 `~/Library/Application Support/com.liulaoshi.llsstudio/unfinished-recordings.json` |
| `2131db5` | 录制中打标记 | 控制条书签按钮 → `<base>_markers.json`（成片时间轴） |
| `cfc55bc` | 转写 + SRT | 提词器识别运行时自动落盘 `<base>_transcript.json` + 同名 `.srt` |
| `24e14f3` | 光标事件轨 | NSEvent 采样（无需辅助功能权限）→ `<base>_cursor.json`；录制时隐藏系统光标 |
| `b03846e` | 自绘光标 | 导出渲染大号平滑箭头（约 1.4 倍）+ 点击波纹 0.45s |
| `102dc82` | 自动缩放 | 停录按点击聚类生成 `<base>_zoom.json`，导出时 easeIn/OutCubic 缓动放大（1.9x，0.38s 进出） |
| 2.7.1 | 悬停停留缩放 | 鼠标在某处静置 ≥1.8s（阅读/讲解中）也触发温和放大（1.5x）；开录静止、讲完停住都算；指针搁在屏幕边缘（闲置）不缩放；点击与停留区间重叠时合并、点击倍率优先；拖拽（选中文字）也纳入光标采样 |

核心测试从 23 项增至 **32 项**（新增：Preflight、UnfinishedStore、MarkerStore、Transcript、Cursor 轨道/节流/插值/资源、ZoomTimeline/Heuristic(点击+停留)/Store、**CursorPixelRendering** 像素级验证真实渲染路径）。新源文件都在 `CueRecord/Recording/Core/Recording/`，加文件时记得同步 `scripts/run-recording-core-tests.sh` 的 swiftc 列表。

**已知边界（下一轮可做）**：
- 窗口录制模式下，光标归一化以开录时的窗口位置为基准，窗口移动后坐标会漂移（全屏 / 区域模式精确）。
- 转写只在提词器语音识别运行时产生；没开提词器就没有字幕稿。
- 自动缩放默认开启（点击即缩放），暂无设置开关；不想要某条的缩放就删它的 `_zoom.json`。
- 手动框选缩放未做：`ZoomRange` 数据结构已支持 manual 来源，缺编辑器 UI。
- 点击音效未做（需要导出端混音）。
- ~~暂停的实机验证仍未完成~~ **已闭环（2026-10-24）**：内置自测入口 `--smoke-record` 全自动验证（录 3s → 暂停 3s → 恢复 3s → 停止 → 导出）。实测：墙钟 9s+（含 3.2s 暂停）→ 成片 6.48s，暂停段确实被剪掉；标记/光标轨/自动缩放/导出全通过。复跑：`open --env NSUnbufferedIO=YES --stdout /tmp/smoke.log ~/Applications/LLSStudio.app --args --smoke-record`，报告在 `/tmp/llsstudio-smoke-report.json`。

**打包**：2.7.1 (build 27)。DMG 在桌面 `LLSStudio-2.7.1.dmg`；旧 2.6.5 DMG 已删除（旧版可从 `e5f42b0` 重建）。

### 排查经验（省时间用）

- 设置页的**预览**和真实浮窗是**两套代码**：预览在 `SettingsView` 的 `NotchPreviewController` / `NotchPreviewContent`，浮窗在 `NotchOverlayController`。改背景类问题必须两处都看。
- 预览里曾有**两块背景**，第二块（浮动预览）写死 `.fill(.black)` 不看设置，是「选全透明仍是黑板」的真凶。
- 透明问题按顺序查：视图背景 → 宿主 layer（`contentsScale` / `backgroundColor`）→ 窗口 `isOpaque`/`backgroundColor` → `hasShadow` → 圆角裁剪。
- 判断「是不是同一个应用」用 `codesign -d -r-`，看 `designated` 是 cdhash 还是 identifier。

---

## 15. 2026-10-24 深夜：HuaStudio 借鉴轮（2.8.0）

来源：`lhg-projects/lhg-hua-studio` 逆向蒸馏包（实测参数 + Agent 剪辑机制）。

| 提交 | 能力 | 说明 |
|---|---|---|
| `6f605f9` | 缩放参数校准 | 换成实测常数：保持 1500ms、点击倍率 1.6x、聚焦中心上移 2.7%；先导 450ms 与实测完全一致 |
| `1bce5ef` | 内置自测 | `--smoke-record` 全自动跑「录 3s → 打标记 → 暂停 3s → 恢复 3s → 停止 → 导出」并校验，报告写 `/tmp/llsstudio-smoke-report.json`。**第 11 节悬置的暂停验证正式闭环**：墙钟约 9.6s（含 3.2s 暂停）→ 成片 6.4s |
| `66c860c` | 闲段建议 | quietSpans（没说话∧没操作）→ `<base>_idle.json`，附开录头 1.5s 裁剪建议；转写缺失时宁缺毋滥不出建议 |
| `cd0b806` | Agent 剪辑 | ⌘⇧E 打开：把转写/标记/闲段/缩放汇总成一段自带操作规范的提示词（进剪贴板 + 存 `_agent-prompt.md`），粘给任意 AI；AI 产出 edits.json 选回来应用即导出。`_zoom.json` 改写前备份 `.bak`，AI 只能改参数碰不到渲染 |
| 2.8.0 | 画布/美化后端 | 画幅（source/16:9/9:16）+ 美化（留白 10.5%、圆角 20、墨岩底色，HuaStudio 实测默认值）渲染管线已实现并有测试。**竖屏不上 UI**（刘老师 2026-10-24 明确不需要），16:9 继续走既有裁切开关；能力入库，要启用时在编辑器 exportSection 加回 Picker 即可 |
| 2.8.0 | writer 单调护栏 | 见下面"重要发现"第 1 条 |

**本轮自测撞出的重要发现**：

1. **10-23 黑屏事故的真实机理复现了**。自测第 4 次运行：暂停恢复后首帧（约 3.1s 处）`writerInput.append` 失败（"The operation could not be completed"）→ writer 进 `.failed` → 后续帧全部静默跳过 → moov 永不写入。症状与用户 10-23 15:20 那条完全一致（moov not found + metrics damaged + 同样用了暂停），且是间歇性的（前三次自测全过）。已加护栏：**非单调时间戳帧直接丢弃**（丢一帧无感，毒死 writer 是全损）。若日后仍复现，排查方向是 SCStream 在暂停边界投递的帧时间戳。
2. 自测模式（`--smoke-record`）会跳过损坏弹窗与恢复提示，无人值守不卡死。
3. **导出完成后归档器会把原始素材移进 `raw_data/`**——之后对同一 take 再次导出必须用移动后的路径（Agent 剪辑窗口经 `CapturedRecordingOutput(discovering:)` 自动处理）。
4. 不同画幅的导出写同一条 `_edited.mov`，相互覆盖；同一素材要两种画幅需先复制。
5. `CIRoundedRectangleGenerator` 的参数键是 `inputExtent`（CIVector），**不是** `inputWidth/inputHeight`——用错键抛 ObjC 异常直接崩掉导出。圆角蒙版已改用 CoreGraphics 绘制（与光标/波纹同一套画法）。

**打包**：2.8.0 (build 28)，DMG 在桌面 `LLSStudio-2.8.0.dmg`。核心测试 34 项。

---

## 16. 2026-10-24：窗口录制改应用级采集（2.8.1）

**报障**：窗口模式只录选中的那个窗口，软件弹出的设置框/对话框是**独立窗口**，录不进来。

**修法**（`WindowCaptureGeometry.swift` + `ScreenRecorder`）：

- 采集滤镜从单窗口（`desktopIndependentWindow`）换成**应用级**（`display + including [目标 app]`），该应用的所有窗口——含弹窗、设置框、面板——全部纳入。
- `sourceRect` 钳在该应用全部可见窗口的**联合矩形**（SCWindow/SCDisplay 同为 SCK 左上原点系，纯平移即可，不做 AppKit 翻转）。
- **输出分辨率开录时固定**（AVAssetWriter 约束）；弹窗出现/窗口移动时，后台任务每 0.5s 重算联合矩形，按初始宽高比"包含式"扩展后 `stream.updateConfiguration` 只动 sourceRect（画面等比缩一下，不变形、不闪分辨率）。日志关键字：`🪟 采集范围跟随`。
- 拿不到窗口归属应用时自动退回老的单窗口滤镜（保底）。
- 跟随任务在停录/启动失败清理时取消。

**待真实使用确认**：弹窗捕获路径通过了 35 项核心测试（几何全测）与全屏回归自测，但"录窗口时真的弹一个框"没有自动化用例——下次窗口模式录课时弹一下设置框，日志里看到「采集范围跟随」即闭环。

**打包**：2.8.1 (build 29)，DMG 在桌面。

**16 节补充（2026-10-24 深夜，2.8.2）**：应用级联合跟随的方案被推翻——刘老师明确了"窗口"的语义：**把选中窗口圈出的那块屏幕定格成"一页"，区域内出现什么录什么，不限应用**（别的软件的窗口、弹窗、系统对话框都算）。实现随之简化：窗口模式与全屏同源采集（整块显示器、万物可见，录课台自己的悬浮窗仍排除），只用 `sourceRect` 把范围定格在选中窗口开录时的 frame（SCK 左上原点系内平移）。区域固定不跟随窗口移动。`WindowCaptureGeometry` 的 `sourceRect` 在用；`unionRect`/`containRect` 保留为工具函数（有测试）。窗口模式下光标归一化的坐标系差异（SCK 顶左 vs AppKit 底左）是既有注意事项，见第 13 节。

**打包**：2.8.2 (build 30)。

---

## 17. 2026-10-27：长录制损坏——资源耗尽（2.8.3）

**报障**：31 分钟区域录制（2x 屏 + 摄像头），停止后两条轨都无 moov、无 `_metrics.json`、无 `raw_data/` 归档。

**诊断（证据链完整）**：
- 双轨无 moov + 无 metrics + 无归档 = **停止流程没走完**（区别于第 15 节的 writer 中途失败，那次有 metrics）；
- 屏幕轨 14:08 停写、摄像头轨拖到 14:15，差 7 分钟 = 停止阶段被系统挂起；
- 系统诊断实锤：`LLSStudio_2026-10-27-134748.diag`（disk writes，24h 脏页写出 2.1GB，超限 86 倍，61 个采样全是 MediaToolbox `pwritev`）+ 13:42 CPU 超限 diag；
- 环境状态：swap 11.3GB 已用 10.65GB（95%），系统盘与写入盘同一块物理盘，只剩 11GB。
- **结论：不是 writer bug，是内存/磁盘资源枯竭，系统扼制了应用**。写入本身健康。第 15 节修的是"暂停边界时间戳问题"，这次是"资源耗尽"，两个病源都能造成无 moov。

**素材抢救**：untrunc + 同参数健康参考轨（`ScreenRecord_2026-10-24_23-09-38`），两条轨均已恢复可播（屏 25min06s / 摄像头 31min26s，AAC 保留；屏幕轨重建索引处有少量帧花屏，正片正常）。产物：原目录 `*_fixed.mov`。

**防线（2.8.3）**：
1. **录制中资源巡检**（`ResourceWatchdog`）：每 60s 采内存足迹 + 写入盘余量；磁盘 <8GB 提示"尽快收尾"、<3GB 提示"立即停止"、内存 >1.5GB 告警；结论经控制器 2s 轮询上 `lastError`（UI 提示条）并进日志（`🚨 资源水位`）。
2. **finishWriting 30s 超时兜底**：资源枯竭时 finishWriting 可能无限挂起（本次事故的直接死法）；超时强制 `cancelWriting()`，停止流程继续走完归档与 metrics——坏也坏得有据可查，不再无声无息。
3. 开录前 5GB 磁盘门槛已有（第 13 节）。

**给刘老师的长录制指南**（写进 HANDOVER，也请转告）：这台 Mac 当前内存吃紧（swap 95%）+ 盘剩 11GB。录 30 分钟以上的课之前：重启一次电脑（清 swap）、确保盘剩 >20GB；录制中若出现红条提示"尽快收尾/立即停止"，当堂收住。

**打包**：2.8.3 (build 31)，DMG 在桌面。核心测试 36 项。

---

## 18. 2026-10-27：借鉴 Screen Studio/HuaStudio 的"及时落盘 + 崩溃可救"（2.8.4）

刘老师点破的问题：为什么 Screen Studio / HuaStudio 没有长录制损坏？答案分两层——

**① 及时落盘（Screen Studio 的核心优点，本轮已学）**：录制路径的全部 5 个 writer
（屏幕/系统音频/麦克风/摄像头）此前都是 `expectsMediaDataInRealTime = true`——
这个模式让 AVAssetWriter **缓攒已编码数据**，内存随时长缓升，崩溃时未刷出的段
全部丢失，moov 收尾也重。全部切到 `false`（有背压、写完即刷），并加
`AVVideoMaxKeyFrameIntervalDuration = 2s`（GOP 按时间封顶，崩溃恢复粒度恒定）。
导出路径本来就是 false，未动。

**② 崩溃可救的凭据（两家的 .bak / unfinishedRecordings 思想）**：
开录即写 `<base>_recovery.json`（分辨率/帧率/码率/GOP——无 moov 的 mdat 用
untrunc 修复必须有同参数参考轨，10-24/10-27 两次抢救都是临时翻旧文件）；
正常停录后删除；**残留即信号**："上次录制未正常收尾，按此参数修复"。
启动时的未完成录制提示（第 13 节）会引导用户看到这个文件。

**验证**：核心测试 37 项；端到端自测确认恢复文件"开录写入 → 停录删除"生命周期
与既有暂停/导出行为无回归。

**打包**：2.8.4 (build 32)，DMG 在桌面。

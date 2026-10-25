import Foundation
import AppKit
import AVFoundation
import Combine
import CoreGraphics
import CoreImage
import ScreenCaptureKit

private nonisolated struct CameraOverlayMetadataFile: Codable, Sendable {
    let version: Int
    let screenFile: String
    let cameraFile: String?
    let coordinateSpace: String
    let generatedAt: String
    let recordingMode: String
    let recordingRect: CodableRect?
    let samples: [CameraOverlayMetadataSample]
}

private nonisolated struct CameraOverlayMetadataSample: Codable, Sendable {
    let time: Double
    let frame: CodableRect
    let shape: String
    let size: String
}

private nonisolated struct ResolvedRecordingEditCut: Sendable {
    let cut: RecordingEditCut
    let startSeconds: Double
    let endSeconds: Double
    let outputStartSeconds: Double

    var duration: Double {
        max(0, endSeconds - startSeconds)
    }
}

private nonisolated struct CodableRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

private extension CGRect {
    var area: CGFloat {
        max(width, 0) * max(height, 0)
    }
}

private enum AudioType {
    case systemAudio
    case microphone
}

private struct PendingAudioSample {
    let sampleBuffer: CMSampleBuffer
    let type: AudioType
}

@MainActor
class ScreenRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var canRecord = false
    
    private var stream: SCStream?
    private var videoWriterInput: AVAssetWriterInput?
    private var videoWriter: AVAssetWriter?
    private var pixelBufferAdapter: AVAssetWriterInputPixelBufferAdaptor?

    // 音频录制组件
    private var audioWriterInput: AVAssetWriterInput?
    private var microphoneWriterInput: AVAssetWriterInput?  // macOS 15+ 独立麦克风轨道
    private var avAudioEngineRecorder: AVAudioEngineRecorder?  // AVAudioEngine录制器

    private var recordingStartTime: CMTime = .zero
    private var frameCount: Int64 = 0
    private var firstVideoFrameTime: CMTime?  // 记录第一帧视频的时间戳

    // MARK: - 暂停/继续
    // 思路：暂停期间丢弃所有帧；恢复时把「时间基准」forward 平移一个暂停时长。
    // 因为所有轨道的相对时间都是 (采样时间 - firstVideoFrameTime) 算出来的，
    // 平移基准等于把暂停那段整体剪掉，输出仍是单一连续文件，不需要拼接。
    private(set) var isPaused = false
    private var pauseStartedAt: Date?

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        if paused {
            isPaused = true
            pauseStartedAt = Date()
            print("⏸ 录制已暂停")
        } else {
            if let started = pauseStartedAt, let base = firstVideoFrameTime {
                let seconds = Date().timeIntervalSince(started)
                firstVideoFrameTime = CMTimeAdd(base, CMTime(seconds: seconds, preferredTimescale: 600))
                print(String(format: "▶️ 录制继续，剪掉暂停时长 %.2fs", seconds))
            }
            pauseStartedAt = nil
            isPaused = false
        }
    }
    private let audioStartGate = AudioStartGate()
    private var pendingAudioBuffers: [PendingAudioSample] = []
    private let recordingMetrics = RecordingMetricsRecorder()
    /// 最近一次停录的产物校验结果。停录后由 RecordingController 读取，
    /// 用于向用户报告"此条录制损坏"，而不是等导出时才看到黑屏。
    private(set) var lastValidation: RecordingOutputValidation?
    /// 视频轨已写入的最后一帧时间戳。暂停/恢复边界上偶发非单调帧
    /// （2026-10-23 黑屏事故与 2026-10-24 自测复现：恢复后首帧 append 失败，
    /// writer 直接 .failed，moov 永远写不出来）。护栏：非单调帧丢弃，
    /// 丢一帧无感，毒死 writer 是全损。
    private var lastAppendedVideoPTS: CMTime?
    private var screenCapturePixelFormat: OSType = kCVPixelFormatType_32BGRA
    
    // 录制配置
    private var outputURL: URL?
    private var recordingRect: CGRect?
    private var isFullScreen: Bool = true
    private var recordingModeName: String = "fullScreen"
    /// 录制期间由 CursorEventTracker 采集光标事件轨时，源画面不再叠加系统光标，
    /// 导出端用自绘光标（更平滑、可放大、可加点击波纹）。
    private var hideSystemCursor = false
    // 窗口录制（应用级采集）的跟随状态
    private var windowUnionTrackingTask: Task<Void, Never>?
    private var windowCaptureDisplayFrame: CGRect = .zero
    private var windowCaptureAspectRect: CGRect = .zero
    private var windowCapturePixelSize: CGSize = .zero
    private var lastAppliedWindowUnion: CGRect?
    
    // 音频录制配置
    private var systemAudioEnabled: Bool = false
    private var microphoneEnabled: Bool = false
    private var microphoneDeviceID: String? = nil
    private var microphoneAudioDeviceID: AudioDeviceID? = nil
    
    // 摄像头叠加层
    private let cameraManager = CameraManager()
    private var enableCameraOverlay = false
    private var cameraOverlayPosition: CameraOverlayPosition = .topRight
    private var cameraOverlaySize: CameraOverlaySize = .medium
    private var cameraOverlaySnapshotProvider: (() -> CameraOverlaySnapshot?)?

    // 独立摄像头视频轨
    private var cameraWriter: AVAssetWriter?
    private var cameraWriterInput: AVAssetWriterInput?
    private var cameraPixelBufferAdapter: AVAssetWriterInputPixelBufferAdaptor?
    private var isCameraTrackRecording = false
    private var cameraOutputURL: URL?
    private var overlayMetadataURL: URL?
    private var cameraOutputDimensions: (width: Int, height: Int)?
    private var cameraFrameCount: Int64 = 0
    private var postProcessingHandler: (@MainActor (RecordingPostProcessingEvent) -> Void)?
    private var cameraFirstFrameTime: CMTime?
    private var overlayMetadataStartTime: CMTime?
    private var lastCameraElapsedTime: Double?
    private var overlayMetadataSamples: [CameraOverlayMetadataSample] = []
    private let cameraCIContext = CIContext()

    /// 设备 RGB 色彩空间：每帧创建一次是白费，做成共享。
    static let sharedDeviceRGBColorSpace = CGColorSpaceCreateDeviceRGB()

    private nonisolated static let screenTargetFrameRate = 60

    private nonisolated static func rec709VideoColorProperties() -> [String: Any] {
        [
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
    }

    private nonisolated static func evenPixelDimension(_ value: CGFloat) -> Int {
        max(2, Int(value.rounded(.toNearestOrAwayFromZero)) / 2 * 2)
    }
    
    override init() {
        super.init()
        checkCanRecord()
    }
    
    // MARK: - 权限和能力检查
    private func checkCanRecord() {
        Task {
            do {
                _ = try await availableContentForRecording()
                print("📺 ScreenCaptureKit 可用: \(canRecord)")
            } catch {
                canRecord = false
                print("❌ ScreenCaptureKit 检查失败: \(error)")
            }
        }
    }

    private func availableContentForRecording() async throws -> SCShareableContent {
        do {
            let availableContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard !availableContent.displays.isEmpty else {
                canRecord = false
                throw RecordingError.noDisplayFound
            }

            canRecord = true
            return availableContent
        } catch {
            canRecord = false
            throw error
        }
    }
    
    // MARK: - 设置摄像头叠加层
    func setCameraOverlay(enabled: Bool, position: CameraOverlayPosition, size: CameraOverlaySize) {
        enableCameraOverlay = enabled
        cameraOverlayPosition = position
        cameraOverlaySize = size
    }
    
    // MARK: - 获取摄像头管理器
    func getCameraManager() -> CameraManager {
        return cameraManager
    }

    func setCameraOverlaySnapshotProvider(_ provider: @escaping () -> CameraOverlaySnapshot?) {
        cameraOverlaySnapshotProvider = provider
    }
    
    // MARK: - 录制控制
    func startRecording(
        mode: RecordingMode,
        outputURL: URL,
        cameraOverlay: Bool = false,
        cameraPosition: CameraOverlayPosition = .topRight,
        cameraSize: CameraOverlaySize = .medium,
        systemAudioEnabled: Bool = false,
        microphoneEnabled: Bool = false,
        microphoneDeviceID: String? = nil,
        microphoneAudioDeviceID: AudioDeviceID? = nil,
        displayID: CGDirectDisplayID? = nil,
        hideSystemCursor: Bool = false
    ) async throws {
        guard !isRecording else {
            throw RecordingError.invalidState
        }

        print("🎬 开始屏幕录制...")
        self.hideSystemCursor = hideSystemCursor
        lastAppendedVideoPTS = nil

        do {
            self.outputURL = outputURL
            self.systemAudioEnabled = systemAudioEnabled
            self.microphoneEnabled = microphoneEnabled
            self.microphoneDeviceID = microphoneDeviceID
            self.microphoneAudioDeviceID = microphoneAudioDeviceID
            pendingAudioBuffers.removeAll()
            frameCount = 0
            firstVideoFrameTime = nil
            setCameraOverlay(enabled: cameraOverlay, position: cameraPosition, size: cameraSize)

            // 启动摄像头（如果需要）
            if enableCameraOverlay {
                // 重新检查摄像头可用性（权限可能刚被授权）
                cameraManager.refreshCameraDevices()
                // 等待一下让权限状态更新
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
                try await cameraManager.startCapture()
            }

            switch mode {
            case .fullScreen:
                try await startFullScreenRecording(displayID: displayID)
            case .selectedArea(let rect):
                try await startAreaRecording(rect: rect)
            case .selectedWindow(let target):
                try await startWindowRecording(target: target)
            }
        } catch {
            await cleanupAfterFailedStart()
            throw error
        }
        
        isRecording = true
        print("✅ 屏幕录制已开始")
    }
    
    func stopRecording(onCaptureStopped: (() -> Void)? = nil) async throws -> CapturedRecordingOutput? {
        guard isRecording else { return nil }

        print("⏹️  停止屏幕录制...")
        windowUnionTrackingTask?.cancel()
        windowUnionTrackingTask = nil

        // 停止stream
        if let stream = stream {
            try await stream.stopCapture()
        }
        stream = nil
        
        // 停止AVAudioEngine录制 (仅macOS 13-14)
        if #available(macOS 15.0, *) {
            // macOS 15+使用SCK，无需停止AVAudioEngine
        } else {
            avAudioEngineRecorder?.stopRecording()
            avAudioEngineRecorder = nil
        }
        
        // 停止独立摄像头视频轨，再关闭摄像头采集
        await stopCameraTrackRecording()
        cameraManager.stopCapture()
        onCaptureStopped?()
        
        // 完成视频写入
        let capturedOutput = await finishVideoWriting()
        
        isRecording = false
        frameCount = 0
        firstVideoFrameTime = nil  // 重置首帧视频时间

        print("✅ 屏幕录制已停止")
        return capturedOutput
    }

    func setPostProcessingHandler(_ handler: @escaping @MainActor (RecordingPostProcessingEvent) -> Void) {
        postProcessingHandler = handler
    }

    func renderCapturedRecording(
        _ capturedOutput: CapturedRecordingOutput,
        mode: RecordingRenderMode,
        exportSettings: RecordingExportSettings = .default
    ) {
        Self.startRecordingPostProcessing(
            capturedOutput: capturedOutput,
            mode: mode,
            exportSettings: exportSettings,
            handler: postProcessingHandler
        )
    }

    @discardableResult
    func deleteCapturedRecording(_ capturedOutput: CapturedRecordingOutput) throws -> [URL] {
        try RecordingArtifactOrganizer.deleteArtifacts(for: capturedOutput)
    }

    private func cleanupAfterFailedStart() async {
        print("🧹 清理录制启动失败后的临时资源")
        windowUnionTrackingTask?.cancel()
        windowUnionTrackingTask = nil

        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        if isCameraTrackRecording {
            isCameraTrackRecording = false
            cameraManager.setRecordingFrameHandler(nil)
        }

        cameraManager.stopCapture()
        videoWriter?.cancelWriting()
        cameraWriter?.cancelWriting()

        videoWriter = nil
        videoWriterInput = nil
        audioWriterInput = nil
        microphoneWriterInput = nil
        pixelBufferAdapter = nil
        cameraWriter = nil
        cameraWriterInput = nil
        cameraPixelBufferAdapter = nil
        cameraOutputDimensions = nil
        cameraFirstFrameTime = nil
        overlayMetadataStartTime = nil
        lastCameraElapsedTime = nil
        overlayMetadataSamples = []
        pendingAudioBuffers.removeAll()
        frameCount = 0
        firstVideoFrameTime = nil
        isRecording = false
    }
    
    // MARK: - 全屏录制
    private func startFullScreenRecording(displayID: CGDirectDisplayID?) async throws {
        print("📺 开始全屏录制...")
        
        let availableContent = try await availableContentForRecording()
        let display: SCDisplay
        if let displayID {
            guard let selectedDisplay = availableContent.displays.first(where: { $0.displayID == displayID }) else {
                let availableIDs = availableContent.displays.map(\.displayID)
                print("❌ 指定显示器不存在: \(displayID), 可用显示器: \(availableIDs)")
                throw RecordingError.noDisplayFound
            }
            display = selectedDisplay
        } else {
            guard let firstDisplay = availableContent.displays.first else {
                throw RecordingError.noDisplayFound
            }
            display = firstDisplay
        }
        
        isFullScreen = true
        recordingModeName = "fullScreen"
        recordingRect = display.frame

        print("📺 全屏录制目标显示器: \(display.displayID)")
        
        try await setupStreamAndWriter(for: display, rect: nil, availableContent: availableContent)
    }
    
    // MARK: - 区域录制  
    private func startAreaRecording(rect: CGRect) async throws {
        print("🔍 开始区域录制: \(rect)")
        
        let availableContent = try await availableContentForRecording()
        guard let display = displayContaining(rect, in: availableContent.displays) ?? availableContent.displays.first else {
            throw RecordingError.noDisplayFound
        }
        
        isFullScreen = false
        recordingModeName = "selectedArea"
        recordingRect = rect
        
        // 保存选择的区域到UserDefaults
        saveSelectedArea(rect)
        
        try await setupStreamAndWriter(for: display, rect: rect, availableContent: availableContent)
    }

    // MARK: - 窗口录制
    private func startWindowRecording(target: WindowRecordingTarget) async throws {
        print("🪟 开始窗口录制: \(target.displayName), id: \(target.windowID), frame: \(target.frame)")

        let availableContent = try await availableContentForRecording()
        guard let display = displayContaining(target.frame, in: availableContent.displays) ?? availableContent.displays.first else {
            throw RecordingError.noDisplayFound
        }
        guard let window = availableContent.windows.first(where: { $0.windowID == target.windowID }) else {
            throw RecordingError.noWindowFound
        }

        isFullScreen = false
        recordingModeName = "selectedWindow"

        // 应用级采集：软件弹出的设置框/对话框是独立窗口，单窗口滤镜
        // （desktopIndependentWindow）录不到。改为采集该应用全部可见窗口
        // 的联合矩形，弹窗自然在内。
        let ownerProcessID = window.owningApplication?.processID
        let captureUnion: CGRect
        if let ownerProcessID {
            let appWindowFrames = availableContent.windows
                .filter { candidate in
                    candidate.owningApplication?.processID == ownerProcessID
                        && candidate.isOnScreen
                        && candidate.frame.width >= 50
                        && candidate.frame.height >= 50
                }
                .map(\.frame)
            captureUnion = WindowCaptureGeometry.unionRect(ofFrames: appWindowFrames) ?? window.frame
            print("🪟 应用级采集: \(appWindowFrames.count) 个窗口联合 \(captureUnion)")
        } else {
            captureUnion = window.frame
        }

        recordingRect = captureUnion
        windowCaptureDisplayFrame = display.frame
        windowCaptureAspectRect = captureUnion
        lastAppliedWindowUnion = captureUnion

        try await setupStreamAndWriter(for: display, rect: nil, window: window, availableContent: availableContent)

        if let ownerProcessID {
            beginWindowUnionTracking(processID: ownerProcessID)
        }
    }

    /// 窗口录制跟随：弹窗出现/窗口移动时，把 sourceRect 扩到新的联合范围。
    /// 输出分辨率固定不变（AVAssetWriter 约束），联合范围按初始宽高比
    /// 包含式扩展，画面等比缩放。0.5s 轮询，变化超过阈值才重配流。
    private func beginWindowUnionTracking(processID: Int32) {
        windowUnionTrackingTask?.cancel()
        windowUnionTrackingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.isRecording, let stream = self.stream else { break }
                guard let content = try? await SCShareableContent.current else { continue }
                let frames = content.windows
                    .filter { candidate in
                        candidate.owningApplication?.processID == processID
                            && candidate.isOnScreen
                            && candidate.frame.width >= 50
                            && candidate.frame.height >= 50
                    }
                    .map(\.frame)
                guard let union = WindowCaptureGeometry.unionRect(ofFrames: frames) else { continue }

                let contain = WindowCaptureGeometry.containRect(
                    aspectOf: self.windowCaptureAspectRect,
                    containing: union,
                    in: self.windowCaptureDisplayFrame
                )
                if let last = self.lastAppliedWindowUnion,
                   abs(contain.minX - last.minX) < 12,
                   abs(contain.minY - last.minY) < 12,
                   abs(contain.width - last.width) < 12,
                   abs(contain.height - last.height) < 12 {
                    continue
                }
                self.lastAppliedWindowUnion = contain
                self.recordingRect = contain
                let config = self.rebuildWindowCaptureConfiguration()
                do {
                    try await stream.updateConfiguration(config)
                    print("🪟 采集范围跟随: \(contain)")
                } catch {
                    print("⚠️ 采集范围跟随失败: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 流重配用的完整配置（updateConfiguration 会整体替换，缺字段会回落默认值）。
    /// 分辨率保持开录时的固定值，只动 sourceRect。
    private func rebuildWindowCaptureConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.pixelFormat = screenCapturePixelFormat
        config.showsCursor = !hideSystemCursor
        config.scalesToFit = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.screenTargetFrameRate))
        config.capturesAudio = systemAudioEnabled
        config.excludesCurrentProcessAudio = true
        if #available(macOS 15.0, *) {
            config.captureMicrophone = microphoneEnabled
            if let deviceID = microphoneDeviceID {
                config.microphoneCaptureDeviceID = deviceID
            }
        }
        if let contain = lastAppliedWindowUnion {
            config.sourceRect = WindowCaptureGeometry.sourceRect(for: contain, in: windowCaptureDisplayFrame)
        }
        config.width = Int(windowCapturePixelSize.width)
        config.height = Int(windowCapturePixelSize.height)
        config.queueDepth = 5
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }

    private func displayContaining(_ rect: CGRect, in displays: [SCDisplay]) -> SCDisplay? {
        displays.max { first, second in
            first.frame.intersection(rect).area < second.frame.intersection(rect).area
        }
    }

    private func backingScaleFactor(for rect: CGRect?) -> CGFloat {
        guard let rect else {
            return NSScreen.main?.backingScaleFactor ?? 1.0
        }

        return NSScreen.screens
            .max { first, second in
                first.frame.intersection(rect).area < second.frame.intersection(rect).area
            }?
            .backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
    }

    private func nativeDisplayPixelDimensions(
        for filter: SCContentFilter,
        display: SCDisplay
    ) -> (width: Int, height: Int, scaleFactor: CGFloat, source: String) {
        if #available(macOS 14.0, *) {
            let contentRect = filter.contentRect
            let scaleFactor = max(CGFloat(filter.pointPixelScale), 1)
            let width = Self.evenPixelDimension(contentRect.width * scaleFactor)
            let height = Self.evenPixelDimension(contentRect.height * scaleFactor)

            if width > 2, height > 2 {
                return (width, height, scaleFactor, "SCContentFilter.contentRect * pointPixelScale")
            }
        }

        if let screen = NSScreen.screens.first(where: { CGDirectDisplayID($0.displayID) == display.displayID }) {
            let scaleFactor = max(screen.backingScaleFactor, 1)
            let width = Self.evenPixelDimension(screen.frame.width * scaleFactor)
            let height = Self.evenPixelDimension(screen.frame.height * scaleFactor)

            if width > 2, height > 2 {
                return (width, height, scaleFactor, "NSScreen.frame * backingScaleFactor")
            }
        }

        return (
            max(2, display.width / 2 * 2),
            max(2, display.height / 2 * 2),
            1,
            "SCDisplay.width/height fallback"
        )
    }
    
    // MARK: - Stream 和 Writer 设置
    private func setupStreamAndWriter(
        for display: SCDisplay,
        rect: CGRect?,
        window: SCWindow? = nil,
        availableContent: SCShareableContent? = nil
    ) async throws {
        guard let outputURL = outputURL else {
            throw RecordingError.invalidOutputURL
        }
        
        // 设置录制配置
        let config = SCStreamConfiguration()
        
        // 视频质量配置
        let capturePixelFormat = RecordingPixelFormatPolicy.selectedFormat()
        let pixelFormat = capturePixelFormat.osType
        screenCapturePixelFormat = pixelFormat
        config.pixelFormat = pixelFormat
        print("🎥 Capture pixel format: \(capturePixelFormat.displayName)")
        config.showsCursor = !hideSystemCursor
        if hideSystemCursor {
            print("🖱️ 系统光标已隐藏，光标由事件轨在导出端自绘")
        }
        config.scalesToFit = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.screenTargetFrameRate))
        
        // 音频配置
        config.capturesAudio = self.systemAudioEnabled
        config.excludesCurrentProcessAudio = true  // 避免录制自己应用的声音
        
        // macOS 15+ 麦克风支持
        if #available(macOS 15.0, *) {
            config.captureMicrophone = self.microphoneEnabled
            if let deviceID = self.microphoneDeviceID {
                config.microphoneCaptureDeviceID = deviceID
            }
        }

        // 设置录制内容过滤器。Full screen uses this filter's display-specific
        // pointPixelScale so selected external Retina displays record at native pixels.
        let filter: SCContentFilter
        if let window = window, let ownerApp = window.owningApplication {
            // 应用级采集（含弹窗）：整块显示器为源，sourceRect 钳在联合矩形
            filter = SCContentFilter(display: display, including: [ownerApp], exceptingWindows: [])
            if let captureRect = recordingRect {
                config.sourceRect = WindowCaptureGeometry.sourceRect(for: captureRect, in: display.frame)
            }
            // 联合范围会随弹窗出现而扩大，按固定输出等比缩放
            config.scalesToFit = true
        } else if let window = window {
            // 拿不到归属应用时退回单窗口（老行为，弹窗录不进来）
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            let excludedWindows = ownShareableWindows(in: availableContent)
            if !excludedWindows.isEmpty {
                print("🪟 Excluding \(excludedWindows.count) 录课台 windows from capture")
            }
            filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        }
        
        if let window = window {
            let targetRect = recordingRect ?? window.frame
            let scaleFactor = backingScaleFactor(for: targetRect)
            let pixelWidth = round(targetRect.width * scaleFactor)
            let pixelHeight = round(targetRect.height * scaleFactor)
            let alignedWidth = max(2, Int(pixelWidth / 2) * 2)
            let alignedHeight = max(2, Int(pixelHeight / 2) * 2)

            config.width = alignedWidth
            config.height = alignedHeight
            config.scalesToFit = true
            config.queueDepth = 5
            config.colorSpaceName = CGColorSpace.sRGB
            // 输出分辨率固定，跟随只动 sourceRect
            windowCapturePixelSize = CGSize(width: alignedWidth, height: alignedHeight)

            print("🪟 窗口录制配置:")
            print("   采集范围: \(targetRect)")
            print("   缩放因子: \(scaleFactor)")
            print("   输出分辨率: \(alignedWidth)x\(alignedHeight)")
        } else if let rect = rect {
            // 🎯 区域录制配置 - 像素对齐优化
            let scaleFactor = backingScaleFactor(for: rect)
            
            // 1. 像素对齐：确保所有坐标都是整数像素
            let pixelX = round(rect.origin.x * scaleFactor)
            let pixelWidth = round(rect.width * scaleFactor)
            let pixelHeight = round(rect.height * scaleFactor)
            
            // 2. 确保宽高为偶数（H.264编码要求）
            let alignedWidth = Int(pixelWidth / 2) * 2
            let alignedHeight = Int(pixelHeight / 2) * 2
            
            // 3. 转换回点坐标（用于sourceRect）
            let alignedRect = CGRect(
                x: pixelX / scaleFactor,
                y: rect.origin.y,  // 暂时保持Y坐标
                width: CGFloat(alignedWidth) / scaleFactor,
                height: CGFloat(alignedHeight) / scaleFactor
            )
            recordingRect = alignedRect
            
            // 4. 坐标系转换：macOS（左下） -> ScreenCaptureKit（左上）
            let convertedX = alignedRect.origin.x - display.frame.origin.x
            let convertedY = display.frame.maxY - alignedRect.maxY
            let convertedRect = CGRect(
                x: convertedX,
                y: convertedY,
                width: alignedRect.width,
                height: alignedRect.height
            )
            
            // 5. 设置配置：关键是1:1采样，避免缩放
            config.sourceRect = convertedRect
            config.width = alignedWidth
            config.height = alignedHeight
            config.scalesToFit = false  // 关键：禁用缩放
            config.queueDepth = 5
            config.colorSpaceName = CGColorSpace.sRGB
            
            print("🎯 像素对齐优化:")
            print("   原始区域: \(rect)")
            print("   像素对齐后: \(alignedRect)")
            print("   转换后区域: \(convertedRect)")
            print("   输出分辨率: \(alignedWidth)x\(alignedHeight) (1:1采样)")
        } else {
            let nativeDimensions = nativeDisplayPixelDimensions(for: filter, display: display)
            config.width = nativeDimensions.width
            config.height = nativeDimensions.height
            config.queueDepth = 5
            config.colorSpaceName = CGColorSpace.sRGB

            print("📺 显示器信息:")
            print("   Display ID: \(display.displayID)")
            print("   Frame: \(display.frame)")
            print("   ScreenCaptureKit报告: \(display.width)x\(display.height)")
            print("   像素倍率: \(nativeDimensions.scaleFactor)")
            print("   分辨率来源: \(nativeDimensions.source)")
            print("   最终录制分辨率: \(nativeDimensions.width)x\(nativeDimensions.height)")
        }

        recordingMetrics.configure(
            mode: recordingModeName,
            displayID: display.displayID,
            recordingRect: recordingRect,
            outputWidth: config.width,
            outputHeight: config.height,
            pixelFormat: screenCapturePixelFormat
        )
        
        // 创建并配置stream
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        
        // 设置视频写入器
        try setupVideoWriter(width: config.width, height: config.height, outputURL: outputURL)
        
        // 设置音频录制
        if self.systemAudioEnabled || self.microphoneEnabled {
            try setupAudioCapture(
                systemAudioEnabled: self.systemAudioEnabled, 
                microphoneEnabled: self.microphoneEnabled,
                microphoneAudioDeviceID: self.microphoneAudioDeviceID
            )
        }
        
        // 在添加所有输入后，开始写入会话
        guard let writer = videoWriter else {
            throw RecordingError.writerNotFound
        }
        guard writer.startWriting() else {
            print("❌ AVAssetWriter 启动失败: \(writer.error?.localizedDescription ?? "未知错误")")
            print("   输出路径: \(outputURL.path)")
            throw RecordingError.writerSetupFailed
        }
        print("✅ AVAssetWriter 开始写入")
        
        // 添加视频输出回调
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "videoQueue"))
        
        // 开始捕获
        try await stream?.startCapture()

        if enableCameraOverlay {
            startCameraTrackRecording()
        }
        
        // 启动AVAudioEngine麦克风录制 (仅macOS 13-14)
        if #available(macOS 15.0, *) {
            // macOS 15+使用SCK，无需额外启动AVAudioEngine
        } else {
            if let avRecorder = avAudioEngineRecorder,
               let micInput = microphoneWriterInput {
                try avRecorder.startRecording(writerInput: micInput)
                print("🎤 AVAudioEngine开始录制麦克风")
            }
        }
        
        print("📹 Stream配置完成 - 分辨率: \(config.width)x\(config.height)")
    }

    private func ownShareableWindows(in availableContent: SCShareableContent?) -> [SCWindow] {
        guard let availableContent else { return [] }

        let processID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let appWindowIDs = Set(NSApp.windows.map { CGWindowID($0.windowNumber) }.filter { $0 > 0 })

        return availableContent.windows.filter { window in
            window.owningApplication?.processID == processID || appWindowIDs.contains(window.windowID)
        }
    }
    
    // MARK: - 音频录制设置
    private func setupAudioCapture(
        systemAudioEnabled: Bool,
        microphoneEnabled: Bool,
        microphoneAudioDeviceID: AudioDeviceID?
    ) throws {
        print("🎤 设置音频录制 - 系统音频: \(systemAudioEnabled), 麦克风: \(microphoneEnabled)")
        
        guard let videoWriter = videoWriter else {
            throw RecordingError.writerNotFound
        }
        
        // 设置系统音频录制
        if systemAudioEnabled {
            try setupSystemAudioInput(videoWriter: videoWriter)
            try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audioQueue"))
            print("✅ 系统音频录制已启用")
        }
        
        // 设置麦克风录制
        if microphoneEnabled {
            if #available(macOS 15.0, *) {
                // macOS 15+: 使用ScreenCaptureKit原生支持
                try setupMicrophoneInput(videoWriter: videoWriter)
                try stream?.addStreamOutput(self, type: .microphone, sampleHandlerQueue: DispatchQueue(label: "microphoneQueue"))
                print("✅ 麦克风录制已启用 (SCK原生支持)")
            } else {
                // macOS 13-14: 使用AVAudioEngine
                try setupAVAudioEngineMicrophone(
                    videoWriter: videoWriter,
                    deviceID: microphoneAudioDeviceID
                )
                print("✅ 麦克风录制已启用 (AVAudioEngine兼容方案)")
            }
        }
    }
    
    private func setupSystemAudioInput(videoWriter: AVAssetWriter) throws {
        // 配置系统音频输入
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192000
        ]
        
        audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioWriterInput?.expectsMediaDataInRealTime = true
        
        guard let audioInput = audioWriterInput else {
            throw RecordingError.audioSetupFailed
        }
        
        guard videoWriter.canAdd(audioInput) else {
            throw RecordingError.audioSetupFailed
        }
        
        videoWriter.add(audioInput)
        print("🔊 系统音频输入已配置")
    }
    
    // MARK: - AVAudioEngine麦克风设置
    private func setupAVAudioEngineMicrophone(videoWriter: AVAssetWriter, deviceID: AudioDeviceID?) throws {
        // 配置麦克风音频输入
        let micSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,  // 立体声
            AVEncoderBitRateKey: 192000
        ]
        
        microphoneWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
        microphoneWriterInput?.expectsMediaDataInRealTime = true
        
        guard let micInput = microphoneWriterInput else {
            throw RecordingError.audioSetupFailed
        }
        
        guard videoWriter.canAdd(micInput) else {
            throw RecordingError.audioSetupFailed
        }
        
        videoWriter.add(micInput)
        
        // 创建并配置AVAudioEngine录制器
        avAudioEngineRecorder = AVAudioEngineRecorder()
        
        // 设置音频设备
        if let deviceID {
            avAudioEngineRecorder?.setInputDevice(deviceID: deviceID)
        }
        
        print("🎤 AVAudioEngine麦克风录制已配置")
    }
    
    @available(macOS 15.0, *)
    private func setupMicrophoneInput(videoWriter: AVAssetWriter) throws {
        // 配置麦克风音频输入（独立轨道）
        let micSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,  // 麦克风通常是单声道
            AVEncoderBitRateKey: 128000
        ]
        
        microphoneWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
        microphoneWriterInput?.expectsMediaDataInRealTime = true
        
        guard let micInput = microphoneWriterInput else {
            throw RecordingError.audioSetupFailed
        }
        
        guard videoWriter.canAdd(micInput) else {
            throw RecordingError.audioSetupFailed
        }
        
        videoWriter.add(micInput)
        print("🎤 SCK麦克风输入已配置")
    }
    
    // MARK: - 视频写入器设置
    private func setupVideoWriter(width: Int, height: Int, outputURL: URL) throws {
        // 删除已存在的文件
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        
        // 创建视频写入器（使用 .mov 以便后续混音和兼容性更好）
        videoWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        
        guard let writer = videoWriter else {
            throw RecordingError.writerSetupFailed
        }
        
        // First quality step: raise the encoder bitrate while keeping the
        // capture pipeline unchanged. This improves text/detail clarity without
        // reintroducing the SCK startup pressure from later experiments.
        let totalPixels = width * height
        let bitsPerPixel: Double
        
        // 🎯 关键优化：区域录制使用更高的单位像素码率
        // 因为区域录制通常包含更多细节内容（如代码、文字）
        if !isFullScreen {
            // 区域录制：提高单位像素码率
            if totalPixels > 1920 * 1080 {
                bitsPerPixel = 0.24  // 更高质量
            } else if totalPixels > 1280 * 720 {
                bitsPerPixel = 0.28
            } else {
                bitsPerPixel = 0.32  // 小区域使用最高质量
            }
        } else {
            // 全屏录制：标准码率
            if totalPixels > 1920 * 1080 {
                bitsPerPixel = 0.18
            } else if totalPixels > 1280 * 720 {
                bitsPerPixel = 0.20
            } else {
                bitsPerPixel = 0.22
            }
        }
        
        let minimumBitRate = isFullScreen ? 12_000_000 : 16_000_000
        let bitRate = max(minimumBitRate, Int(Double(totalPixels) * bitsPerPixel * Double(Self.screenTargetFrameRate)))
        
        print("🎥 编码优化设置:")
        print("   分辨率: \(width)x\(height)")
        print("   像素总数: \(totalPixels)")
        print("   单位像素码率: \(bitsPerPixel) bits/pixel/frame")
        print("   总码率: \(bitRate) bps (\(bitRate/1000000) Mbps)")
        print("   模式: \(isFullScreen ? "全屏" : "区域")")
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: Self.rec709VideoColorProperties(),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoMaxKeyFrameIntervalKey: Self.screenTargetFrameRate / 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: Self.screenTargetFrameRate,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                // 额外的质量参数
                AVVideoQualityKey: isFullScreen ? 0.85 : 0.95  // 区域录制使用更高质量
            ]
        ]
        
        videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput?.expectsMediaDataInRealTime = true
        
        guard let writerInput = videoWriterInput else {
            throw RecordingError.writerSetupFailed
        }
        
        // 像素缓冲适配器
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        
        pixelBufferAdapter = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )
        
        writer.add(writerInput)
        
        // 注意：不在这里调用 startWriting()，需要先添加音频输入
        
        recordingStartTime = CMTime.zero
        
        print("🎥 视频写入器配置完成")
    }

    // MARK: - 独立摄像头视频轨
    private func startCameraTrackRecording() {
        guard !isCameraTrackRecording, let outputURL else { return }

        cameraOutputURL = Self.siblingOutputURL(for: outputURL, suffix: "camera", extension: "mov")
        overlayMetadataURL = Self.siblingOutputURL(for: outputURL, suffix: "overlay", extension: "json")
        cameraFrameCount = 0
        cameraFirstFrameTime = nil
        cameraOutputDimensions = nil
        overlayMetadataStartTime = nil
        lastCameraElapsedTime = nil
        overlayMetadataSamples = []

        if let cameraOutputURL, FileManager.default.fileExists(atPath: cameraOutputURL.path) {
            try? FileManager.default.removeItem(at: cameraOutputURL)
        }
        if let overlayMetadataURL, FileManager.default.fileExists(atPath: overlayMetadataURL.path) {
            try? FileManager.default.removeItem(at: overlayMetadataURL)
        }

        isCameraTrackRecording = true
        cameraManager.setRecordingFrameHandler { [weak self] frame in
            self?.appendCameraFrame(frame)
        }

        print("📷 独立摄像头视频轨开始: \(cameraOutputURL?.lastPathComponent ?? "")")
    }

    private var recordedFrameCount = 0

    private func appendCameraFrame(_ frame: CameraFrameSample) {
        guard !isPaused else { return }
        guard let videoStartTime = firstVideoFrameTime else { return }

        let sourceTime = frame.timestamp.isValid
            ? frame.timestamp
            : CMTime(value: CMTimeValue(frame.sequence), timescale: 30)

        guard sourceTime >= videoStartTime else { return }

        let processedFrame = CameraFrameProcessor.mirroredVisibleImage(from: frame.pixelBuffer)

        do {
            if cameraWriter == nil {
                let dimensions = CameraFrameProcessor.evenDimensions(for: processedFrame.extent.size)
                try setupCameraVideoWriter(width: dimensions.width, height: dimensions.height)
            }
        } catch {
            print("❌ 摄像头视频写入器创建失败: \(error.localizedDescription)")
            isCameraTrackRecording = false
            cameraManager.setRecordingFrameHandler(nil)
            return
        }

        guard let writer = cameraWriter,
              let writerInput = cameraWriterInput,
              let adapter = cameraPixelBufferAdapter,
              let dimensions = cameraOutputDimensions,
              writer.status == .writing else {
            return
        }

        if cameraFirstFrameTime == nil {
            cameraFirstFrameTime = videoStartTime
            overlayMetadataStartTime = videoStartTime
            writer.startSession(atSourceTime: .zero)
        }

        let rawPresentationTime = CMTimeSubtract(sourceTime, videoStartTime)
        let presentationTime = rawPresentationTime.isValid && rawPresentationTime >= .zero
            ? rawPresentationTime
            : .zero
        lastCameraElapsedTime = presentationTime.seconds.isFinite ? presentationTime.seconds : lastCameraElapsedTime

        if cameraFrameCount % 8 == 0 {
            captureOverlayMetadataSample(at: lastCameraElapsedTime)
        }

        guard writerInput.isReadyForMoreMediaData,
              let outputPixelBuffer = renderCameraFrame(
                processedFrame.image,
                sourceExtent: processedFrame.extent,
                width: dimensions.width,
                height: dimensions.height,
                adapter: adapter
              ) else {
            return
        }

        if adapter.append(outputPixelBuffer, withPresentationTime: presentationTime) {
            cameraFrameCount += 1
            recordedFrameCount += 1
            if recordedFrameCount % 600 == 0 {
                MemoryFootprint.log("录制中（\(recordedFrameCount) 帧）")
            }
            recordingMetrics.updateCamera(
                received: cameraManager.receivedFrameCount,
                written: cameraFrameCount,
                dropped: cameraManager.droppedFrameCount
            )
        } else {
            print("⚠️  摄像头帧写入失败: \(cameraFrameCount)，写入器: \(cameraWriter?.error?.localizedDescription ?? "未报错")")
        }
    }

    private func setupCameraVideoWriter(width: Int, height: Int) throws {
        guard let cameraOutputURL else { return }

        cameraWriter = try AVAssetWriter(outputURL: cameraOutputURL, fileType: .mov)
        guard let writer = cameraWriter else {
            throw RecordingError.writerSetupFailed
        }

        let bitRate = max(4_000_000, width * height * 4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: Self.rec709VideoColorProperties(),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoQualityKey: 0.9
            ]
        ]

        cameraWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        cameraWriterInput?.expectsMediaDataInRealTime = true

        guard let writerInput = cameraWriterInput, writer.canAdd(writerInput) else {
            throw RecordingError.writerSetupFailed
        }

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        cameraPixelBufferAdapter = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw RecordingError.writerSetupFailed
        }

        cameraOutputDimensions = (width, height)
        print("📷 摄像头视频写入器配置完成: \(width)x\(height)")
    }

    private func renderCameraFrame(
        _ image: CIImage,
        sourceExtent: CGRect,
        width: Int,
        height: Int,
        adapter: AVAssetWriterInputPixelBufferAdaptor
    ) -> CVPixelBuffer? {
        guard let pixelBufferPool = adapter.pixelBufferPool else { return nil }

        var outputPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &outputPixelBuffer)
        guard status == kCVReturnSuccess, let outputPixelBuffer else {
            return nil
        }

        let outputExtent = CGRect(x: 0, y: 0, width: width, height: height)
        let scaledImage = Self.aspectFill(
            image,
            sourceExtent: sourceExtent,
            targetRect: outputExtent
        )

        cameraCIContext.render(
            scaledImage,
            to: outputPixelBuffer,
            bounds: outputExtent,
            colorSpace: Self.sharedDeviceRGBColorSpace
        )

        return outputPixelBuffer
    }

    private func stopCameraTrackRecording() async {
        isCameraTrackRecording = false
        cameraManager.setRecordingFrameHandler(nil)

        captureOverlayMetadataSample(at: lastCameraElapsedTime)

        if let writer = cameraWriter {
            cameraWriterInput?.markAsFinished()
            await writer.finishWriting()

            switch writer.status {
            case .completed:
                print("✅ 摄像头视频保存成功: \(cameraOutputURL?.lastPathComponent ?? "")")
            case .failed:
                print("❌ 摄像头视频保存失败: \(writer.error?.localizedDescription ?? "未知错误")")
            case .cancelled:
                print("⚠️  摄像头视频写入被取消")
            default:
                print("⚠️  摄像头视频写入状态未知: \(writer.status.rawValue)")
            }
        }

        recordingMetrics.updateCamera(
            received: cameraManager.receivedFrameCount,
            written: cameraFrameCount,
            dropped: cameraManager.droppedFrameCount
        )

        writeOverlayMetadataFile()

        cameraWriter = nil
        cameraWriterInput = nil
        cameraPixelBufferAdapter = nil
        cameraOutputDimensions = nil
        cameraFirstFrameTime = nil
        overlayMetadataStartTime = nil
        lastCameraElapsedTime = nil
        overlayMetadataSamples = []
    }

    private func captureOverlayMetadataSample(at elapsedTime: Double? = nil) {
        guard enableCameraOverlay,
              overlayMetadataStartTime != nil,
              let snapshot = cameraOverlaySnapshotProvider?() else {
            return
        }

        let elapsedTime = elapsedTime ?? lastCameraElapsedTime ?? 0
        let sample = CameraOverlayMetadataSample(
            time: elapsedTime,
            frame: CodableRect(snapshot.frame),
            shape: metadataValue(for: snapshot.shape),
            size: metadataValue(for: snapshot.size)
        )

        if let lastSample = overlayMetadataSamples.last,
           abs(lastSample.time - sample.time) < 0.2,
           lastSample.frame == sample.frame,
           lastSample.shape == sample.shape,
           lastSample.size == sample.size {
            return
        }

        overlayMetadataSamples.append(sample)
    }

    private func writeOverlayMetadataFile() {
        guard let overlayMetadataURL, let outputURL else { return }

        let metadata = CameraOverlayMetadataFile(
            version: 1,
            screenFile: outputURL.lastPathComponent,
            cameraFile: cameraOutputURL?.lastPathComponent,
            coordinateSpace: "macOS global screen points; origin is bottom-left",
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            recordingMode: recordingModeName,
            recordingRect: recordingRect.map(CodableRect.init),
            samples: overlayMetadataSamples
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            try data.write(to: overlayMetadataURL)
            print("✅ 摄像头叠加元数据保存成功: \(overlayMetadataURL.lastPathComponent)")
        } catch {
            print("❌ 摄像头叠加元数据保存失败: \(error.localizedDescription)")
        }
    }

    private nonisolated static func siblingOutputURL(for outputURL: URL, suffix: String, extension pathExtension: String) -> URL {
        let baseName = outputURL.deletingPathExtension().lastPathComponent
        return outputURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(baseName)_\(suffix)")
            .appendingPathExtension(pathExtension)
    }

    private func metadataValue(for shape: CameraOverlayShape) -> String {
        switch shape {
        case .circle:
            return "circle"
        case .roundedSquare:
            return "roundedRectangle"
        case .roundedBox:
            return "roundedSquare"
        }
    }

    private func metadataValue(for size: CameraOverlaySize) -> String {
        switch size {
        case .small:
            return "small"
        case .medium:
            return "medium"
        case .large:
            return "large"
        }
    }

    // MARK: - 自动合成视频
    private nonisolated static func exportCompositedVideoIfNeeded(
        for screenURL: URL,
        cameraURL: URL?,
        overlayMetadataURL: URL?,
        exportSettings: RecordingExportSettings
    ) async -> URL? {
        guard let cameraURL,
              let overlayMetadataURL,
              FileManager.default.fileExists(atPath: cameraURL.path),
              FileManager.default.fileExists(atPath: overlayMetadataURL.path) else {
            return nil
        }

        let compositedURL = Self.siblingOutputURL(for: screenURL, suffix: "composited", extension: "mov")
        let tempVideoURL = Self.siblingOutputURL(for: screenURL, suffix: "composited_video_tmp", extension: "mov")

        do {
            let metadataData = try Data(contentsOf: overlayMetadataURL)
            let metadata = try JSONDecoder().decode(CameraOverlayMetadataFile.self, from: metadataData)

            try? FileManager.default.removeItem(at: compositedURL)
            try? FileManager.default.removeItem(at: tempVideoURL)

            print("🎞️  开始合成视频: \(compositedURL.lastPathComponent)")
            let rendered = try Self.renderCompositedVideo(
                screenURL: screenURL,
                cameraURL: cameraURL,
                metadata: metadata,
                outputURL: tempVideoURL,
                exportSettings: exportSettings
            )

            guard rendered else {
                print("❌ 合成视频渲染失败")
                return nil
            }

            let muxed = await Self.muxAudioFromScreenVideo(
                screenURL: screenURL,
                videoOnlyURL: tempVideoURL,
                outputURL: compositedURL
            )

            if muxed {
                try? FileManager.default.removeItem(at: tempVideoURL)
                print("✅ 合成视频保存成功: \(compositedURL.lastPathComponent)")
            } else {
                try FileManager.default.moveItem(at: tempVideoURL, to: compositedURL)
                print("✅ 合成视频保存成功（无音频复用）: \(compositedURL.lastPathComponent)")
            }
            return compositedURL
        } catch {
            print("❌ 合成视频失败: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempVideoURL)
            return nil
        }
    }

    private nonisolated static func exportTransparentCameraVideoIfNeeded(
        for screenURL: URL,
        cameraURL: URL?,
        overlayMetadataURL: URL?,
        exportSettings: RecordingExportSettings
    ) async -> URL? {
        guard let cameraURL,
              let overlayMetadataURL,
              FileManager.default.fileExists(atPath: cameraURL.path),
              FileManager.default.fileExists(atPath: overlayMetadataURL.path) else {
            return nil
        }

        let cameraOnlyURL = Self.siblingOutputURL(for: screenURL, suffix: "camera_only", extension: "mov")

        do {
            let metadataData = try Data(contentsOf: overlayMetadataURL)
            let metadata = try JSONDecoder().decode(CameraOverlayMetadataFile.self, from: metadataData)
            guard !metadata.samples.isEmpty else { return nil }

            try? FileManager.default.removeItem(at: cameraOnlyURL)

            print("🎞️  Rendering transparent camera video: \(cameraOnlyURL.lastPathComponent)")
            let rendered = try Self.renderTransparentCameraVideo(
                screenURL: screenURL,
                cameraURL: cameraURL,
                metadata: metadata,
                outputURL: cameraOnlyURL,
                exportSettings: exportSettings
            )

            guard rendered else {
                print("❌ Transparent camera render failed")
                try? FileManager.default.removeItem(at: cameraOnlyURL)
                return nil
            }

            print("✅ Transparent camera video saved: \(cameraOnlyURL.lastPathComponent)")
            return cameraOnlyURL
        } catch {
            print("❌ Transparent camera render failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: cameraOnlyURL)
            return nil
        }
    }

    private nonisolated static func exportEditedRecordingIfNeeded(
        for screenURL: URL,
        cameraURL: URL?,
        overlayMetadataURL: URL?,
        decision: RecordingEditDecision,
        exportSettings: RecordingExportSettings
    ) async -> URL? {
        let editedURL = Self.siblingOutputURL(for: screenURL, suffix: "edited", extension: "mov")
        let tempVideoURL = Self.siblingOutputURL(for: screenURL, suffix: "edited_video_tmp", extension: "mov")

        do {
            let metadata = overlayMetadataURL.flatMap { url -> CameraOverlayMetadataFile? in
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(CameraOverlayMetadataFile.self, from: data)
            }

            try? FileManager.default.removeItem(at: editedURL)
            try? FileManager.default.removeItem(at: tempVideoURL)

            print("🎞️  Rendering edited recording: \(editedURL.lastPathComponent)")
            let rendered = try Self.renderEditedVideo(
                screenURL: screenURL,
                cameraURL: cameraURL,
                metadata: metadata,
                decision: decision,
                outputURL: tempVideoURL,
                exportSettings: exportSettings
            )

            guard rendered else {
                print("❌ Edited recording render failed")
                try? FileManager.default.removeItem(at: tempVideoURL)
                return nil
            }

            let muxed = await Self.muxAudioFromScreenVideo(
                screenURL: screenURL,
                videoOnlyURL: tempVideoURL,
                outputURL: editedURL,
                cuts: decision.cuts
            )

            if muxed {
                try? FileManager.default.removeItem(at: tempVideoURL)
                print("✅ Edited recording saved: \(editedURL.lastPathComponent)")
            } else {
                try FileManager.default.moveItem(at: tempVideoURL, to: editedURL)
                print("✅ Edited recording saved without audio remux: \(editedURL.lastPathComponent)")
            }

            return editedURL
        } catch {
            print("❌ Edited recording render failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempVideoURL)
            return nil
        }
    }

    private nonisolated static func renderCompositedVideo(
        screenURL: URL,
        cameraURL: URL,
        metadata: CameraOverlayMetadataFile,
        outputURL: URL,
        exportSettings: RecordingExportSettings
    ) throws -> Bool {
        let screenAsset = AVURLAsset(url: screenURL)
        let cameraAsset = AVURLAsset(url: cameraURL)

        guard let screenTrack = screenAsset.tracks(withMediaType: .video).first,
              let cameraTrack = cameraAsset.tracks(withMediaType: .video).first else {
            return false
        }

        let screenSize = Self.normalizedVideoSize(for: screenTrack)
        let outputSize = exportSettings.canvasSize(for: screenSize)
        let outputWidth = Int(outputSize.width)
        let outputHeight = Int(outputSize.height)

        let screenReader = try AVAssetReader(asset: screenAsset)
        let cameraReader = try AVAssetReader(asset: cameraAsset)

        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        let screenOutput = AVAssetReaderTrackOutput(track: screenTrack, outputSettings: readerSettings)
        screenOutput.alwaysCopiesSampleData = false
        guard screenReader.canAdd(screenOutput) else { return false }
        screenReader.add(screenOutput)

        let cameraOutput = AVAssetReaderTrackOutput(track: cameraTrack, outputSettings: readerSettings)
        cameraOutput.alwaysCopiesSampleData = false
        guard cameraReader.canAdd(cameraOutput) else { return false }
        cameraReader.add(cameraOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let compositedBitRate = exportSettings.averageBitRate(for: outputSize)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoColorPropertiesKey: Self.rec709VideoColorProperties(),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: compositedBitRate,
                AVVideoMaxKeyFrameIntervalKey: Self.screenTargetFrameRate / 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: Self.screenTargetFrameRate,
                AVVideoQualityKey: exportSettings.bitRatePreset.compressionQuality
            ]
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let adapter = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard writer.canAdd(writerInput) else { return false }
        writer.add(writerInput)

        guard screenReader.startReading(),
              cameraReader.startReading(),
              writer.startWriting() else {
            return false
        }

        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext()
        var currentCameraPixelBuffer: CVPixelBuffer?
        var currentCameraTime = CMTime.zero
        var nextCameraSample = cameraOutput.copyNextSampleBuffer()
        var maskCache: [String: CIImage] = [:]
        let bufferExtent = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        _ = bufferExtent
        // 合成阶段始终按「未裁切」的完整画面布局，气泡坐标才不会整体偏移；
        // 裁切放在最后一步，只影响输出尺寸。
        let composeSize: CGSize
        if exportSettings.canvasAspect == .source && exportSettings.cropTo16x9 {
            composeSize = exportSettings.resolutionPreset.outputSize(for: screenSize)
        } else {
            composeSize = CGSize(width: outputWidth, height: outputHeight)
        }
        let outputExtent = CGRect(origin: .zero, size: composeSize)

        // 自绘光标：事件轨存在才启用（录制时源画面已隐藏系统光标）
        let cursorTrack = CursorEventStore.load(from: CursorEventStore.cursorURL(for: screenURL))
        var cursorSampler = CursorEventSampler(samples: cursorTrack?.events ?? [])
        let cursorCI: CIImage? = cursorTrack == nil ? nil : CursorRenderer.arrowCGImage().map { CIImage(cgImage: $0) }
        let rippleCI: CIImage? = cursorTrack == nil ? nil : CursorRenderer.rippleCGImage().map { CIImage(cgImage: $0) }
        // 自动缩放：点击聚焦区间
        let zoomRanges = ZoomRangeStore.load(from: ZoomRangeStore.zoomURL(for: screenURL))?.ranges ?? []
        let beautifyPadding = exportSettings.beautifyEnabled ? exportSettings.beautifyPaddingRatio : 0
        let beautifyRadius = exportSettings.beautifyEnabled ? exportSettings.beautifyCornerRadiusPoints : 0
        let cursorContentRect = CursorRenderer.contentRect(
            sourceExtent: CGRect(origin: .zero, size: screenSize),
            in: outputExtent,
            paddingRatio: beautifyPadding
        )

        func advanceCameraFrame(to screenTime: CMTime) {
            while let sample = nextCameraSample {
                let sampleTime = CMSampleBufferGetPresentationTimeStamp(sample)
                guard sampleTime <= screenTime || currentCameraPixelBuffer == nil else {
                    break
                }

                if let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
                    currentCameraPixelBuffer = pixelBuffer
                    currentCameraTime = sampleTime
                }

                nextCameraSample = cameraOutput.copyNextSampleBuffer()
            }
        }

        // 每帧都会产生一批自动释放对象（CIImage、CGImage、渲染中间结果）。
        // 没有 autoreleasepool 的话它们要等到整个导出结束才释放：
        // 4K 一帧约 33 MB，几分钟的录像就能把内存推到几十 GB。
        let renderColorSpace = CGColorSpaceCreateDeviceRGB()
        var composedFrameCount = 0

        while let screenSample = screenOutput.copyNextSampleBuffer() {
            let screenTime = CMSampleBufferGetPresentationTimeStamp(screenSample)

            autoreleasepool {
                advanceCameraFrame(to: screenTime)

                guard let screenPixelBuffer = CMSampleBufferGetImageBuffer(screenSample),
                      let outputPixelBuffer = Self.createPixelBuffer(from: adapter) else {
                    return
                }

                let rawScreenImage = CIImage(cvPixelBuffer: screenPixelBuffer)
                let seconds = max(0, CMTimeGetSeconds(screenTime))
                let zoomCrop = ZoomTimeline.activeCrop(at: seconds, ranges: zoomRanges)
                let screenImage = zoomCrop.map { Self.zoomCroppedImage(rawScreenImage, crop: $0) } ?? rawScreenImage
                let cameraImage = currentCameraPixelBuffer.map { CIImage(cvPixelBuffer: $0) }
                let sample = Self.overlaySample(at: seconds, in: metadata.samples)
                var composedImage = Self.composeScreenImage(
                    screenImage,
                    cameraImage: cameraImage,
                    overlaySample: sample,
                    metadata: metadata,
                    outputExtent: outputExtent,
                    maskCache: &maskCache,
                    beautifyPaddingRatio: beautifyPadding,
                    beautifyCornerRadiusPoints: beautifyRadius
                )

                if !cursorSampler.isEmpty, let cursorCI, let rippleCI {
                    composedImage = CursorRenderer.applyCursor(
                        to: composedImage,
                        sampler: &cursorSampler,
                        at: seconds,
                        contentRect: cursorContentRect,
                        cursorCI: cursorCI,
                        rippleCI: rippleCI,
                        crop: zoomCrop
                    )
                }

                let finalImage = (exportSettings.cropTo16x9 && exportSettings.canvasAspect == .source)
                    ? Self.cropToAspect(composedImage, from: outputExtent, to: bufferExtent)
                    : composedImage
                ciContext.render(
                    finalImage,
                    to: outputPixelBuffer,
                    bounds: bufferExtent,
                    colorSpace: renderColorSpace
                )

                while !writerInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.002)
                }

                let presentationTime = screenTime.isValid ? screenTime : currentCameraTime
                adapter.append(outputPixelBuffer, withPresentationTime: presentationTime)
                composedFrameCount += 1
                if composedFrameCount % 300 == 0 {
                    MemoryFootprint.log("合成中（\(composedFrameCount) 帧）")
                }
            }
        }

        writerInput.markAsFinished()
        screenReader.cancelReading()
        cameraReader.cancelReading()

        let completed = DispatchSemaphore(value: 0)
        writer.finishWriting {
            completed.signal()
        }
        completed.wait()

        return writer.status == .completed
    }

    private nonisolated static func renderEditedVideo(
        screenURL: URL,
        cameraURL: URL?,
        metadata: CameraOverlayMetadataFile?,
        decision: RecordingEditDecision,
        outputURL: URL,
        exportSettings: RecordingExportSettings
    ) throws -> Bool {
        let screenAsset = AVURLAsset(url: screenURL)
        guard let screenTrack = screenAsset.tracks(withMediaType: .video).first else {
            return false
        }

        let screenSize = Self.normalizedVideoSize(for: screenTrack)
        let outputSize = exportSettings.canvasSize(for: screenSize)
        let outputWidth = Int(outputSize.width)
        let outputHeight = Int(outputSize.height)
        let bufferExtent = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        // 合成阶段始终按「未裁切」的完整画面布局，气泡坐标才不会整体偏移；
        // 裁切放在最后一步，只影响输出尺寸。指定了发布画幅时画布即输出。
        let composeSize: CGSize
        if exportSettings.canvasAspect == .source && exportSettings.cropTo16x9 {
            composeSize = exportSettings.resolutionPreset.outputSize(for: screenSize)
        } else {
            composeSize = CGSize(width: outputWidth, height: outputHeight)
        }
        let outputExtent = CGRect(origin: .zero, size: composeSize)

        // 自绘光标：事件轨存在才启用（录制时源画面已隐藏系统光标）。
        // 时间轴与剪辑映射一致：光标 t 就是源视频时间轴。
        let cursorTrack = CursorEventStore.load(from: CursorEventStore.cursorURL(for: screenURL))
        var cursorSampler = CursorEventSampler(samples: cursorTrack?.events ?? [])
        let cursorCI: CIImage? = cursorTrack == nil ? nil : CursorRenderer.arrowCGImage().map { CIImage(cgImage: $0) }
        let rippleCI: CIImage? = cursorTrack == nil ? nil : CursorRenderer.rippleCGImage().map { CIImage(cgImage: $0) }
        // 自动缩放：点击聚焦区间（停录时由光标事件轨生成）
        let zoomRanges = ZoomRangeStore.load(from: ZoomRangeStore.zoomURL(for: screenURL))?.ranges ?? []
        let beautifyPadding = exportSettings.beautifyEnabled ? exportSettings.beautifyPaddingRatio : 0
        let beautifyRadius = exportSettings.beautifyEnabled ? exportSettings.beautifyCornerRadiusPoints : 0
        let cursorContentRect = CursorRenderer.contentRect(
            sourceExtent: CGRect(origin: .zero, size: screenSize),
            in: outputExtent,
            paddingRatio: beautifyPadding
        )

        let screenReader = try AVAssetReader(asset: screenAsset)
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        let screenOutput = AVAssetReaderTrackOutput(track: screenTrack, outputSettings: readerSettings)
        screenOutput.alwaysCopiesSampleData = false
        guard screenReader.canAdd(screenOutput) else { return false }
        screenReader.add(screenOutput)

        var cameraReader: AVAssetReader?
        var cameraOutput: AVAssetReaderTrackOutput?
        if let cameraURL {
            let cameraAsset = AVURLAsset(url: cameraURL)
            if let cameraTrack = cameraAsset.tracks(withMediaType: .video).first {
                let reader = try AVAssetReader(asset: cameraAsset)
                let output = AVAssetReaderTrackOutput(track: cameraTrack, outputSettings: readerSettings)
                output.alwaysCopiesSampleData = false
                if reader.canAdd(output) {
                    reader.add(output)
                    cameraReader = reader
                    cameraOutput = output
                }
            }
        }

        let resolvedCuts = Self.resolvedEditCuts(
            decision.cuts,
            totalDuration: CMTimeGetSeconds(screenAsset.duration),
            hasCamera: cameraOutput != nil
        )
        guard !resolvedCuts.isEmpty else { return false }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let editedBitRate = exportSettings.averageBitRate(for: outputSize)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoColorPropertiesKey: Self.rec709VideoColorProperties(),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: editedBitRate,
                AVVideoMaxKeyFrameIntervalKey: Self.screenTargetFrameRate / 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: Self.screenTargetFrameRate,
                AVVideoQualityKey: exportSettings.bitRatePreset.compressionQuality
            ]
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let adapter = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard writer.canAdd(writerInput) else { return false }
        writer.add(writerInput)

        guard screenReader.startReading(),
              writer.startWriting() else {
            return false
        }

        if cameraReader?.startReading() != true {
            cameraReader = nil
            cameraOutput = nil
        }

        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext()
        var currentCameraPixelBuffer: CVPixelBuffer?
        var nextCameraSample = cameraOutput?.copyNextSampleBuffer()
        var maskCache: [String: CIImage] = [:]
        var cutIndex = 0

        func advanceCameraFrame(to screenTime: CMTime) {
            while let sample = nextCameraSample {
                let sampleTime = CMSampleBufferGetPresentationTimeStamp(sample)
                guard sampleTime <= screenTime || currentCameraPixelBuffer == nil else {
                    break
                }

                if let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
                    currentCameraPixelBuffer = pixelBuffer
                }

                nextCameraSample = cameraOutput?.copyNextSampleBuffer()
            }
        }

        enum FrameOutcome { case skip, proceed, stop }
        let renderColorSpace = CGColorSpaceCreateDeviceRGB()
        var editedFrameCount = 0

        // 恒定帧率输出：屏幕录制是变帧率（画面不变就不出帧），
        // 直接写进 60fps 容器会在播放器里表现为顿挫。
        // 这里把时间量化到 30fps 网格，空洞用上一帧补齐，输出真正的 CFR。
        let outputTimescale: CMTimeScale = 30
        var lastWrittenSlot: Int64 = -1
        var lastFinalImage: CIImage?

        func appendFrame(_ image: CIImage, atSlot slot: Int64) -> Bool {
            guard let buffer = Self.createPixelBuffer(from: adapter) else { return false }
            ciContext.render(image, to: buffer, bounds: bufferExtent, colorSpace: renderColorSpace)
            while !writerInput.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
            }
            return adapter.append(buffer, withPresentationTime: CMTime(value: slot, timescale: outputTimescale))
        }

        /// 把 [from, to] 之间的空槽用上一帧填满
        func fillGap(upTo slot: Int64, with image: CIImage?) {
            guard let image else { return }
            var next = lastWrittenSlot + 1
            while next < slot {
                _ = appendFrame(image, atSlot: next)
                next += 1
            }
            lastWrittenSlot = max(lastWrittenSlot, slot - 1)
        }

        // 关键：合成时钟由输出帧率驱动，不是由屏幕帧驱动。
        // 屏幕录制是变帧率（画面不动就不出帧，实测空洞可达 20~40 秒），
        // 按屏幕帧驱动的话，屏幕一静止整个人像就冻结，看起来就是卡顿。
        // 这里每一拍分别取「最新屏幕帧」和「最新摄像头帧」，两者独立推进。
        var currentScreenSample: CMSampleBuffer?
        var nextScreenSample = screenOutput.copyNextSampleBuffer()

        func advanceScreenFrame(to time: CMTime) {
            while let sample = nextScreenSample {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if pts > time, currentScreenSample != nil { break }
                currentScreenSample = sample
                nextScreenSample = screenOutput.copyNextSampleBuffer()
            }
        }

        let totalOutputSeconds = resolvedCuts.reduce(0.0) { $0 + max(0, $1.endSeconds - $1.startSeconds) }
        let totalTicks = max(0, Int((totalOutputSeconds * Double(outputTimescale)).rounded()))
        var tick = 0
        var activeCutIndex = 0

        while tick <= totalTicks {
            let outputSeconds = Double(tick) / Double(outputTimescale)

            while activeCutIndex < resolvedCuts.count,
                  outputSeconds >= resolvedCuts[activeCutIndex].outputStartSeconds
                    + (resolvedCuts[activeCutIndex].endSeconds - resolvedCuts[activeCutIndex].startSeconds) {
                activeCutIndex += 1
            }
            guard activeCutIndex < resolvedCuts.count else { break }

            let resolvedCut = resolvedCuts[activeCutIndex]
            let sourceSeconds = resolvedCut.startSeconds + (outputSeconds - resolvedCut.outputStartSeconds)
            let sourceTime = CMTime(seconds: sourceSeconds, preferredTimescale: 600)

            advanceScreenFrame(to: sourceTime)
            advanceCameraFrame(to: sourceTime)

            if let screenSample = currentScreenSample,
               let screenPixelBuffer = CMSampleBufferGetImageBuffer(screenSample),
               let outputPixelBuffer = Self.createPixelBuffer(from: adapter) {

                autoreleasepool {
                    let rawScreenImage = CIImage(cvPixelBuffer: screenPixelBuffer)
                    let zoomCrop = ZoomTimeline.activeCrop(at: sourceSeconds, ranges: zoomRanges)
                    let screenImage = zoomCrop.map { Self.zoomCroppedImage(rawScreenImage, crop: $0) } ?? rawScreenImage
                    let cameraImage = currentCameraPixelBuffer.map { CIImage(cvPixelBuffer: $0) }
                    let overlaySample = metadata.map { Self.overlaySample(at: sourceSeconds, in: $0.samples) } ?? nil
                    var composedImage = Self.composeEditedImage(
                        screenImage,
                        cameraImage: cameraImage,
                        cut: resolvedCut.cut,
                        overlaySample: overlaySample,
                        outputExtent: outputExtent,
                        maskCache: &maskCache,
                        beautifyPaddingRatio: beautifyPadding,
                        beautifyCornerRadiusPoints: beautifyRadius
                    )

                    if !cursorSampler.isEmpty, let cursorCI, let rippleCI,
                       resolvedCut.cut.layoutMode != .cameraFullScreen {
                        composedImage = CursorRenderer.applyCursor(
                            to: composedImage,
                            sampler: &cursorSampler,
                            at: sourceSeconds,
                            contentRect: cursorContentRect,
                            cursorCI: cursorCI,
                            rippleCI: rippleCI,
                            crop: zoomCrop
                        )
                    }

                    let finalImage = (exportSettings.cropTo16x9 && exportSettings.canvasAspect == .source)
                        ? Self.cropToAspect(composedImage, from: outputExtent, to: bufferExtent)
                        : composedImage

                    ciContext.render(finalImage, to: outputPixelBuffer, bounds: bufferExtent, colorSpace: renderColorSpace)
                    while !writerInput.isReadyForMoreMediaData {
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                    _ = adapter.append(outputPixelBuffer, withPresentationTime: CMTime(value: Int64(tick), timescale: outputTimescale))
                    editedFrameCount += 1
                    if editedFrameCount % 300 == 0 {
                        MemoryFootprint.log("剪辑合成中（\(editedFrameCount) 帧）")
                    }
                }
            }

            tick += 1
        }

        writerInput.markAsFinished()
        screenReader.cancelReading()
        cameraReader?.cancelReading()

        let completed = DispatchSemaphore(value: 0)
        writer.finishWriting {
            completed.signal()
        }
        completed.wait()

        return writer.status == .completed
    }

    private nonisolated static func renderTransparentCameraVideo(
        screenURL: URL,
        cameraURL: URL,
        metadata: CameraOverlayMetadataFile,
        outputURL: URL,
        exportSettings: RecordingExportSettings
    ) throws -> Bool {
        let screenAsset = AVURLAsset(url: screenURL)
        let cameraAsset = AVURLAsset(url: cameraURL)

        guard let screenTrack = screenAsset.tracks(withMediaType: .video).first,
              let cameraTrack = cameraAsset.tracks(withMediaType: .video).first else {
            return false
        }

        let screenSize = Self.normalizedVideoSize(for: screenTrack)
        let outputSize = exportSettings.outputSize(for: screenSize)
        let outputWidth = Int(outputSize.width)
        let outputHeight = Int(outputSize.height)

        let cameraReader = try AVAssetReader(asset: cameraAsset)
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        let cameraOutput = AVAssetReaderTrackOutput(track: cameraTrack, outputSettings: readerSettings)
        cameraOutput.alwaysCopiesSampleData = false
        guard cameraReader.canAdd(cameraOutput) else { return false }
        cameraReader.add(cameraOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let alphaBitRate = max(
            6_000_000,
            exportSettings.averageBitRate(for: outputSize)
        )
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoColorPropertiesKey: Self.rec709VideoColorProperties(),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: alphaBitRate,
                AVVideoMaxKeyFrameIntervalKey: Self.screenTargetFrameRate / 2,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: Self.screenTargetFrameRate,
                AVVideoQualityKey: exportSettings.bitRatePreset.compressionQuality
            ]
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let adapter = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard writer.canAdd(writerInput) else { return false }
        writer.add(writerInput)

        guard cameraReader.startReading(),
              writer.startWriting() else {
            return false
        }

        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext()
        var maskCache: [String: CIImage] = [:]
        let bufferExtent = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        // 合成阶段始终按「未裁切」的完整画面布局，气泡坐标才不会整体偏移；
        // 裁切放在最后一步，只影响输出尺寸。
        let composeSize = exportSettings.cropTo16x9
            ? exportSettings.resolutionPreset.outputSize(for: screenSize)
            : CGSize(width: outputWidth, height: outputHeight)
        let outputExtent = CGRect(origin: .zero, size: composeSize)

        while let cameraSample = cameraOutput.copyNextSampleBuffer() {
            guard let cameraPixelBuffer = CMSampleBufferGetImageBuffer(cameraSample),
                  let outputPixelBuffer = Self.createPixelBuffer(from: adapter) else {
                continue
            }

            let cameraTime = CMSampleBufferGetPresentationTimeStamp(cameraSample)
            let seconds = max(0, CMTimeGetSeconds(cameraTime))
            let sample = Self.overlaySample(at: seconds, in: metadata.samples)
            let composedImage = Self.composeTransparentCameraImage(
                CIImage(cvPixelBuffer: cameraPixelBuffer),
                overlaySample: sample,
                metadata: metadata,
                outputExtent: outputExtent,
                maskCache: &maskCache
            )

            ciContext.render(
                composedImage,
                to: outputPixelBuffer,
                bounds: outputExtent,
                colorSpace: Self.sharedDeviceRGBColorSpace
            )

            while !writerInput.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
            }

            adapter.append(outputPixelBuffer, withPresentationTime: cameraTime.isValid ? cameraTime : .zero)
        }

        writerInput.markAsFinished()
        cameraReader.cancelReading()

        let completed = DispatchSemaphore(value: 0)
        writer.finishWriting {
            completed.signal()
        }
        completed.wait()

        return writer.status == .completed
    }

    private nonisolated static func composeScreenImage(
        _ screenImage: CIImage,
        cameraImage: CIImage?,
        overlaySample: CameraOverlayMetadataSample?,
        metadata: CameraOverlayMetadataFile,
        outputExtent: CGRect,
        maskCache: inout [String: CIImage],
        beautifyPaddingRatio: Double = 0,
        beautifyCornerRadiusPoints: Double = 0
    ) -> CIImage {
        let screenBase = beautifiedOrFittedBase(
            screenImage,
            outputExtent: outputExtent,
            paddingRatio: beautifyPaddingRatio,
            cornerRadiusPoints: beautifyCornerRadiusPoints,
            maskCache: &maskCache
        )

        guard let cameraImage, let overlaySample else {
            return screenBase
        }

        let targetRect = Self.overlayTargetRect(
            from: overlaySample.frame.cgRect,
            metadata: metadata,
            outputExtent: outputExtent
        )

        guard targetRect.width > 1, targetRect.height > 1 else {
            return screenBase
        }

        let scaledCamera = Self.aspectFill(
            cameraImage,
            sourceExtent: cameraImage.extent,
            targetRect: targetRect
        )

        let mask = Self.overlayMask(
            size: targetRect.size,
            shape: overlaySample.shape,
            cache: &maskCache
        ).transformed(by: CGAffineTransform(translationX: targetRect.minX, y: targetRect.minY))

        let blendedImage = scaledCamera.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: screenBase,
            kCIInputMaskImageKey: mask
        ])

        return blendedImage.cropped(to: outputExtent)
    }

    private nonisolated static func composeTransparentCameraImage(
        _ cameraImage: CIImage,
        overlaySample: CameraOverlayMetadataSample?,
        metadata: CameraOverlayMetadataFile,
        outputExtent: CGRect,
        maskCache: inout [String: CIImage]
    ) -> CIImage {
        let transparentBackground = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: outputExtent)

        guard let overlaySample else {
            return transparentBackground
        }

        let targetRect = Self.overlayTargetRect(
            from: overlaySample.frame.cgRect,
            metadata: metadata,
            outputExtent: outputExtent
        )

        guard targetRect.width > 1, targetRect.height > 1 else {
            return transparentBackground
        }

        let scaledCamera = Self.aspectFill(
            cameraImage,
            sourceExtent: cameraImage.extent,
            targetRect: targetRect
        )

        let mask = Self.overlayMask(
            size: targetRect.size,
            shape: overlaySample.shape,
            cache: &maskCache
        ).transformed(by: CGAffineTransform(translationX: targetRect.minX, y: targetRect.minY))

        let blendedImage = scaledCamera.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: transparentBackground,
            kCIInputMaskImageKey: mask
        ])

        return blendedImage.cropped(to: outputExtent)
    }

    private nonisolated static func composeEditedImage(
        _ screenImage: CIImage,
        cameraImage: CIImage?,
        cut: RecordingEditCut,
        overlaySample: CameraOverlayMetadataSample?,
        outputExtent: CGRect,
        maskCache: inout [String: CIImage],
        beautifyPaddingRatio: Double = 0,
        beautifyCornerRadiusPoints: Double = 0
    ) -> CIImage {
        let screenBase = beautifiedOrFittedBase(
            screenImage,
            outputExtent: outputExtent,
            paddingRatio: beautifyPaddingRatio,
            cornerRadiusPoints: beautifyCornerRadiusPoints,
            maskCache: &maskCache
        )

        switch cut.layoutMode {
        case .screenFullScreen:
            return screenBase

        case .cameraFullScreen:
            guard let cameraImage else { return screenBase }
            return Self.aspectFill(
                cameraImage,
                sourceExtent: cameraImage.extent,
                targetRect: outputExtent
            )
            .cropped(to: outputExtent)

        case .screenWithCamera:
            guard let cameraImage else { return screenBase }

            let targetRect = cut.cameraFrame.videoRect(in: outputExtent)
            guard targetRect.width > 1, targetRect.height > 1 else {
                return screenBase
            }

            let scaledCamera = Self.aspectFill(
                cameraImage,
                sourceExtent: cameraImage.extent,
                targetRect: targetRect
            )

            let shape = Self.metadataShapeValue(for: cut.cameraShape)
            let mask = Self.overlayMask(
                size: targetRect.size,
                shape: shape,
                cache: &maskCache
            )
            .transformed(by: CGAffineTransform(translationX: targetRect.minX, y: targetRect.minY))

            let blendedImage = scaledCamera.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: screenBase,
                kCIInputMaskImageKey: mask
            ])

            return blendedImage.cropped(to: outputExtent)
        }
    }

    private nonisolated static func aspectFill(
        _ image: CIImage,
        sourceExtent: CGRect,
        targetRect: CGRect
    ) -> CIImage {
        let scale = max(
            targetRect.width / max(sourceExtent.width, 1),
            targetRect.height / max(sourceExtent.height, 1)
        )
        let scaledWidth = sourceExtent.width * scale
        let scaledHeight = sourceExtent.height * scale
        let translationX = targetRect.midX - scaledWidth / 2 - sourceExtent.minX * scale
        let translationY = targetRect.midY - scaledHeight / 2 - sourceExtent.minY * scale

        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: translationX, y: translationY))
    }

    private nonisolated static func aspectFit(
        _ image: CIImage,
        sourceExtent: CGRect,
        targetRect: CGRect
    ) -> CIImage {
        let scale = min(
            targetRect.width / max(sourceExtent.width, 1),
            targetRect.height / max(sourceExtent.height, 1)
        )
        let scaledWidth = sourceExtent.width * scale
        let scaledHeight = sourceExtent.height * scale
        let translationX = targetRect.midX - scaledWidth / 2 - sourceExtent.minX * scale
        let translationY = targetRect.midY - scaledHeight / 2 - sourceExtent.minY * scale

        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: translationX, y: translationY))
    }

    /// 按归一化裁切矩形（左上原点）裁出缩放区间聚焦的画面。
    /// CIImage 是左下原点，y 轴在这里翻转。
    private nonisolated static func zoomCroppedImage(_ image: CIImage, crop: NormalizedCrop) -> CIImage {
        let extent = image.extent
        let rect = CGRect(
            x: extent.minX + crop.x * extent.width,
            y: extent.minY + (1 - crop.y - crop.h) * extent.height,
            width: crop.w * extent.width,
            height: crop.h * extent.height
        )
        return image.cropped(to: rect)
    }

    /// 把合成好的整幅画面按目标比例居中裁切，再缩放到目标尺寸。
    /// 用于「导出 16:9」：整屏录制是 1.53:1，直接上传会被平台加黑边。
    /// 美化开启时：底色画布 + 留白 + 圆角悬浮画面；关闭时：直接铺满。
    private nonisolated static func beautifiedOrFittedBase(
        _ screenImage: CIImage,
        outputExtent: CGRect,
        paddingRatio: Double,
        cornerRadiusPoints: Double,
        maskCache: inout [String: CIImage]
    ) -> CIImage {
        guard paddingRatio > 0 else {
            return Self.aspectFit(
                screenImage,
                sourceExtent: screenImage.extent,
                targetRect: outputExtent
            )
            .cropped(to: outputExtent)
        }

        let inset = min(outputExtent.width, outputExtent.height) * CGFloat(paddingRatio)
        let contentTarget = outputExtent.insetBy(dx: inset, dy: inset)
        let fittedRect = CursorRenderer.contentRect(
            sourceExtent: screenImage.extent,
            in: contentTarget
        )
        let fitted = Self.aspectFit(
            screenImage,
            sourceExtent: screenImage.extent,
            targetRect: fittedRect
        )

        let slate = RecordingExportSettings.beautifySlateBackground
        let background = CIImage(
            color: CIColor(red: slate.red, green: slate.green, blue: slate.blue)
        ).cropped(to: outputExtent)

        // 圆角随输出分辨率缩放：20pt 是 1080p 基准（HuaStudio 实测值）
        let radius = CGFloat(cornerRadiusPoints) * (outputExtent.height / 1080.0)
        let cacheKey = "rounded-mask-\(Int(fittedRect.width))x\(Int(fittedRect.height))-\(Int(radius))"
        if maskCache[cacheKey] == nil,
           let maskImage = Self.roundedRectMaskCGImage(size: fittedRect.size, radius: radius) {
            maskCache[cacheKey] = CIImage(cgImage: maskImage)
        }
        if let maskTemplate = maskCache[cacheKey] {
            let mask = maskTemplate.transformed(by: CGAffineTransform(
                translationX: fittedRect.minX,
                y: fittedRect.minY
            ))
            return fitted
                .applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: background,
                    kCIInputMaskImageKey: mask
                ])
                .cropped(to: outputExtent)
        }
        return fitted.composited(over: background).cropped(to: outputExtent)
    }

    /// 圆角矩形蒙版。用 CoreGraphics 画（CIFilter CIRoundedRectangleGenerator
    /// 的参数键是 inputExtent 而非 inputWidth/Height，用错键会抛 ObjC 异常
    /// 直接崩掉导出——2026-10-24 自测实测踩过）。
    private nonisolated static func roundedRectMaskCGImage(size: CGSize, radius: CGFloat) -> CGImage? {
        let width = max(2, Int(size.width.rounded()))
        let height = max(2, Int(size.height.rounded()))
        guard let cg = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        cg.addPath(CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
            cornerWidth: max(1, radius),
            cornerHeight: max(1, radius),
            transform: nil
        ))
        cg.fillPath()
        return cg.makeImage()
    }

    private nonisolated static func cropToAspect(
        _ image: CIImage,
        from sourceExtent: CGRect,
        to targetExtent: CGRect
    ) -> CIImage {
        guard sourceExtent.width > 0, sourceExtent.height > 0,
              targetExtent.width > 0, targetExtent.height > 0 else { return image }

        let targetAspect = targetExtent.width / targetExtent.height
        let sourceAspect = sourceExtent.width / sourceExtent.height

        let cropRect: CGRect
        if abs(sourceAspect - targetAspect) < 0.0001 {
            cropRect = sourceExtent
        } else if sourceAspect > targetAspect {
            let width = sourceExtent.height * targetAspect
            cropRect = CGRect(x: sourceExtent.midX - width / 2, y: sourceExtent.minY,
                              width: width, height: sourceExtent.height)
        } else {
            let height = sourceExtent.width / targetAspect
            cropRect = CGRect(x: sourceExtent.minX, y: sourceExtent.midY - height / 2,
                              width: sourceExtent.width, height: height)
        }

        return image
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
            .transformed(by: CGAffineTransform(scaleX: targetExtent.width / cropRect.width,
                                               y: targetExtent.height / cropRect.height))
    }

    private nonisolated static func overlayTargetRect(
        from overlayFrame: CGRect,
        metadata: CameraOverlayMetadataFile,
        outputExtent: CGRect
    ) -> CGRect {
        let sourceRect = metadata.recordingRect?.cgRect ?? outputExtent
        let scaleX = outputExtent.width / max(sourceRect.width, 1)
        let scaleY = outputExtent.height / max(sourceRect.height, 1)
        let uniformScale = min(scaleX, scaleY)
        let center = CGPoint(
            x: (overlayFrame.midX - sourceRect.minX) * scaleX,
            y: (overlayFrame.midY - sourceRect.minY) * scaleY
        )
        let size = CGSize(
            width: overlayFrame.width * uniformScale,
            height: overlayFrame.height * uniformScale
        )

        var rect = CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )

        // 气泡原本按屏幕绝对坐标落位，会压住菜单栏（顶部约 24pt）。
        // 这里把它钳制在安全区内：四边留出约 4% 的边距。
        let inset = min(outputExtent.width, outputExtent.height) * 0.04
        let safeRect = outputExtent.insetBy(dx: inset, dy: inset)
        if safeRect.width >= rect.width, safeRect.height >= rect.height {
            rect.origin.x = min(max(rect.minX, safeRect.minX), safeRect.maxX - rect.width)
            rect.origin.y = min(max(rect.minY, safeRect.minY), safeRect.maxY - rect.height)
        } else {
            rect.origin.x = safeRect.midX - rect.width / 2
            rect.origin.y = safeRect.midY - rect.height / 2
        }
        return rect
    }

    private nonisolated static func overlayMask(size: CGSize, shape: String, cache: inout [String: CIImage]) -> CIImage {
        let width = max(2, Int(size.width.rounded()))
        let height = max(2, Int(size.height.rounded()))
        let key = "\(shape)-\(width)x\(height)"

        if let cachedMask = cache[key] {
            return cachedMask
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))

        if shape == "circle" {
            context.fillEllipse(in: rect)
        } else {
            let minSide = min(CGFloat(width), CGFloat(height))
            let radius = min(max(18, minSide * 0.16), minSide * 0.24)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }

        guard let cgImage = context.makeImage() else {
            return CIImage(color: .white).cropped(to: rect)
        }

        let mask = CIImage(cgImage: cgImage)
        cache[key] = mask
        return mask
    }

    private nonisolated static func metadataShapeValue(for shape: CameraOverlayShape) -> String {
        switch shape {
        case .circle:
            return "circle"
        case .roundedSquare:
            return "roundedRectangle"
        case .roundedBox:
            return "roundedSquare"
        }
    }

    private nonisolated static func resolvedEditCuts(
        _ cuts: [RecordingEditCut],
        totalDuration: Double,
        hasCamera: Bool
    ) -> [ResolvedRecordingEditCut] {
        let safeDuration = max(totalDuration.isFinite ? totalDuration : 0, 0.1)
        var outputStart = 0.0

        let sanitizedCuts = cuts
            .map { cut -> RecordingEditCut in
                var sanitized = cut
                sanitized.startTime = min(max(0, sanitized.startTime), safeDuration)
                sanitized.endTime = min(max(sanitized.startTime + 0.05, sanitized.endTime), safeDuration)
                if sanitized.layoutMode.requiresCamera && !hasCamera {
                    sanitized.layoutMode = .screenFullScreen
                }
                sanitized.cameraFrame = sanitized.cameraFrame.clamped()
                return sanitized
            }
            .filter { $0.duration > 0.05 }
            .sorted { $0.startTime < $1.startTime }

        let sourceCuts: [RecordingEditCut]
        if sanitizedCuts.isEmpty {
            sourceCuts = [
                RecordingEditCut(
                    startTime: 0,
                    endTime: safeDuration,
                    layoutMode: hasCamera ? .screenWithCamera : .screenFullScreen,
                    cameraFrame: .defaultCameraFrame,
                    cameraShape: .circle
                )
            ]
        } else {
            sourceCuts = sanitizedCuts
        }

        return sourceCuts.map { cut in
            let resolved = ResolvedRecordingEditCut(
                cut: cut,
                startSeconds: cut.startTime,
                endSeconds: cut.endTime,
                outputStartSeconds: outputStart
            )
            outputStart += resolved.duration
            return resolved
        }
    }

    private nonisolated static func overlaySample(
        at seconds: Double,
        in samples: [CameraOverlayMetadataSample]
    ) -> CameraOverlayMetadataSample? {
        guard var selectedSample = samples.first else { return nil }

        for sample in samples {
            guard sample.time <= seconds else { break }
            selectedSample = sample
        }

        return selectedSample
    }

    private nonisolated static func createPixelBuffer(from adapter: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        guard let pixelBufferPool = adapter.pixelBufferPool else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer)
        guard status == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    private nonisolated static func normalizedVideoSize(for track: AVAssetTrack) -> CGSize {
        let naturalSize = track.naturalSize.applying(track.preferredTransform)
        return CGSize(width: abs(naturalSize.width), height: abs(naturalSize.height))
    }

    private nonisolated static func muxAudioFromScreenVideo(
        screenURL: URL,
        videoOnlyURL: URL,
        outputURL: URL,
        cuts: [RecordingEditCut]? = nil
    ) async -> Bool {
        let screenAsset = AVURLAsset(url: screenURL)
        let videoAsset = AVURLAsset(url: videoOnlyURL)
        let audioTracks = screenAsset.tracks(withMediaType: .audio)

        guard !audioTracks.isEmpty,
              let videoTrack = videoAsset.tracks(withMediaType: .video).first else {
            return false
        }

        if let cuts {
            return await Self.muxVideoWithEditedAudio(
                videoAsset: videoAsset,
                videoTrack: videoTrack,
                sourceDuration: screenAsset.duration,
                audioTracks: audioTracks,
                outputURL: outputURL,
                cuts: cuts
            )
        }

        if audioTracks.count > 1 {
            let mixedAudioURL = Self.siblingOutputURL(for: screenURL, suffix: "mixed_audio_tmp", extension: "m4a")
            try? FileManager.default.removeItem(at: mixedAudioURL)

            let mixed = await Self.exportSingleMixedAudioTrack(
                audioTracks: audioTracks,
                duration: videoAsset.duration,
                outputURL: mixedAudioURL
            )

            if mixed {
                defer { try? FileManager.default.removeItem(at: mixedAudioURL) }
                if await Self.muxVideoWithSingleAudioTrack(
                    videoAsset: videoAsset,
                    videoTrack: videoTrack,
                    audioURL: mixedAudioURL,
                    outputURL: outputURL
                ) {
                    return true
                }
                print("⚠️  Single-track audio mux failed; falling back to passthrough audio tracks")
            } else {
                print("⚠️  Mixed audio export failed; falling back to passthrough audio tracks")
            }
        }

        return await Self.muxVideoWithPassthroughAudioTracks(
            videoAsset: videoAsset,
            videoTrack: videoTrack,
            audioTracks: audioTracks,
            outputURL: outputURL
        )
    }

    private nonisolated static func muxVideoWithEditedAudio(
        videoAsset: AVURLAsset,
        videoTrack: AVAssetTrack,
        sourceDuration: CMTime,
        audioTracks: [AVAssetTrack],
        outputURL: URL,
        cuts: [RecordingEditCut]
    ) async -> Bool {
        let sourceDurationSeconds = CMTimeGetSeconds(sourceDuration)
        let resolvedCuts = Self.resolvedEditCuts(
            cuts,
            totalDuration: sourceDurationSeconds,
            hasCamera: true
        )
        guard !resolvedCuts.isEmpty else { return false }

        let editedAudioURL = Self.siblingOutputURL(for: outputURL, suffix: "audio_tmp", extension: "m4a")
        try? FileManager.default.removeItem(at: editedAudioURL)

        let mixedAudio = await Self.exportEditedSingleMixedAudioTrack(
            audioTracks: audioTracks,
            resolvedCuts: resolvedCuts,
            outputURL: editedAudioURL
        )

        if mixedAudio {
            defer { try? FileManager.default.removeItem(at: editedAudioURL) }
            let muxed = await Self.muxVideoWithSingleAudioTrack(
                videoAsset: videoAsset,
                videoTrack: videoTrack,
                audioURL: editedAudioURL,
                outputURL: outputURL
            )
            if muxed {
                return true
            }
        }

        print("⚠️  Edited audio mux failed; falling back to direct composition export")

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return false
        }

        do {
            try compositionVideoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: videoAsset.duration),
                of: videoTrack,
                at: .zero
            )
            compositionVideoTrack.preferredTransform = videoTrack.preferredTransform
        } catch {
            print("❌ Edited video mux failed: \(error.localizedDescription)")
            return false
        }

        var mixParameters: [AVAudioMixInputParameters] = []
        for (index, audioTrack) in audioTracks.enumerated() {
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                continue
            }

            for resolvedCut in resolvedCuts {
                let sourceStart = CMTime(seconds: resolvedCut.startSeconds, preferredTimescale: 600)
                let sourceDuration = CMTime(seconds: resolvedCut.duration, preferredTimescale: 600)
                let destinationStart = CMTime(seconds: resolvedCut.outputStartSeconds, preferredTimescale: 600)

                do {
                    try compositionAudioTrack.insertTimeRange(
                        CMTimeRange(start: sourceStart, duration: sourceDuration),
                        of: audioTrack,
                        at: destinationStart
                    )
                } catch {
                    print("⚠️  Failed to insert edited audio segment: \(error.localizedDescription)")
                }
            }

            let parameters = AVMutableAudioMixInputParameters(track: compositionAudioTrack)
            parameters.setVolume(audioMixVolume(forAudioTrackAt: index, trackCount: audioTracks.count), at: .zero)
            mixParameters.append(parameters)
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            return false
        }

        if !mixParameters.isEmpty {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = mixParameters
            exporter.audioMix = audioMix
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = false

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            exporter.exportAsynchronously {
                continuation.resume(returning: exporter.status == .completed)
            }
        }
    }

    private nonisolated static func exportEditedSingleMixedAudioTrack(
        audioTracks: [AVAssetTrack],
        resolvedCuts: [ResolvedRecordingEditCut],
        outputURL: URL
    ) async -> Bool {
        let composition = AVMutableComposition()
        var mixParameters: [AVAudioMixInputParameters] = []

        for (index, audioTrack) in audioTracks.enumerated() {
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                continue
            }

            for resolvedCut in resolvedCuts {
                let sourceStart = CMTime(seconds: resolvedCut.startSeconds, preferredTimescale: 600)
                let sourceDuration = CMTime(seconds: resolvedCut.duration, preferredTimescale: 600)
                let destinationStart = CMTime(seconds: resolvedCut.outputStartSeconds, preferredTimescale: 600)

                do {
                    try compositionAudioTrack.insertTimeRange(
                        CMTimeRange(start: sourceStart, duration: sourceDuration),
                        of: audioTrack,
                        at: destinationStart
                    )
                } catch {
                    print("⚠️  Failed to insert edited audio segment for mix: \(error.localizedDescription)")
                }
            }

            let parameters = AVMutableAudioMixInputParameters(track: compositionAudioTrack)
            parameters.setVolume(audioMixVolume(forAudioTrackAt: index, trackCount: audioTracks.count), at: .zero)
            mixParameters.append(parameters)
        }

        guard !mixParameters.isEmpty,
              let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            return false
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = mixParameters
        exporter.audioMix = audioMix
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = false

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            exporter.exportAsynchronously {
                continuation.resume(returning: exporter.status == .completed)
            }
        }
    }

    private nonisolated static func exportSingleMixedAudioTrack(
        audioTracks: [AVAssetTrack],
        duration: CMTime,
        outputURL: URL
    ) async -> Bool {
        let composition = AVMutableComposition()
        var mixParameters: [AVAudioMixInputParameters] = []

        for (index, audioTrack) in audioTracks.enumerated() {
            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                continue
            }

            let insertionTime = audioTrack.timeRange.start.isValid ? audioTrack.timeRange.start : .zero
            let availableDuration = CMTimeSubtract(duration, insertionTime)
            let sourceDuration = CMTimeMinimum(audioTrack.timeRange.duration, availableDuration)
            guard sourceDuration.isValid, sourceDuration > .zero else { continue }

            do {
                try compositionTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: sourceDuration),
                    of: audioTrack,
                    at: insertionTime
                )
                let parameters = AVMutableAudioMixInputParameters(track: compositionTrack)
                parameters.setVolume(audioMixVolume(forAudioTrackAt: index, trackCount: audioTracks.count), at: .zero)
                mixParameters.append(parameters)
            } catch {
                print("⚠️  Failed to insert audio track for mix: \(error.localizedDescription)")
            }
        }

        guard !mixParameters.isEmpty,
              let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            return false
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = mixParameters
        exporter.audioMix = audioMix
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = false

        print("🎚️  Exporting single mixed audio track from \(audioTracks.count) source tracks")
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            exporter.exportAsynchronously {
                continuation.resume(returning: exporter.status == .completed)
            }
        }
    }

    private nonisolated static func muxVideoWithSingleAudioTrack(
        videoAsset: AVURLAsset,
        videoTrack: AVAssetTrack,
        audioURL: URL,
        outputURL: URL
    ) async -> Bool {
        let audioAsset = AVURLAsset(url: audioURL)
        guard let audioTrack = audioAsset.tracks(withMediaType: .audio).first else {
            return false
        }

        return await muxVideoWithPassthroughAudioTracks(
            videoAsset: videoAsset,
            videoTrack: videoTrack,
            audioTracks: [audioTrack],
            outputURL: outputURL
        )
    }

    private nonisolated static func muxVideoWithPassthroughAudioTracks(
        videoAsset: AVURLAsset,
        videoTrack: AVAssetTrack,
        audioTracks: [AVAssetTrack],
        outputURL: URL
    ) async -> Bool {
        let composition = AVMutableComposition()

        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return false
        }

        do {
            try compositionVideoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: videoAsset.duration),
                of: videoTrack,
                at: .zero
            )
            compositionVideoTrack.preferredTransform = videoTrack.preferredTransform

            for audioTrack in audioTracks {
                guard let compositionAudioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { continue }

                try compositionAudioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: videoAsset.duration),
                    of: audioTrack,
                    at: .zero
                )
            }
        } catch {
            print("❌ 合成视频复用音频失败: \(error.localizedDescription)")
            return false
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            return false
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = false

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            exporter.exportAsynchronously {
                continuation.resume(returning: exporter.status == .completed)
            }
        }
    }

    private nonisolated static func audioMixVolume(forAudioTrackAt index: Int, trackCount: Int) -> Float {
        guard trackCount > 1 else { return 1.0 }

        // AVAssetWriter adds system audio before microphone audio. Keep headroom
        // when both are present so playback apps do not clip while summing.
        return index == 0 ? 0.55 : 0.85
    }
    
    // MARK: - 完成视频写入
    private func finishVideoWriting() async -> CapturedRecordingOutput? {
        guard let writer = videoWriter else { return nil }
        let completedOutputURL = outputURL
        let completedCameraURL = enableCameraOverlay ? cameraOutputURL : nil
        let completedOverlayMetadataURL = enableCameraOverlay ? overlayMetadataURL : nil
        var capturedOutput: CapturedRecordingOutput?
        
        print("🎬 完成视频写入，总帧数: \(frameCount)")
        
        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()
        microphoneWriterInput?.markAsFinished()
        
        await writer.finishWriting()
        
        switch writer.status {
        case .completed:
            print("✅ 视频文件保存成功: \(completedOutputURL?.lastPathComponent ?? "")")
            if let url = completedOutputURL {
                let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
                print("📄 文件大小: \(fileSize ?? 0) bytes")
                writeRecordingMetrics(for: url)
                capturedOutput = CapturedRecordingOutput(
                    outputURL: url,
                    cameraURL: Self.existingFileURL(completedCameraURL),
                    overlayMetadataURL: Self.existingFileURL(completedOverlayMetadataURL)
                )
            }
        case .failed:
            print("❌ 视频文件保存失败: \(writer.error?.localizedDescription ?? "未知错误")")
            if let url = completedOutputURL {
                writeRecordingMetrics(for: url)
            }
        case .cancelled:
            print("⚠️  视频写入被取消")
            if let url = completedOutputURL {
                writeRecordingMetrics(for: url)
            }
        default:
            print("⚠️  视频写入状态未知: \(writer.status.rawValue)")
            if let url = completedOutputURL {
                writeRecordingMetrics(for: url)
            }
        }
        
        // 清理资源
        videoWriter = nil
        videoWriterInput = nil
        audioWriterInput = nil
        microphoneWriterInput = nil
        pixelBufferAdapter = nil

        return capturedOutput
    }

    private func writeRecordingMetrics(for outputURL: URL) {
        let expectedMinimumDuration: TimeInterval
        if frameCount > 0 {
            expectedMinimumDuration = min(0.5, max(0.1, Double(frameCount) / Double(Self.screenTargetFrameRate) * 0.5))
        } else {
            expectedMinimumDuration = 0.1
        }

        let validation = RecordingOutputValidator.validate(
            outputURL: outputURL,
            expectedMinimumDuration: expectedMinimumDuration
        )
        lastValidation = validation
        recordingMetrics.applyValidation(validation)
        recordingMetrics.markFinished()
        recordingMetrics.write(to: outputURL)
    }

    private nonisolated static func existingFileURL(_ url: URL?) -> URL? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private nonisolated static func promoteGeneratedOutputIfNeeded(
        _ generatedOutputURL: URL?,
        sourceOutputURL: URL,
        sessionDirectory: URL
    ) -> URL? {
        guard let generatedOutputURL else { return nil }

        let sourceDirectory = sourceOutputURL.deletingLastPathComponent()
        guard sourceDirectory.lastPathComponent == RecordingArtifactOrganizer.rawDataDirectoryName else {
            return generatedOutputURL
        }

        let destinationURL = sessionDirectory.appendingPathComponent(generatedOutputURL.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: generatedOutputURL, to: destinationURL)
            return destinationURL
        } catch {
            print("⚠️  Failed to promote rendered recording from raw_data: \(error.localizedDescription)")
            return generatedOutputURL
        }
    }

    private static func startRecordingPostProcessing(
        capturedOutput: CapturedRecordingOutput,
        mode: RecordingRenderMode,
        exportSettings: RecordingExportSettings,
        handler: (@MainActor (RecordingPostProcessingEvent) -> Void)?
    ) {
        handler?(.started(outputURL: capturedOutput.outputURL, mode: mode))
        Task.detached(priority: .utility) {
            let result = await Self.runRecordingPostProcessing(
                capturedOutput: capturedOutput,
                mode: mode,
                exportSettings: exportSettings
            )
            await MainActor.run {
                handler?(.completed(result))
            }
        }
    }

    private nonisolated static func runRecordingPostProcessing(
        capturedOutput: CapturedRecordingOutput,
        mode: RecordingRenderMode,
        exportSettings: RecordingExportSettings
    ) async -> RecordingPostProcessingResult {
        print("ℹ️  Starting recording post-processing")
        let outputURL = capturedOutput.outputURL
        let outputDirectory = outputURL.deletingLastPathComponent()
        let isSourceInRawData = outputDirectory.lastPathComponent == RecordingArtifactOrganizer.rawDataDirectoryName
        let sessionDirectory = isSourceInRawData ? outputDirectory.deletingLastPathComponent() : outputDirectory
        let exportStart = Date()
        let compositedURL: URL?
        let cameraOnlyURL: URL?

        switch mode {
        case .all:
            compositedURL = await Self.exportCompositedVideoIfNeeded(
                for: outputURL,
                cameraURL: capturedOutput.cameraURL,
                overlayMetadataURL: capturedOutput.overlayMetadataURL,
                exportSettings: exportSettings
            )
            cameraOnlyURL = nil
        case .cameraOnlyTransparent:
            compositedURL = nil
            cameraOnlyURL = await Self.exportTransparentCameraVideoIfNeeded(
                for: outputURL,
                cameraURL: capturedOutput.cameraURL,
                overlayMetadataURL: capturedOutput.overlayMetadataURL,
                exportSettings: exportSettings
            )
        case .edited(let decision):
            compositedURL = await Self.exportEditedRecordingIfNeeded(
                for: outputURL,
                cameraURL: capturedOutput.cameraURL,
                overlayMetadataURL: capturedOutput.overlayMetadataURL,
                decision: decision,
                exportSettings: exportSettings
            )
            cameraOnlyURL = nil
        }

        let generatedOutputURL = compositedURL ?? cameraOnlyURL
        let promotedGeneratedOutputURL = promoteGeneratedOutputIfNeeded(
            generatedOutputURL,
            sourceOutputURL: outputURL,
            sessionDirectory: sessionDirectory
        )
        let finalOutputURL = promotedGeneratedOutputURL
            ?? (mode == .cameraOnlyTransparent ? capturedOutput.cameraURL : nil)
            ?? outputURL
        if generatedOutputURL != nil {
            updateMetricsExportDuration(
                for: outputURL,
                duration: Date().timeIntervalSince(exportStart)
            )
        }

        let movedRawArtifactCount: Int
        let finalOutputIsInSessionDirectory = finalOutputURL.deletingLastPathComponent().standardizedFileURL == sessionDirectory.standardizedFileURL
        if !isSourceInRawData || finalOutputIsInSessionDirectory {
            do {
                let movedURLs = try RecordingArtifactOrganizer.moveRawArtifacts(
                    in: sessionDirectory,
                    keeping: finalOutputURL
                )
                movedRawArtifactCount = movedURLs.count
                if movedRawArtifactCount > 0 {
                    print("✅ Raw recording data moved to \(RecordingArtifactOrganizer.rawDataDirectoryName): \(movedRawArtifactCount) files")
                }
            } catch {
                movedRawArtifactCount = 0
                print("⚠️  Failed to organize raw recording data: \(error.localizedDescription)")
            }
        } else {
            movedRawArtifactCount = 0
        }

        return RecordingPostProcessingResult(
            finalOutputURL: finalOutputURL,
            mode: mode,
            didExportCompositedVideo: compositedURL != nil,
            didExportCameraOnlyVideo: cameraOnlyURL != nil,
            movedRawArtifactCount: movedRawArtifactCount
        )
    }

    private nonisolated static func updateMetricsExportDuration(for outputURL: URL, duration: TimeInterval) {
        let metricsURL = RecordingMetricsRecorder.metricsURL(for: outputURL)
        guard FileManager.default.fileExists(atPath: metricsURL.path) else { return }

        do {
            let data = try Data(contentsOf: metricsURL)
            var snapshot = try JSONDecoder().decode(RecordingMetricsSnapshot.self, from: data)
            snapshot.exportDurationSeconds = duration

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: metricsURL)
            print("✅ Recording export metrics updated: \(metricsURL.lastPathComponent)")
        } catch {
            print("⚠️  Failed to update export metrics: \(error.localizedDescription)")
        }
    }

    // MARK: - 区域保存和恢复
    private func saveSelectedArea(_ rect: CGRect) {
        let rectDict: [String: Double] = [
            "x": rect.origin.x,
            "y": rect.origin.y,
            "width": rect.width,
            "height": rect.height
        ]
        UserDefaults.standard.set(rectDict, forKey: "lastSelectedArea")
        print("💾 保存选择区域: \(rect)")
    }
    
    func getLastSelectedArea() -> CGRect? {
        guard let rectDict = UserDefaults.standard.dictionary(forKey: "lastSelectedArea") as? [String: Double],
              let x = rectDict["x"],
              let y = rectDict["y"],
              let width = rectDict["width"],
              let height = rectDict["height"] else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - SCStreamOutput
extension ScreenRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        Task { @MainActor in
            switch type {
            case .screen:
                await processVideoSampleBuffer(sampleBuffer)
            case .audio:
                await processAudioSampleBuffer(sampleBuffer, type: .systemAudio)
            case .microphone:
                if #available(macOS 15.0, *) {
                    await processAudioSampleBuffer(sampleBuffer, type: .microphone)
                }
            @unknown default:
                break
            }
        }
    }
}

// MARK: - SCStreamDelegate
extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("❌ Stream意外停止: \(error.localizedDescription)")
        Task { @MainActor in
            isRecording = false
        }
    }
}

// MARK: - 媒体处理
extension ScreenRecorder {
    private func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) async {
        guard !isPaused else { return }
        guard let writer = videoWriter,
              let writerInput = videoWriterInput,
              writer.status == .writing else {
            return
        }

        guard isCompleteScreenFrame(sampleBuffer) else { return }

        // 获取当前帧的原始时间戳
        let currentFrameTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // 设置录制开始时间（只设置一次）
        if firstVideoFrameTime == nil {
            firstVideoFrameTime = currentFrameTime
            recordingStartTime = .zero
            writer.startSession(atSourceTime: recordingStartTime)
            flushPendingAudioBuffers()
            print("🎬 录制会话开始，首帧时间: \(CMTimeGetSeconds(currentFrameTime))秒")
        }

        // 计算相对于第一帧的时间差，使用实际时间戳
        guard let firstTime = firstVideoFrameTime else { return }
        let relativeTime = CMTimeSubtract(currentFrameTime, firstTime)
        if let lastPTS = lastAppendedVideoPTS, relativeTime <= lastPTS {
            print(String(
                format: "⚠️  丢弃非单调帧: %.4fs ≤ 已写入 %.4fs（暂停边界护栏）",
                CMTimeGetSeconds(relativeTime), CMTimeGetSeconds(lastPTS)
            ))
            return
        }
        guard let adjustedBuffer = adjustedVideoSampleBuffer(sampleBuffer, relativeTo: firstTime) else {
            return
        }

        // 调试输出
        if frameCount % 30 == 0 { // 每秒打印一次
            let seconds = CMTimeGetSeconds(relativeTime)
            print("🎬 视频帧 \(frameCount): \(String(format: "%.3f", seconds))秒")
        }

        // 写入帧数据
        if writerInput.isReadyForMoreMediaData {
            let success = writerInput.append(adjustedBuffer)
            if success {
                lastAppendedVideoPTS = relativeTime
                frameCount += 1
                recordingMetrics.incrementScreenAppended()
            } else {
                print("⚠️  帧写入失败，帧号: \(frameCount)，写入器: \(videoWriter?.error?.localizedDescription ?? "未报错")")
            }
        } else {
            recordingMetrics.incrementScreenWriterNotReady()
            print("⚠️  写入器未就绪，跳过帧: \(frameCount)")
        }
    }

    private func isCompleteScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue) else {
            return false
        }

        return status == .complete
    }

    private func adjustedVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, relativeTo firstTime: CMTime) -> CMSampleBuffer? {
        adjustedSampleBuffer(sampleBuffer, relativeTo: firstTime)
    }

    private func adjustedAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        let originalTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        switch audioStartGate.decision(
            audioStart: originalTime,
            audioDuration: duration,
            firstVideoStart: firstVideoFrameTime
        ) {
        case .waitForVideo:
            return nil
        case .dropBeforeVideo:
            recordingMetrics.incrementDroppedAudioBeforeVideo()
            return nil
        case .append(let relativeTo, let partialOverlap):
            if partialOverlap > .zero {
                recordingMetrics.addPartialAudioOverlap(partialOverlap)
            }
            return adjustedSampleBuffer(
                sampleBuffer,
                relativeTo: relativeTo,
                clampNegativeTimestamps: partialOverlap > .zero
            )
        }
    }

    private func adjustedSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        relativeTo offset: CMTime,
        clampNegativeTimestamps: Bool = false
    ) -> CMSampleBuffer? {
        var timingEntryCount: CMItemCount = 0
        let entryCountStatus = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingEntryCount
        )

        guard entryCountStatus == noErr, timingEntryCount > 0 else {
            print("❌ 读取样本时间条目数量失败: \(entryCountStatus)")
            return nil
        }

        var timingInfo = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid),
            count: Int(timingEntryCount)
        )

        let timingStatus = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: timingEntryCount,
            arrayToFill: &timingInfo,
            entriesNeededOut: nil
        )

        if timingStatus != noErr {
            print("❌ 读取样本时间信息失败: \(timingStatus)")
            return nil
        }

        for index in 0..<timingInfo.count {
            if timingInfo[index].presentationTimeStamp.isValid {
                var presentationTimeStamp = CMTimeSubtract(timingInfo[index].presentationTimeStamp, offset)
                if clampNegativeTimestamps, presentationTimeStamp.isValid, presentationTimeStamp < .zero {
                    presentationTimeStamp = .zero
                }
                timingInfo[index].presentationTimeStamp = presentationTimeStamp
            }
            if timingInfo[index].decodeTimeStamp.isValid {
                var decodeTimeStamp = CMTimeSubtract(timingInfo[index].decodeTimeStamp, offset)
                if clampNegativeTimestamps, decodeTimeStamp.isValid, decodeTimeStamp < .zero {
                    decodeTimeStamp = .zero
                }
                timingInfo[index].decodeTimeStamp = decodeTimeStamp
            }
        }

        var adjustedBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timingInfo.count,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &adjustedBuffer
        )

        if status != noErr {
            print("❌ 创建调整后的样本缓冲失败: \(status)")
            return nil
        }

        return adjustedBuffer
    }
    
    // MARK: - 音频处理
    private func processAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, type: AudioType) async {
        guard !isPaused else { return }
        guard let writer = videoWriter,
              writer.status == .writing else {
            return
        }

        guard firstVideoFrameTime != nil else {
            queuePendingAudio(sampleBuffer, type: type)
            return
        }

        appendAudioSampleBuffer(sampleBuffer, type: type)
    }

    private func queuePendingAudio(_ sampleBuffer: CMSampleBuffer, type: AudioType) {
        pendingAudioBuffers.append(PendingAudioSample(sampleBuffer: sampleBuffer, type: type))
        recordingMetrics.incrementQueuedAudioBeforeVideo()

        guard let newestAudioStart = pendingAudioBuffers.last.map({ CMSampleBufferGetPresentationTimeStamp($0.sampleBuffer) }) else {
            return
        }

        while pendingAudioBuffers.count > 48 {
            pendingAudioBuffers.removeFirst()
            recordingMetrics.incrementDroppedAudioBeforeVideo()
        }

        while let oldestAudioStart = pendingAudioBuffers.first.map({ CMSampleBufferGetPresentationTimeStamp($0.sampleBuffer) }),
              !audioStartGate.shouldKeepPendingAudio(newestAudioStart: newestAudioStart, oldestAudioStart: oldestAudioStart) {
            pendingAudioBuffers.removeFirst()
            recordingMetrics.incrementDroppedAudioBeforeVideo()
        }
    }

    private func flushPendingAudioBuffers() {
        guard !pendingAudioBuffers.isEmpty else { return }

        let pending = pendingAudioBuffers
        pendingAudioBuffers.removeAll(keepingCapacity: true)
        for sample in pending {
            appendAudioSampleBuffer(sample.sampleBuffer, type: sample.type)
        }
    }

    private func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, type: AudioType) {
        let writerInput: AVAssetWriterInput?
        
        switch type {
        case .systemAudio:
            writerInput = audioWriterInput
        case .microphone:
            writerInput = microphoneWriterInput
        }
        
        guard let input = writerInput else {
            print("⚠️  音频写入器不可用: \(type)")
            return
        }
        
        // SCK 音频与屏幕帧共享 host-time 时间轴；统一按首个完整视频帧归零。
        guard let adjustedBuffer = adjustedAudioSampleBuffer(sampleBuffer) else {
            return
        }
        
        if input.isReadyForMoreMediaData {
            let success = input.append(adjustedBuffer)
            if success {
                // 音频写入成功
                if frameCount % 300 == 0 {  // 每10秒打印一次
                    print("🔊 音频样本写入成功: \(type)")
                }
            } else {
                recordingMetrics.incrementAudioAppendFailed()
                print("❌ 音频样本写入失败: \(type)")
            }
        } else {
            recordingMetrics.incrementAudioWriterNotReady()
            print("⚠️  音频写入器未就绪: \(type)")
        }
    }
}

// MARK: - 错误类型
enum RecordingError: Error, LocalizedError {
    case invalidState
    case noDisplayFound
    case noWindowFound
    case invalidOutputURL
    case writerSetupFailed
    case writerNotFound
    case audioSetupFailed
    case permissionDenied
    
    var errorDescription: String? {
        switch self {
        case .invalidState:
            return "Invalid recording state"
        case .noDisplayFound:
            return "No recordable display found"
        case .noWindowFound:
            return "No recordable window found"
        case .invalidOutputURL:
            return "Invalid output file path"
        case .writerSetupFailed:
            return "Failed to set up video writer"
        case .writerNotFound:
            return "Video writer not found"
        case .audioSetupFailed:
            return "Failed to set up audio"
        case .permissionDenied:
            return "Screen recording permission denied"
        }
    }
}

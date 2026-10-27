import AppKit
import Combine
import Foundation

@MainActor
final class RecordingController: ObservableObject {
    static let shared = RecordingController()
    private static let selectedDisplayIDDefaultsKey = "recording.selectedDisplayID"

    let recordingState = RecordingState()
    let permissionsManager = PermissionsManager()
    let audioManager = AudioManager()

    private let screenRecorder = ScreenRecorder()
    private let cursorTracker = CursorEventTracker()
    private let areaSelector = AreaSelector()
    private let windowSelector = WindowSelector()
    private let recordingIndicator = RecordingIndicatorWindow()
    private let previewRecordingIndicator = RecordingIndicatorWindow()

    private var circularCameraWindow: CircularCameraWindow?
    private var previewCameraWindow: CircularCameraWindow?
    private var recordingTimer: Timer?
    private var selectedWindowTrackingTimer: Timer?
    private var isPreviewActive = false
    private var pendingStopCompletions: [() -> Void] = []
    private var preparedDisplayID: CGDirectDisplayID?

    @Published var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var isRecording = false
    @Published private(set) var isRecordingPaused = false
    @Published private(set) var isPreviewing = false
    @Published private(set) var isExporting = false
    @Published private(set) var exportStatusText: String?
    @Published private(set) var pendingCapturedRecording: CapturedRecordingOutput?
    @Published private(set) var recordingLibraryChangeID = UUID()
    @Published private(set) var lastOutputURL: URL?
    @Published var lastError: String?

    private struct QueuedRenderRequest {
        let capturedOutput: CapturedRecordingOutput
        let mode: RecordingRenderMode
        let exportSettings: RecordingExportSettings
    }

    private var queuedRenderRequest: QueuedRenderRequest?
    private var transcriptAccumulator: RecordingTranscriptAccumulator?

    var cameraManager: CameraManager {
        screenRecorder.getCameraManager()
    }

    var availableDisplays: [ScreenRecordingDisplayTarget] {
        NSScreen.screens.enumerated().map { index, screen in
            let displayID = CGDirectDisplayID(screen.displayID)
            return ScreenRecordingDisplayTarget(
                id: displayID,
                frame: screen.frame,
                name: screen.localizedName,
                index: index
            )
        }
    }

    var selectedDisplayTarget: ScreenRecordingDisplayTarget? {
        let displays = availableDisplays
        if let selectedDisplayID = recordingState.selectedDisplayID,
           let display = displays.first(where: { $0.id == selectedDisplayID }) {
            return display
        }

        return displays.first { display in
            NSScreen.main?.displayID == display.id
        } ?? displays.first
    }

    var currentRecordingInterfaceFrame: CGRect? {
        resolvedRecordingTarget()?.interfaceFrame ?? selectedDisplayTarget?.frame
    }

    var hasPendingCapturedRecording: Bool {
        pendingCapturedRecording != nil
    }

    var canRenderPendingCameraOnly: Bool {
        pendingCapturedRecording?.canRenderCameraOnly == true
    }

    private init() {
        configureOutputDirectory()
        restoreSelectedDisplay()

        screenRecorder.setCameraOverlaySnapshotProvider { [weak self] in
            guard let self else { return nil }
            if let snapshot = self.circularCameraWindow?.metadataSnapshot() {
                return snapshot
            }
            guard let frame = self.recordingState.customCameraOverlayFrame else { return nil }
            return CameraOverlaySnapshot(
                frame: frame,
                shape: self.recordingState.cameraOverlayShape,
                size: self.recordingState.cameraOverlaySize
            )
        }

        screenRecorder.setPostProcessingHandler { [weak self] event in
            self?.handleRecordingPostProcessingEvent(event)
        }

        // 启动时检查上次是否异常退出、留下未收尾的录制。
        Task { @MainActor [weak self] in
            self?.presentUnfinishedRecordingRecoveryIfNeeded()
        }
    }

    private var unfinishedStoreURL: URL? {
        UnfinishedRecordingStore.defaultStoreURL()
    }

    private func registerUnfinishedRecording(state: String) {
        guard let storeURL = unfinishedStoreURL else { return }
        let outputURL = recordingState.outputURL
        UnfinishedRecordingStore.upsert(
            UnfinishedRecordingEntry(
                id: outputURL.lastPathComponent,
                outputURLPath: outputURL.path,
                state: state
            ),
            to: storeURL
        )
    }

    /// 用停录前捕获的 URL 清单。recordingState.stopRecording() 会清空会话状态，
    /// 之后再读 outputURL 得到的是下一条录制的名字，会清错条目。
    private func clearUnfinishedRecording(outputURL: URL) {
        guard let storeURL = unfinishedStoreURL else { return }
        UnfinishedRecordingStore.remove(id: outputURL.lastPathComponent, from: storeURL)
    }

    /// 异常退出后启动：清单里还有未收尾的录制时明确告知。
    /// 无声处理的话，坏文件要等到用户导出看到黑屏才被发现。
    /// 自测模式跳过（避免阻塞无人值守流程）。
    private func presentUnfinishedRecordingRecoveryIfNeeded() {
        guard !RecordingSmokeTestRunner.isRequested else { return }
        guard let storeURL = unfinishedStoreURL else { return }
        var entries = UnfinishedRecordingStore.load(from: storeURL)
        let goneIDs = UnfinishedRecordingStore.entryIDsWithoutOutput(entries)
        if !goneIDs.isEmpty {
            UnfinishedRecordingStore.removeEntries(ids: goneIDs, from: storeURL)
            entries.removeAll { goneIDs.contains($0.id) }
        }
        guard !entries.isEmpty else { return }

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let listing = entries.prefix(3).map { entry in
            "· \(URL(fileURLWithPath: entry.outputURLPath).lastPathComponent)（\(formatter.string(from: entry.startedAt))）"
        }.joined(separator: "\n")

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "发现 \(entries.count) 条未完成收尾的录制"
        alert.informativeText = """
        上次退出时以下录制没有正常收尾，文件可能无法播放：
        \(listing)
        建议在 Finder 中查看并确认素材是否可用。
        """
        alert.addButton(withTitle: "在 Finder 中显示")
        alert.addButton(withTitle: "知道了，清除清单")
        if alert.runModal() == .alertFirstButtonReturn {
            let urls = entries.map { URL(fileURLWithPath: $0.outputURLPath) }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } else {
            UnfinishedRecordingStore.removeEntries(ids: entries.map(\.id), from: storeURL)
        }
    }

    func refreshDevicesAndPermissions() {
        Task {
            await permissionsManager.checkAllPermissions()
            await audioManager.refreshMicrophoneDevices()
            cameraManager.refreshCameraDevices()
            updatePreview()
        }
    }

    func requestPermissions() {
        Task {
            await permissionsManager.requestAllPermissions()
            updatePreview()
        }
    }

    func selectDisplay(_ display: ScreenRecordingDisplayTarget) {
        recordingState.captureMode = .fullScreen
        recordingState.selectedDisplayID = display.id
        preparedDisplayID = display.id
        UserDefaults.standard.set(Int(display.id), forKey: Self.selectedDisplayIDDefaultsKey)
        recordingState.selectedWindowTarget = nil
        recordingState.recordingMode = .fullScreen
        updatePreview()
    }

    private func restoreSelectedDisplay() {
        let savedDisplayID = UserDefaults.standard.integer(forKey: Self.selectedDisplayIDDefaultsKey)
        guard savedDisplayID > 0 else { return }
        let displayID = CGDirectDisplayID(savedDisplayID)
        recordingState.selectedDisplayID = displayID
        preparedDisplayID = displayID
    }

    func startConfiguredRecording(completion: @escaping (Bool) -> Void) {
        switch recordingState.captureMode {
        case .fullScreen:
            endPreview()
            recordingState.recordingMode = .fullScreen
            let displayID = selectedDisplayTarget?.id
            preparedDisplayID = displayID
            startRecording(displayID: displayID) { [weak self] started in
                if !started {
                    self?.beginPreview()
                }
                completion(started)
            }
        case .selectedArea:
            endPreview()
            areaSelector.selectArea(aspectRatioPreset: recordingState.areaAspectRatioPreset) { [weak self] rect in
                guard let self, let rect else {
                    self?.beginPreview()
                    completion(false)
                    return
                }

                self.recordingState.recordingMode = .selectedArea(rect)
                self.recordingState.selectedArea = rect
                self.startRecording { [weak self] started in
                    if !started {
                        self?.beginPreview()
                    }
                    completion(started)
                }
            }
        case .selectedWindow:
            endPreview()
            windowSelector.selectWindow { [weak self] target in
                guard let self, let target else {
                    self?.beginPreview()
                    completion(false)
                    return
                }

                let currentTarget = self.refreshedWindowTarget(target) ?? target
                self.setSelectedWindowTarget(currentTarget)
                self.startRecording { [weak self] started in
                    if !started {
                        self?.beginPreview()
                    }
                    completion(started)
                }
            }
        }
    }

    func startPreviewedRecording(completion: @escaping (Bool) -> Void) {
        switch recordingState.captureMode {
        case .fullScreen:
            recordingState.recordingMode = .fullScreen
            let displayID = selectedDisplayTarget?.id
            preparedDisplayID = displayID
            beginPreparedRecording(displayID: displayID, completion: completion)
        case .selectedArea:
            let rect = !recordingState.selectedArea.isEmpty ? recordingState.selectedArea : previewRecordingRect()
            guard let rect else {
                completion(false)
                return
            }

            recordingState.selectedArea = rect
            recordingState.recordingMode = .selectedArea(rect)
            beginPreparedRecording(completion: completion)
        case .selectedWindow:
            if let target = recordingState.selectedWindowTarget {
                let currentTarget = refreshedWindowTarget(target) ?? target
                setSelectedWindowTarget(currentTarget)
                beginPreparedRecording(completion: completion)
                return
            }

            selectWindowForPreview { [weak self] target in
                guard let self, let target else {
                    completion(false)
                    return
                }

                let currentTarget = self.refreshedWindowTarget(target) ?? target
                self.setSelectedWindowTarget(currentTarget)
                self.beginPreparedRecording(completion: completion)
            }
        }
    }

    func selectAreaForPreview(completion: ((CGRect?) -> Void)? = nil) {
        let previousMode = recordingState.captureMode
        recordingState.captureMode = .selectedArea
        previewRecordingIndicator.hideIndicator()

        areaSelector.selectArea(aspectRatioPreset: recordingState.areaAspectRatioPreset) { [weak self] rect in
            guard let self else {
                completion?(nil)
                return
            }

            if let rect {
                self.recordingState.selectedArea = rect
                self.recordingState.recordingMode = .selectedArea(rect)
            } else if self.recordingState.selectedArea.isEmpty {
                self.recordingState.captureMode = previousMode
            }

            self.beginPreview()
            completion?(rect)
        }
    }

    func selectWindowForPreview(completion: ((WindowRecordingTarget?) -> Void)? = nil) {
        let previousMode = recordingState.captureMode
        recordingState.captureMode = .selectedWindow
        previewRecordingIndicator.hideIndicator()

        windowSelector.selectWindow { [weak self] target in
            guard let self else {
                completion?(nil)
                return
            }

            if let target {
                self.setSelectedWindowTarget(target)
            } else if self.recordingState.selectedWindowTarget == nil {
                self.recordingState.captureMode = previousMode
            }

            self.beginPreview()
            completion?(target)
        }
    }

    func beginPreview() {
        guard !recordingState.isRecording && !screenRecorder.isRecording else { return }

        isPreviewActive = true
        isPreviewing = true
        updatePreview()
    }

    func updatePreview() {
        guard isPreviewActive, !recordingState.isRecording, !screenRecorder.isRecording else { return }

        guard let previewRect = previewRecordingRect() else {
            previewRecordingIndicator.hideIndicator()
            updateCameraPreview(recordingRect: nil)
            return
        }

        if recordingState.captureMode == .selectedArea {
            previewRecordingIndicator.showInteractiveIndicator(
                for: previewRect,
                aspectRatio: recordingState.areaAspectRatioPreset.aspectRatio ?? previewRect.width / max(previewRect.height, 1)
            ) { [weak self] rect in
                self?.updateSelectedAreaPreview(to: rect)
            }
        } else {
            previewRecordingIndicator.showIndicator(for: previewRect)
        }

        if recordingState.captureMode == .fullScreen {
            preparedDisplayID = selectedDisplayTarget?.id
        }

        updateCameraPreview(recordingRect: previewRect)

        if recordingState.captureMode == .selectedWindow {
            startSelectedWindowTracking()
        } else if !recordingState.isRecording && !screenRecorder.isRecording {
            stopSelectedWindowTracking()
        }
    }

    private func updateSelectedAreaPreview(to rect: CGRect) {
        guard isPreviewActive,
              recordingState.captureMode == .selectedArea,
              !recordingState.isRecording,
              !screenRecorder.isRecording
        else {
            return
        }

        if let cameraFrame = recordingState.customCameraOverlayFrame,
           !recordingState.selectedArea.isEmpty {
            let dx = rect.minX - recordingState.selectedArea.minX
            let dy = rect.minY - recordingState.selectedArea.minY
            recordingState.customCameraOverlayFrame = cameraFrame.offsetBy(dx: dx, dy: dy)
        }

        recordingState.selectedArea = rect
        recordingState.recordingMode = .selectedArea(rect)
        updateCameraPreview(recordingRect: rect)
    }

    func resetCustomCameraOverlayFrame() {
        recordingState.customCameraOverlayFrame = nil
        updatePreview()
    }

    func restartCameraPreview() {
        guard isPreviewActive else { return }

        if !recordingState.isRecording && !screenRecorder.isRecording {
            cameraManager.stopCapture()
        }

        updatePreview()
    }

    func endPreview() {
        isPreviewActive = false
        isPreviewing = false
        previewRecordingIndicator.hideIndicator()
        previewCameraWindow?.hide()
        previewCameraWindow = nil
        if !recordingState.isRecording && !screenRecorder.isRecording {
            stopSelectedWindowTracking()
        }

        if !recordingState.isRecording && !screenRecorder.isRecording {
            cameraManager.stopCapture()
        }
    }

    /// 暂停 / 继续录制。暂停期间不写入任何帧，恢复后时间轴顺延，
    /// 中间那段不会出现在成片里。
    func togglePauseRecording() {
        guard isRecording else { return }
        isRecordingPaused.toggle()
        screenRecorder.setPaused(isRecordingPaused)
        recordingState.setPaused(isRecordingPaused)
        registerUnfinishedRecording(state: isRecordingPaused ? "paused" : "recording")
    }

    /// 录制中打标记：把当前成片时间点写进 <输出>_markers.json。
    /// 讲课时想到"这段重来"或"这段保留"，点一下，剪辑时按标记定位。
    @discardableResult
    func addMarkerAtCurrentTime() -> RecordingMarker? {
        guard isRecording else { return nil }
        let marker = RecordingMarkerStore.append(
            elapsedSeconds: recordingState.recordingDuration,
            to: RecordingMarkerStore.markersURL(for: recordingState.outputURL)
        )
        print(String(format: "🔖 标记 %d（%.1fs）", marker.index + 1, marker.elapsedSeconds))
        return marker
    }

    /// --smoke-record 专用：合成光标事件，保证无人值守环境里光标链路
    /// （侧车 → 自动缩放 → 导出渲染）被确定性覆盖。坐标为主屏全局坐标。
    func simulateCursorEventForSmoke(x: Double, y: Double, click: Bool) {
        guard RecordingSmokeTestRunner.isRequested else { return }
        cursorTracker.simulateEvent(globalLocation: CGPoint(x: x, y: y), isClick: click)
    }

    /// Agent 剪辑：应用 edits.json 的结果。缩放区间改写前先备份
    /// （_zoom.json → _zoom.json.bak，非破坏数据层，AI 再怎么乱来素材都安全），
    /// 导出走应用自己的渲染管线——AI 只改参数，碰不到渲染。
    func applyAgentEdits(_ application: AgentEditApplication, to capturedOutput: CapturedRecordingOutput) {
        let zoomURL = ZoomRangeStore.zoomURL(for: capturedOutput.outputURL)
        if FileManager.default.fileExists(atPath: zoomURL.path) {
            let backupURL = URL(fileURLWithPath: zoomURL.path + ".bak")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: zoomURL, to: backupURL)
        }
        if !application.zoomRanges.isEmpty {
            ZoomRangeStore.save(
                ZoomRangeFile(source: "agent", ranges: application.zoomRanges),
                for: capturedOutput.outputURL
            )
        }
        renderCapturedRecording(
            capturedOutput,
            editDecision: application.editDecision,
            exportSettings: application.exportSettings
        )
    }

    func stopRecording(completion: (() -> Void)? = nil) {
        if let completion {
            pendingStopCompletions.append(completion)
        }

        guard !isStopping else { return }
        guard recordingState.isRecording || screenRecorder.isRecording else {
            runPendingStopCompletions()
            return
        }

        isStopping = true
        MemoryFootprint.log("录制 停止（停止前）")
        stopRecordingTimer()
        stopSelectedWindowTracking()
        recordingIndicator.hideIndicator()
        let expectedOutputURL = recordingState.outputURL
        if let snapshot = circularCameraWindow?.metadataSnapshot() {
            recordingState.customCameraOverlayFrame = snapshot.frame
        }
        circularCameraWindow?.hide()
        circularCameraWindow = nil

        Task {
            var didRunStopCompletions = false
            let runStopCompletionsIfNeeded = { [weak self] in
                guard !didRunStopCompletions else { return }
                didRunStopCompletions = true
                self?.runPendingStopCompletions()
            }

            do {
                pendingCapturedRecording = try await screenRecorder.stopRecording()
                    ?? capturedRecordingOutput(for: expectedOutputURL)
            } catch {
                lastError = error.localizedDescription
                pendingCapturedRecording = capturedRecordingOutput(for: expectedOutputURL)
            }

            recordingState.stopRecording()
            isRecording = false
            isStopping = false
            clearUnfinishedRecording(outputURL: expectedOutputURL)
            cursorTracker.stopSavingOutput(expectedOutputURL)
            generateAutoZoomRanges(outputURL: expectedOutputURL)
            endTranscriptCapture(outputURL: expectedOutputURL)
            writeIdleSuggestions(outputURL: expectedOutputURL)
            presentDamageAlertIfNeeded(
                validation: screenRecorder.lastValidation,
                outputURL: expectedOutputURL
            )
            runStopCompletionsIfNeeded()
        }
    }

    /// 录制损坏时当场告知用户。此前 damaged 只写进 metrics json，
    /// 用户直到导出看到全黑成片才知道录废了（2026-10-23 事故，HANDOVER 第 12 节）。
    private func presentDamageAlertIfNeeded(validation: RecordingOutputValidation?, outputURL: URL?) {
        guard let validation, validation.health == .damaged else { return }
        // 自测模式不能弹模态框（无人值守会卡死），只落日志与报告
        guard !RecordingSmokeTestRunner.isRequested else {
            print("🧪 [smoke] 损坏弹窗跳过：\(validation.issues.joined(separator: "；"))")
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "此条录制损坏，屏幕轨未能完整写入"
        let issues = validation.issues.isEmpty ? "原因未知" : validation.issues.joined(separator: "；")
        var informative = "原因：\(issues)\n导出只会得到全黑画面，请勿直接导出。"
        if let outputURL {
            informative += "\n文件：\(outputURL.path)"
        }
        informative += "\n摄像头轨与音频如果完好，仍可尝试仅导出摄像头画面。"
        alert.informativeText = informative
        alert.addButton(withTitle: "在 Finder 中显示")
        alert.addButton(withTitle: "知道了")
        if alert.runModal() == .alertFirstButtonReturn, let outputURL {
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        }
    }

    private func capturedRecordingOutput(for outputURL: URL) -> CapturedRecordingOutput? {
        CapturedRecordingOutput(discovering: outputURL)
    }

    func renderPendingCapturedRecording(
        mode: RecordingRenderMode,
        exportSettings: RecordingExportSettings = .default
    ) {
        guard let capturedOutput = pendingCapturedRecording, !isExporting else { return }
        renderCapturedRecording(capturedOutput, mode: mode, exportSettings: exportSettings)
    }

    func renderPendingCapturedRecording(
        editDecision: RecordingEditDecision,
        exportSettings: RecordingExportSettings = .default
    ) {
        renderPendingCapturedRecording(mode: .edited(editDecision), exportSettings: exportSettings)
    }

    func renderCapturedRecording(
        _ capturedOutput: CapturedRecordingOutput,
        editDecision: RecordingEditDecision,
        exportSettings: RecordingExportSettings = .default
    ) {
        renderCapturedRecording(capturedOutput, mode: .edited(editDecision), exportSettings: exportSettings)
    }

    func renderCapturedRecording(
        _ capturedOutput: CapturedRecordingOutput,
        mode: RecordingRenderMode,
        exportSettings: RecordingExportSettings = .default
    ) {
        // 导出闸门：屏幕轨损坏的 take 直接拒绝。放行的话导出会"成功"产出一个
        // 全黑成片，比报错更误导。覆盖所有导出入口（待处理、素材库、编辑决策）。
        let validation = RecordingOutputValidator.validate(outputURL: capturedOutput.outputURL)
        if let blocked = RecordingPreflight.exportBlockReason(for: validation) {
            lastError = blocked
            return
        }

        // Never drop an export request silently: keep the newest one and run it as soon as
        // the current export finishes.
        guard !isExporting else {
            queuedRenderRequest = QueuedRenderRequest(
                capturedOutput: capturedOutput,
                mode: mode,
                exportSettings: exportSettings
            )
            return
        }
        if pendingCapturedRecording?.outputURL.standardizedFileURL == capturedOutput.outputURL.standardizedFileURL {
            pendingCapturedRecording = nil
        }
        screenRecorder.renderCapturedRecording(capturedOutput, mode: mode, exportSettings: exportSettings)
    }

    func deletePendingCapturedRecording() {
        guard let capturedOutput = pendingCapturedRecording else { return }
        pendingCapturedRecording = nil
        deleteCapturedRecording(capturedOutput)
    }

    func deleteCapturedRecording(_ capturedOutput: CapturedRecordingOutput) {
        do {
            _ = try screenRecorder.deleteCapturedRecording(capturedOutput)
            lastOutputURL = nil
            exportStatusText = nil
            recordingLibraryChangeID = UUID()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handleRecordingPostProcessingEvent(_ event: RecordingPostProcessingEvent) {
        switch event {
        case .started(_, let mode):
            MemoryFootprint.log("后处理/导出 开始 (\(mode.statusText))")
            isExporting = true
            exportStatusText = uiText(mode.statusText)
        case .completed(let result):
            MemoryFootprint.log("后处理/导出 完成")
            isExporting = false
            exportStatusText = nil
            lastOutputURL = result.finalOutputURL
            recordingLibraryChangeID = UUID()
            revealRecordingInFinder(result.finalOutputURL)
            if let queued = queuedRenderRequest {
                queuedRenderRequest = nil
                renderCapturedRecording(
                    queued.capturedOutput,
                    mode: queued.mode,
                    exportSettings: queued.exportSettings
                )
            }
        }
    }

    /// 挂载转写钩子：提词器识别开着时，把讲的话连同成片时间点记进字幕稿。
    /// 暂停期间音频不进成片，暂停时的语音不记录，避免字幕与成片错位。
    /// 停录后依据光标事件轨生成自动缩放区间（点击 = 操作焦点，停留 = 阅读焦点）。
    /// 导出时 ZoomTimeline 按 <base>_zoom.json 做缓动放大。
    private func generateAutoZoomRanges(outputURL: URL) {
        guard let cursorTrack = CursorEventStore.load(from: CursorEventStore.cursorURL(for: outputURL)) else { return }
        let ranges = ZoomHeuristic.ranges(
            from: cursorTrack.events,
            totalDuration: recordingState.currentElapsed()
        )
        guard !ranges.isEmpty else { return }
        ZoomRangeStore.save(ZoomRangeFile(source: "auto-clicks-and-dwell", ranges: ranges), for: outputURL)
        print("🔍 自动缩放区间: \(ranges.count) 个 → \(outputURL.deletingPathExtension().lastPathComponent)_zoom.json")
    }

    /// 闲段建议：没说话∧没操作的段（剪掉或 3×），加开录头 1.5s 裁剪建议。
    /// 消费方是 Agent 剪辑提示词；转写缺失时宁缺毋滥。
    private func writeIdleSuggestions(outputURL: URL) {
        let transcript = TranscriptSRTSerializer.loadTranscript(for: outputURL)
        let cursorTrack = CursorEventStore.load(from: CursorEventStore.cursorURL(for: outputURL))
        let idle = RecordingIdleSpanDetector.detect(
            totalDuration: recordingState.currentElapsed(),
            transcript: transcript,
            cursorEvents: cursorTrack?.events ?? []
        )
        IdleSpanStore.save(idle, for: outputURL)
        if !idle.suggestions.isEmpty {
            print("💤 闲段建议: \(idle.suggestions.count) 段 → \(outputURL.deletingPathExtension().lastPathComponent)_idle.json")
        }
    }

    private func beginTranscriptCapture() {
        transcriptAccumulator = RecordingTranscriptAccumulator()
        let recognizer = CueRecordService.shared.overlayController.speechRecognizer
        recognizer.onTranscriptUpdate = { [weak self] text in
            guard let self, self.isRecording, !self.isRecordingPaused else { return }
            self.recordingState.updateRecordingDuration()
            self.transcriptAccumulator?.ingestUpdate(text, at: self.recordingState.recordingDuration)
        }
        recognizer.onTranscriptSegmentEnd = { [weak self] in
            guard let self, self.isRecording else { return }
            self.recordingState.updateRecordingDuration()
            self.transcriptAccumulator?.closeSegment(at: self.recordingState.recordingDuration)
        }
    }

    private func endTranscriptCapture(outputURL: URL) {
        let recognizer = CueRecordService.shared.overlayController.speechRecognizer
        recognizer.onTranscriptUpdate = nil
        recognizer.onTranscriptSegmentEnd = nil
        guard var accumulator = transcriptAccumulator else { return }
        transcriptAccumulator = nil
        recordingState.updateRecordingDuration()
        accumulator.closeSegment(at: recordingState.recordingDuration)
        guard !accumulator.segments.isEmpty else { return }
        TranscriptSRTSerializer.saveTranscript(accumulator.segments, for: outputURL)
        print("📝 字幕稿已保存: \(accumulator.segments.count) 段 → \(outputURL.deletingPathExtension().lastPathComponent).srt")
    }

    private func startRecording(
        displayID requestedDisplayID: CGDirectDisplayID? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !recordingState.isRecording && !screenRecorder.isRecording && !isStarting else {
            completion?(false)
            return
        }

        isStarting = true
        lastError = nil
        let displayIDForRecording = requestedDisplayID ?? preparedDisplayID ?? selectedDisplayTarget?.id

        Task {
            await permissionsManager.checkAllPermissions()

            if !permissionsManager.screenRecordingAuthorized {
                await permissionsManager.requestScreenRecordingPermission()
            }

            guard permissionsManager.screenRecordingAuthorized else {
                isStarting = false
                lastError = "Screen recording permission is required."
                completion?(false)
                return
            }

            if recordingState.microphoneEnabled && !permissionsManager.microphoneAuthorized {
                await permissionsManager.requestMicrophonePermission()
            }

            if recordingState.cameraOverlayEnabled && !permissionsManager.cameraAuthorized {
                await permissionsManager.requestCameraPermission()
            }

            if recordingState.cameraOverlayEnabled && !permissionsManager.cameraAuthorized {
                recordingState.cameraOverlayEnabled = false
            }

            // 停录体检：磁盘余量不足时拒绝开录。磁盘写满是 writer 中途失败的已知成因。
            if let spaceIssue = RecordingPreflight.freeSpaceIssue(
                availableBytes: RecordingPreflight.availableCapacity(on: recordingState.outputDirectory)
            ) {
                isStarting = false
                lastError = spaceIssue
                completion?(false)
                return
            }

            if case .selectedWindow = recordingState.recordingMode {
                _ = refreshSelectedWindowTarget()
            }

            recordingState.startRecording()
            recordingState.resetPauseAccounting()
            isRecordingPaused = false
            isRecording = true
            startRecordingTimer()

            do {
                // 光标事件轨：先起监听，成功后源画面才隐藏系统光标（导出端自绘）。
                if let recordingFrame = resolvedRecordingTarget(
                    mode: recordingState.recordingMode,
                    selectedDisplayID: displayIDForRecording
                )?.interfaceFrame {
                    cursorTracker.start(recordingRect: recordingFrame) { [weak self] in
                        self?.recordingState.samplingElapsed() ?? -1
                    }
                }

                try await screenRecorder.startRecording(
                    mode: recordingState.recordingMode,
                    outputURL: recordingState.outputURL,
                    cameraOverlay: recordingState.cameraOverlayEnabled,
                    cameraPosition: recordingState.cameraOverlayPosition,
                    cameraSize: recordingState.cameraOverlaySize,
                    systemAudioEnabled: recordingState.systemAudioEnabled,
                    microphoneEnabled: recordingState.microphoneEnabled,
                    microphoneDeviceID: audioManager.getMicrophoneDeviceIDForSCK(),
                    microphoneAudioDeviceID: audioManager.selectedMicrophone.deviceID,
                    displayID: displayIDForRecording,
                    hideSystemCursor: cursorTracker.isActive
                )

                showRecordingOverlays()
                registerUnfinishedRecording(state: "recording")
                beginTranscriptCapture()
                MemoryFootprint.log("录制 开始")
                completion?(true)
            } catch {
                cursorTracker.stop()
                recordingState.stopRecording()
                isRecording = false
                stopRecordingTimer()
                lastError = error.localizedDescription
                completion?(false)
            }

            isStarting = false
        }
    }

    private func beginPreparedRecording(
        displayID requestedDisplayID: CGDirectDisplayID? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        endPreview()
        startRecording(displayID: requestedDisplayID) { [weak self] started in
            if !started {
                self?.beginPreview()
            }
            completion(started)
        }
    }

    private func showRecordingOverlays() {
        if case .selectedArea(let rect) = recordingState.recordingMode {
            recordingIndicator.showIndicator(for: rect)
        }

        if case .selectedWindow = recordingState.recordingMode {
            startSelectedWindowTracking()
        }

        guard recordingState.cameraOverlayEnabled else { return }

        if circularCameraWindow == nil {
            circularCameraWindow = CircularCameraWindow(cameraManager: cameraManager)
        }

        circularCameraWindow?.show(
            at: recordingState.cameraOverlayPosition,
            size: recordingState.cameraOverlaySize,
            shape: recordingState.cameraOverlayShape,
            recordingRect: currentRecordingFrame(),
            customFrame: recordingState.customCameraOverlayFrame
        ) { [weak self] frame in
            self?.recordingState.customCameraOverlayFrame = frame
        }
    }

    private func currentRecordingFrame() -> CGRect? {
        resolvedRecordingTarget()?.overlayFrame
    }

    private var displayGeometries: [RecordingDisplayGeometry] {
        availableDisplays.map { display in
            RecordingDisplayGeometry(
                id: display.id,
                frame: display.frame,
                name: display.name,
                index: display.index
            )
        }
    }

    private func resolvedRecordingTarget(
        mode: RecordingMode? = nil,
        selectedDisplayID: CGDirectDisplayID? = nil
    ) -> ResolvedRecordingTarget? {
        let activeMode = mode ?? recordingState.recordingMode
        let activeDisplayID = selectedDisplayID
            ?? preparedDisplayID
            ?? recordingState.selectedDisplayID
            ?? selectedDisplayTarget?.id

        return ResolvedRecordingTarget.resolve(
            mode: activeMode,
            selectedDisplayID: activeDisplayID,
            displays: displayGeometries
        )
    }

    private func setSelectedWindowTarget(_ target: WindowRecordingTarget) {
        recordingState.selectedWindowTarget = target
        recordingState.selectedArea = target.frame
        recordingState.recordingMode = .selectedWindow(target)
    }

    private func refreshedWindowTarget(_ target: WindowRecordingTarget) -> WindowRecordingTarget? {
        windowSelector.refreshedTarget(target)
    }

    @discardableResult
    private func refreshSelectedWindowTarget() -> (target: WindowRecordingTarget, frameChanged: Bool)? {
        guard let currentTarget = activeSelectedWindowTarget(),
              let refreshedTarget = refreshedWindowTarget(currentTarget)
        else {
            return nil
        }

        let frameChanged = !rectsApproximatelyEqual(currentTarget.frame, refreshedTarget.frame)
        if frameChanged
            || recordingState.selectedWindowTarget?.windowID != refreshedTarget.windowID
            || recordingState.selectedWindowTarget?.title != refreshedTarget.title
            || recordingState.selectedWindowTarget?.ownerName != refreshedTarget.ownerName {
            setSelectedWindowTarget(refreshedTarget)
        }

        return (refreshedTarget, frameChanged)
    }

    private func activeSelectedWindowTarget() -> WindowRecordingTarget? {
        if let target = recordingState.selectedWindowTarget {
            return target
        }

        if case .selectedWindow(let target) = recordingState.recordingMode {
            return target
        }

        return nil
    }

    private func rectsApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.5
            && abs(lhs.origin.y - rhs.origin.y) < 0.5
            && abs(lhs.width - rhs.width) < 0.5
            && abs(lhs.height - rhs.height) < 0.5
    }

    private func startSelectedWindowTracking() {
        guard selectedWindowTrackingTimer == nil else { return }

        selectedWindowTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.updateSelectedWindowTracking()
            }
        }
    }

    private func stopSelectedWindowTracking() {
        selectedWindowTrackingTimer?.invalidate()
        selectedWindowTrackingTimer = nil
    }

    private func updateSelectedWindowTracking() {
        let shouldTrackPreview = isPreviewActive && recordingState.captureMode == .selectedWindow
        let shouldTrackRecording: Bool
        if case .selectedWindow = recordingState.recordingMode {
            shouldTrackRecording = recordingState.isRecording || screenRecorder.isRecording
        } else {
            shouldTrackRecording = false
        }

        guard shouldTrackPreview || shouldTrackRecording else {
            stopSelectedWindowTracking()
            return
        }

        guard let refresh = refreshSelectedWindowTarget() else {
            if shouldTrackPreview {
                previewRecordingIndicator.hideIndicator()
                updateCameraPreview(recordingRect: nil)
            }
            return
        }

        guard refresh.frameChanged else { return }

        if shouldTrackPreview {
            updatePreview()
        }

        if shouldTrackRecording {
            updateRecordingCameraWindow(recordingRect: refresh.target.frame)
        }
    }

    private func updateRecordingCameraWindow(recordingRect: CGRect?) {
        guard recordingState.cameraOverlayEnabled else { return }

        circularCameraWindow?.show(
            at: recordingState.cameraOverlayPosition,
            size: recordingState.cameraOverlaySize,
            shape: recordingState.cameraOverlayShape,
            recordingRect: recordingRect,
            customFrame: recordingState.customCameraOverlayFrame
        ) { [weak self] frame in
            self?.recordingState.customCameraOverlayFrame = frame
        }
    }

    private func updateCameraPreview(recordingRect: CGRect?) {
        guard recordingState.cameraOverlayEnabled else {
            previewCameraWindow?.hide()
            previewCameraWindow = nil

            if !recordingState.isRecording && !screenRecorder.isRecording {
                cameraManager.stopCapture()
            }
            return
        }

        if previewCameraWindow == nil {
            previewCameraWindow = CircularCameraWindow(cameraManager: cameraManager)
        }

        previewCameraWindow?.show(
            at: recordingState.cameraOverlayPosition,
            size: recordingState.cameraOverlaySize,
            shape: recordingState.cameraOverlayShape,
            recordingRect: recordingRect,
            customFrame: recordingState.customCameraOverlayFrame
        ) { [weak self] frame in
            self?.recordingState.customCameraOverlayFrame = frame
        }

        Task { @MainActor [weak self] in
            guard let self, self.isPreviewActive, !self.recordingState.isRecording, !self.screenRecorder.isRecording else { return }

            await self.permissionsManager.checkCameraPermission()
            guard self.permissionsManager.cameraAuthorized else { return }

            self.cameraManager.refreshCameraDevices()

            do {
                try await self.cameraManager.startCapture()
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    private func previewRecordingRect() -> CGRect? {
        switch recordingState.captureMode {
        case .fullScreen:
            return previewScreenRect()
        case .selectedArea:
            if !recordingState.selectedArea.isEmpty {
                return recordingState.selectedArea
            }
            return defaultAreaPreviewRect()
        case .selectedWindow:
            return previewWindowRect() ?? defaultAreaPreviewRect()
        }
    }

    private func previewScreenRect() -> CGRect? {
        selectedDisplayTarget?.frame.insetBy(dx: 8, dy: 8)
    }

    private func defaultAreaPreviewRect() -> CGRect? {
        let screen = screen(for: selectedDisplayTarget?.id) ?? NSScreen.main
        guard let screen else { return nil }

        let visibleFrame = screen.visibleFrame
        let fallbackAspectRatio: CGFloat = 16.0 / 9.0
        let aspectRatio = recordingState.areaAspectRatioPreset.aspectRatio ?? fallbackAspectRatio

        var width = visibleFrame.width * 0.62
        var height = width / aspectRatio

        if height > visibleFrame.height * 0.62 {
            height = visibleFrame.height * 0.62
            width = height * aspectRatio
        }

        return CGRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func screen(for displayID: CGDirectDisplayID?) -> NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first { CGDirectDisplayID($0.displayID) == displayID }
    }

    private func previewWindowRect() -> CGRect? {
        if let target = refreshSelectedWindowTarget()?.target ?? recordingState.selectedWindowTarget {
            return target.frame.insetBy(dx: 4, dy: 4)
        }

        return NSApp.windows
            .first { window in
                !(window is NSPanel)
                    && window.isVisible
                    && window.frame.width > 120
                    && window.frame.height > 120
            }?
            .frame
            .insetBy(dx: 4, dy: 4)
    }

    private func startRecordingTimer() {
        stopRecordingTimer()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.recordingState.updateRecordingDuration()
            }
        }
        // 资源水位巡检是 ScreenRecorder 里 60s 一次的粗巡检；
        // 这里每 2s 把结论搬到 lastError（UI 提示条），异常期间高频可见。
        resourceUITimer?.invalidate()
        resourceUITimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                if let issue = self.screenRecorder.lastResourceIssue, self.lastError != issue {
                    self.lastError = issue
                }
            }
        }
    }

    private var resourceUITimer: Timer?

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        resourceUITimer?.invalidate()
        resourceUITimer = nil
    }

    private func runPendingStopCompletions() {
        let completions = pendingStopCompletions
        pendingStopCompletions.removeAll()
        completions.forEach { $0() }
    }

    private func preferredCompletedOutputURL(for baseOutputURL: URL) -> URL? {
        let fileManager = FileManager.default
        let basePath = baseOutputURL.deletingPathExtension().path
        let fileExtension = baseOutputURL.pathExtension

        let compositedURL = URL(fileURLWithPath: "\(basePath)_composited.\(fileExtension)")
        if fileManager.fileExists(atPath: compositedURL.path) {
            return compositedURL
        }

        if fileManager.fileExists(atPath: baseOutputURL.path) {
            return baseOutputURL
        }

        let cameraURL = URL(fileURLWithPath: "\(basePath)_camera.\(fileExtension)")
        if fileManager.fileExists(atPath: cameraURL.path) {
            return cameraURL
        }

        return nil
    }

    private func revealRecordingInFinder(_ url: URL) {
        NSWorkspace.shared.open(url.deletingLastPathComponent())
    }

    private func configureOutputDirectory() {
        let outputDirectory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        recordingState.outputDirectory = outputDirectory
    }
}

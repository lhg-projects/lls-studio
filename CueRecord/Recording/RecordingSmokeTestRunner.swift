import AVFoundation
import Foundation
import AppKit

/// 内置自测入口（学习 HuaStudio 的 --smoke-* 设计）。
///
/// 用 `open LLSStudio.app --args --smoke-record` 启动后自动执行：
/// 录 3s → 打标记 → 暂停 3s → 恢复 3s → 停止 → 导出 → 校验。
/// 不依赖任何外部 UI 驱动，正好闭环「暂停是否真的剪掉那段」这个
/// 悬了很久的验证（HANDOVER 第 11/13 节）。
///
/// 结果写 /tmp/llsstudio-smoke-report.json，全部通过后应用自动退出，
/// 退出码由报告的 allOk 决定（脚本可据此判绿）。
@MainActor
enum RecordingSmokeTestRunner {
    static let argument = "--smoke-record"
    static let reportPath = "/tmp/llsstudio-smoke-report.json"

    private static var didRun = false

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }

    static func runIfNeeded() async {
        guard isRequested, !didRun else { return }
        didRun = true
        await run()
    }

    private static func run() async {
        var report: [String: Any] = [
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "scenario": "record3s-pause3s-resume3s-stop-export"
        ]
        var allOk = true

        let controller = RecordingController.shared
        // 自测要确定性：全屏模式、摄像头关闭（避免无人值守时录到人脸）。
        // 用户原设置事后恢复。自动缩放默认关闭，自测要覆盖缩放管线全程，显式打开。
        let previousMode = controller.recordingState.captureMode
        let previousCamera = controller.recordingState.cameraOverlayEnabled
        let previousAutoZoom = controller.isAutoZoomEnabled
        controller.recordingState.captureMode = .fullScreen
        controller.recordingState.cameraOverlayEnabled = false
        controller.setAutoZoomEnabled(true)
        defer {
            controller.recordingState.captureMode = previousMode
            controller.recordingState.cameraOverlayEnabled = previousCamera
            controller.setAutoZoomEnabled(previousAutoZoom)
        }

        print("🧪 [smoke] 开始：录 3s → 暂停 3s → 恢复 3s → 停止 → 导出")

        // 1. 开录
        let started = await withCheckedContinuation { continuation in
            controller.startConfiguredRecording { started in
                continuation.resume(returning: started)
            }
        }
        guard started else {
            fail(&report, &allOk, "start", "开录失败: \(controller.lastError ?? "未知")")
            finish(report, allOk)
            return
        }
        report["started"] = true
        let outputURL = controller.recordingState.outputURL
        let mainScreen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        // 2. 录 3s：中途合成光标事件（移动 + 点击 + 移动），无人值守也能
        //    确定性覆盖光标链路；打一个标记
        try? await Task.sleep(nanoseconds: 800_000_000)
        controller.simulateCursorEventForSmoke(x: mainScreen.midX, y: mainScreen.midY, click: false)
        try? await Task.sleep(nanoseconds: 400_000_000)
        let marker = controller.addMarkerAtCurrentTime()
        report["markerAdded"] = marker != nil
        try? await Task.sleep(nanoseconds: 400_000_000)
        controller.simulateCursorEventForSmoke(
            x: mainScreen.midX + mainScreen.width * 0.05,
            y: mainScreen.midY,
            click: true
        )
        try? await Task.sleep(nanoseconds: 1_400_000_000)

        // 3. 暂停 3s（这段不应进入成片）
        let wallClockBeforePause = Date()
        controller.togglePauseRecording()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        controller.togglePauseRecording()
        let pauseWallSeconds = Date().timeIntervalSince(wallClockBeforePause)

        // 4. 恢复再录 3s（再动一下光标），然后停止
        try? await Task.sleep(nanoseconds: 800_000_000)
        controller.simulateCursorEventForSmoke(
            x: mainScreen.midX - mainScreen.width * 0.08,
            y: mainScreen.midY + mainScreen.height * 0.05,
            click: false
        )
        try? await Task.sleep(nanoseconds: 2_200_000_000)
        let stopped = await withCheckedContinuation { continuation in
            controller.stopRecording {
                continuation.resume(returning: true)
            }
        }
        report["stopped"] = stopped
        guard stopped, let captured = controller.pendingCapturedRecording else {
            fail(&report, &allOk, "stop", "停录后没有可用的录制产物")
            finish(report, allOk)
            return
        }

        // 5. 校验原始屏幕轨：约 6s（3+3），暂停段必须不在里面
        let rawDuration = assetDuration(of: captured.outputURL)
        report["rawOutputURL"] = captured.outputURL.path
        report["rawDurationSeconds"] = rawDuration
        if let rawDuration {
            // 墙钟约 9s+（3+3+3 加操作余量）；成片应显著小于墙钟且接近 6s
            if rawDuration > 7.5 || rawDuration < 3.5 {
                fail(&report, &allOk, "pauseCut", String(format: "屏幕轨 %.2fs，暂停段疑似未被剪掉（期望约 6s）", rawDuration))
            } else {
                report["pauseCut"] = String(format: "ok（%.2fs，墙钟暂停段 %.2fs 未计入）", rawDuration, pauseWallSeconds)
            }
        } else {
            fail(&report, &allOk, "pauseCut", "屏幕轨不可读——录制产物损坏")
        }

        // 6. 侧车齐全性：合成事件保证光标轨必须存在且事件数够（移动+点击+移动）
        let cursorTrackFile = CursorEventStore.load(from: CursorEventStore.cursorURL(for: captured.outputURL))
        let cursorEventCount = cursorTrackFile?.events.count ?? 0
        report["cursorEventCount"] = cursorEventCount
        if cursorEventCount < 3 {
            fail(&report, &allOk, "cursorTrack", "光标事件应有 ≥3 条（合成 3 条），实际 \(cursorEventCount)")
        } else {
            report["cursorTrack"] = true
        }
        let markers = RecordingMarkerStore.load(from: RecordingMarkerStore.markersURL(for: captured.outputURL))
        report["markerCount"] = markers.count
        if markers.count != 1 {
            fail(&report, &allOk, "markers", "应有 1 个标记，实际 \(markers.count)")
        }
        // 合成的点击应触发自动缩放区间
        let zoomRanges = ZoomRangeStore.load(from: ZoomRangeStore.zoomURL(for: captured.outputURL))?.ranges ?? []
        report["zoomRangeCount"] = zoomRanges.count
        if zoomRanges.isEmpty {
            fail(&report, &allOk, "autoZoom", "合成点击后应生成自动缩放区间")
        }

        // 7. 导出：走 .edited 渲染路径（单段全时长、纯屏幕布局），
        //    才能真实过一遍"缩放裁切 + 自绘光标 + 30fps CFR"的渲染循环
        let fullRangeCut = RecordingEditCut(
            startTime: 0,
            endTime: (rawDuration ?? 6) + 1,
            layoutMode: .screenFullScreen,
            cameraFrame: .defaultCameraFrame,
            cameraShape: .circle
        )
        controller.renderPendingCapturedRecording(
            editDecision: RecordingEditDecision(cuts: [fullRangeCut]),
            exportSettings: .default
        )
        let exportDeadline = Date().addingTimeInterval(180)
        var exportedURL: URL?
        while Date() < exportDeadline {
            if !controller.isExporting, let url = controller.lastOutputURL {
                exportedURL = url
                break
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if let exportedURL {
            let exportDuration = assetDuration(of: exportedURL)
            report["exportedURL"] = exportedURL.path
            report["exportDurationSeconds"] = exportDuration
            if let exportDuration, exportDuration > 0.5, exportedURL.path != captured.outputURL.path {
                report["export"] = String(format: "ok（%.2fs，渲染产物独立落盘）", exportDuration)
            } else if exportedURL.path == captured.outputURL.path {
                fail(&report, &allOk, "export", "导出结果指向原始轨，渲染循环未执行")
            } else {
                fail(&report, &allOk, "export", "导出文件不可读或时长异常")
            }
        } else {
            fail(&report, &allOk, "export", "导出超时（180s）")
        }

        finish(report, allOk)
    }

    private static func assetDuration(of url: URL) -> Double? {
        let asset = AVURLAsset(url: url)
        guard asset.tracks(withMediaType: .video).count > 0,
              asset.duration.isValid, asset.duration.seconds > 0 else { return nil }
        return asset.duration.seconds
    }

    private static func fail(
        _ report: inout [String: Any],
        _ allOk: inout Bool,
        _ key: String,
        _ message: String
    ) {
        report[key] = "FAIL: \(message)"
        allOk = false
        print("🧪 [smoke] FAIL \(key): \(message)")
    }

    private static func finish(_ report: [String: Any], _ allOk: Bool) {
        var final = report
        final["allOk"] = allOk
        final["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: final, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        }
        print("🧪 [smoke] \(allOk ? "PASS 全部通过" : "FAIL 存在失败项")，报告: \(reportPath)")
        Task { @MainActor in
            // 给 stdout 一点落盘时间再退出
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSApp.terminate(nil)
        }
    }
}

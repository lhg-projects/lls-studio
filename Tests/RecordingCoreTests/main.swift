import CoreGraphics
import CoreImage
import CoreMedia
import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure.failed(message)
    }
}

func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

func testAudioStartGate() throws {
    let gate = AudioStartGate(holdLimit: seconds(0.5))
    let firstVideo = seconds(1.0)

    try expect(
        gate.decision(audioStart: seconds(0.9), audioDuration: seconds(0.05), firstVideoStart: nil) == .waitForVideo,
        "Audio should wait while video start is unknown"
    )

    switch gate.decision(audioStart: seconds(0.2), audioDuration: seconds(0.2), firstVideoStart: firstVideo) {
    case .dropBeforeVideo:
        break
    default:
        throw TestFailure.failed("Audio that ends before first video should be dropped")
    }

    switch gate.decision(audioStart: seconds(0.95), audioDuration: seconds(0.1), firstVideoStart: firstVideo) {
    case .append(let relativeTo, let partialOverlap):
        try expect(relativeTo == firstVideo, "Overlapping audio should stay on the video time base")
        try expect(partialOverlap == seconds(0.05), "Overlap duration should be measured")
    default:
        throw TestFailure.failed("Overlapping audio should be appended")
    }

    switch gate.decision(audioStart: seconds(1.2), audioDuration: seconds(0.1), firstVideoStart: firstVideo) {
    case .append(let relativeTo, let partialOverlap):
        try expect(relativeTo == firstVideo, "Post-video audio should use first video as offset")
        try expect(partialOverlap == .zero, "Post-video audio should have no partial overlap")
    default:
        throw TestFailure.failed("Post-video audio should be appended")
    }

    try expect(
        gate.shouldKeepPendingAudio(newestAudioStart: seconds(1.0), oldestAudioStart: seconds(0.55)),
        "Pending audio within hold limit should be kept"
    )
    try expect(
        !gate.shouldKeepPendingAudio(newestAudioStart: seconds(1.0), oldestAudioStart: seconds(0.4)),
        "Pending audio beyond hold limit should be trimmed"
    )
}

func testBoundedDropOldestBuffer() throws {
    var buffer = BoundedDropOldestBuffer<Int>(capacity: 2)
    buffer.append(1)
    buffer.append(2)
    buffer.append(3)

    try expect(buffer.droppedCount == 1, "Buffer should count dropped oldest entries")
    try expect(buffer.removeAll() == [2, 3], "Buffer should keep newest entries")
    try expect(buffer.isEmpty, "removeAll should empty the buffer")
}

func testResolvedRecordingTarget() throws {
    let displayOne = RecordingDisplayGeometry(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 100, height: 100),
        name: "Internal",
        index: 0
    )
    let displayTwo = RecordingDisplayGeometry(
        id: 2,
        frame: CGRect(x: 100, y: 0, width: 200, height: 100),
        name: "External",
        index: 1
    )
    let displays = [displayOne, displayTwo]

    let fullScreen = ResolvedRecordingTarget.resolve(
        mode: .fullScreen,
        selectedDisplayID: 2,
        displays: displays
    )
    try expect(fullScreen?.displayID == 2, "Full-screen target should honor selected display")
    try expect(fullScreen?.interfaceFrame == displayTwo.frame, "Full-screen interface frame should be selected display")

    let area = ResolvedRecordingTarget.resolve(
        mode: .selectedArea(CGRect(x: 140, y: 20, width: 60, height: 60)),
        selectedDisplayID: 1,
        displays: displays
    )
    try expect(area?.displayID == 2, "Area target should use the display with the largest intersection")
    try expect(area?.overlayFrame == CGRect(x: 140, y: 20, width: 60, height: 60), "Area overlay should be the capture rect")

    let windowTarget = WindowRecordingTarget(
        windowID: 42,
        frame: CGRect(x: 20, y: 10, width: 50, height: 50),
        title: "Doc",
        ownerName: "App"
    )
    let window = ResolvedRecordingTarget.resolve(
        mode: .selectedWindow(windowTarget),
        selectedDisplayID: 2,
        displays: displays
    )
    try expect(window?.displayID == 1, "Window target should follow the window display")
    try expect(window?.modeName == "selectedWindow", "Window target should expose mode name")
}

func testMetricsURLAndMissingOutputValidation() throws {
    let outputURL = URL(fileURLWithPath: "/tmp/CueRecord Sample.mov")
    let metricsURL = RecordingMetricsRecorder.metricsURL(for: outputURL)
    try expect(metricsURL.lastPathComponent == "CueRecord Sample_metrics.json", "Metrics URL should use output base name")

    let missingURL = URL(fileURLWithPath: "/tmp/cuerecord-missing-\(UUID().uuidString).mov")
    let validation = RecordingOutputValidator.validate(outputURL: missingURL)
    try expect(validation.health == .damaged, "Missing output should be damaged")
    try expect(validation.issues.contains("Output file does not exist"), "Missing output should report a clear issue")
}

func testRecordingPixelFormatPolicy() throws {
    try expect(
        RecordingPixelFormatPolicy.format(from: "bgra") == .bgra,
        "BGRA alias should resolve"
    )
    try expect(
        RecordingPixelFormatPolicy.format(from: "420v") == .yuv420VideoRange,
        "420v alias should resolve"
    )
    try expect(
        RecordingPixelFormatPolicy.format(from: "NV12") == .yuv420VideoRange,
        "NV12 alias should map to video-range 420"
    )
    try expect(
        RecordingPixelFormatPolicy.format(from: "420f") == .yuv420FullRange,
        "420f alias should resolve"
    )

    let suiteName = "CueRecordRecordingPixelFormatPolicyTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    try expect(
        RecordingPixelFormatPolicy.selectedFormat(defaults: defaults, environment: [:]) == .bgra,
        "Default capture pixel format should stay BGRA until a quality path is explicitly enabled"
    )

    defaults.set("420v", forKey: RecordingPixelFormatPolicy.userDefaultsKey)
    try expect(
        RecordingPixelFormatPolicy.selectedFormat(defaults: defaults, environment: [:]) == .yuv420VideoRange,
        "Stored 420v preference should select video-range 420"
    )

    try expect(
        RecordingPixelFormatPolicy.selectedFormat(
            defaults: defaults,
            environment: [RecordingPixelFormatPolicy.environmentKey: "420f"]
        ) == .yuv420FullRange,
        "Environment override should take precedence over stored preference"
    )
}

func testRecordingExportSettings() throws {
    // 默认导出改成 1080p：录课够用，导出帧缓冲只有 4K 的四分之一
    let defaultSettings = RecordingExportSettings.default
    try expect(defaultSettings.resolutionPreset == .p1080, "Default export resolution should be 1080p")
    try expect(defaultSettings.bitRatePreset == .medium, "Default export bitrate should be medium")

    let fiveKSize = CGSize(width: 5120, height: 2880)
    let defaultOutputSize = defaultSettings.outputSize(for: fiveKSize)
    try expect(defaultOutputSize == CGSize(width: 1920, height: 1080), "1080p export should cap 5K landscape sources at 1920 x 1080")
    try expect(defaultSettings.outputDimensionsText(for: fiveKSize) == "1920 x 1080", "Expected dimensions text should match the 1080p output size")

    // 默认已开启 16:9 裁切，竖屏源会被裁成 1080x608；不裁切的竖屏仍保持原始比例
    let portraitOutputSize = defaultSettings.outputSize(for: CGSize(width: 2880, height: 5120))
    try expect(portraitOutputSize == CGSize(width: 1920, height: 1080), "默认 16:9 裁切会把大尺寸竖屏源裁成 1920x1080")
    let uncroppedPortrait = RecordingExportSettings(resolutionPreset: .p1080, bitRatePreset: .medium, cropTo16x9: false)
    try expect(uncroppedPortrait.outputSize(for: CGSize(width: 2880, height: 5120)) == CGSize(width: 1080, height: 1920),
               "不裁切时竖屏保持原始比例")

    let smallSourceSize = CGSize(width: 1280, height: 720)
    try expect(defaultSettings.outputSize(for: smallSourceSize) == smallSourceSize, "1080p export should not upscale smaller sources")

    let fourKSettings = RecordingExportSettings(resolutionPreset: .p4K, bitRatePreset: .medium)
    try expect(fourKSettings.outputSize(for: fiveKSize) == CGSize(width: 3840, height: 2160), "4K preset should still cap landscape sources at 3840 x 2160")

    let hdSettings = RecordingExportSettings(resolutionPreset: .p1080, bitRatePreset: .low)
    try expect(hdSettings.outputSize(for: fiveKSize) == CGSize(width: 1920, height: 1080), "1080p export should cap landscape sources at 1920 x 1080")
    try expect(hdSettings.averageBitRate(for: CGSize(width: 1920, height: 1080)) == 4_147_200, "Low bitrate should scale from output pixels")
}

func testRecordingArtifactOrganizer() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("CueRecordArtifactOrganizer-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let finalURL = root.appendingPathComponent("ScreenRecord_2026-06-10_17-33-36_composited.mov")
    let rawScreenURL = root.appendingPathComponent("ScreenRecord_2026-06-10_17-33-36.mov")
    let cameraURL = root.appendingPathComponent("ScreenRecord_2026-06-10_17-33-36_camera.mov")
    let overlayURL = root.appendingPathComponent("ScreenRecord_2026-06-10_17-33-36_overlay.json")
    let metricsURL = root.appendingPathComponent("ScreenRecord_2026-06-10_17-33-36_metrics.json")

    for url in [finalURL, rawScreenURL, cameraURL, overlayURL, metricsURL] {
        try Data(url.lastPathComponent.utf8).write(to: url)
    }

    let movedURLs = try RecordingArtifactOrganizer.moveRawArtifacts(in: root, keeping: finalURL)
    let rawDataURL = root.appendingPathComponent(RecordingArtifactOrganizer.rawDataDirectoryName, isDirectory: true)

    try expect(fileManager.fileExists(atPath: finalURL.path), "Final composited export should stay in the session folder")
    try expect(!fileManager.fileExists(atPath: rawScreenURL.path), "Raw screen recording should leave the session folder")
    try expect(fileManager.fileExists(atPath: rawDataURL.appendingPathComponent(rawScreenURL.lastPathComponent).path), "Raw screen recording should move into raw_data")
    try expect(fileManager.fileExists(atPath: rawDataURL.appendingPathComponent(cameraURL.lastPathComponent).path), "Camera recording should move into raw_data")
    try expect(fileManager.fileExists(atPath: rawDataURL.appendingPathComponent(overlayURL.lastPathComponent).path), "Overlay metadata should move into raw_data")
    try expect(fileManager.fileExists(atPath: rawDataURL.appendingPathComponent(metricsURL.lastPathComponent).path), "Metrics should move into raw_data")
    try expect(movedURLs.count == 4, "Only non-final root artifacts should move into raw_data")
}

func testRecordingArtifactDeletion() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("CueRecordArtifactDeletion-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let screenURL = root.appendingPathComponent("ScreenRecord_2026-06-10_17-33-36.mov")
    let cameraURL = root.appendingPathComponent("ScreenRecord_2026-06-10_17-33-36_camera.mov")
    let overlayURL = root.appendingPathComponent("ScreenRecord_2026-06-10_17-33-36_overlay.json")
    let unrelatedURL = root.appendingPathComponent("notes.md")

    for url in [screenURL, cameraURL, overlayURL, unrelatedURL] {
        try Data(url.lastPathComponent.utf8).write(to: url)
    }

    let capturedOutput = CapturedRecordingOutput(
        outputURL: screenURL,
        cameraURL: cameraURL,
        overlayMetadataURL: overlayURL
    )
    let deletedURLs = try RecordingArtifactOrganizer.deleteArtifacts(for: capturedOutput)

    try expect(!fileManager.fileExists(atPath: screenURL.path), "Delete should remove the raw screen recording")
    try expect(!fileManager.fileExists(atPath: cameraURL.path), "Delete should remove the camera recording")
    try expect(!fileManager.fileExists(atPath: overlayURL.path), "Delete should remove overlay metadata")
    try expect(fileManager.fileExists(atPath: unrelatedURL.path), "Delete should keep unrelated project files")
    try expect(deletedURLs.count == 3, "Delete should report only the removed recording files")
}

func testCueRecordPathPolicy() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("CueRecordPathPolicy-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    try expect(
        CueRecordPathPolicy.sanitizedPathComponent("CON") == "_CON",
        "Windows reserved names should be prefixed"
    )

    let sanitized = CueRecordPathPolicy.sanitizedPathComponent("  ../Deck: intro?/  ")
    try expect(!sanitized.contains("/"), "Sanitized names should not contain path separators")
    try expect(!sanitized.contains(":"), "Sanitized names should not contain colon characters")
    try expect(!sanitized.isEmpty, "Sanitized names should not be empty")

    let existing = root.appendingPathComponent("Clip.md")
    try Data().write(to: existing)

    let unique = CueRecordPathPolicy.uniqueFileURL(in: root, title: "Clip", pathExtension: "md")
    try expect(unique.lastPathComponent == "Clip 2.md", "Unique file URLs should avoid existing files")

    let excluded = CueRecordPathPolicy.uniqueFileURL(
        in: root,
        title: "Clip",
        pathExtension: "md",
        excluding: existing
    )
    try expect(excluded.lastPathComponent == "Clip.md", "Excluded URLs should be reusable for renames")
}

func testCueRecordProjectManifestAndConflictDetection() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("CueRecordProjectStore-\(UUID().uuidString)", isDirectory: true)
    let projectURL = root.appendingPathComponent("Project", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
    let store = CueRecordProjectStore(projectURL: projectURL)
    let firstURL = projectURL.appendingPathComponent("First.md")
    try "one".write(to: firstURL, atomically: true, encoding: .utf8)

    let manifest = try store.syncManifest(
        markdownURLs: [firstURL],
        titles: ["First"],
        pages: ["one"],
        selectedURL: firstURL
    )
    try expect(manifest.files.count == 1, "Manifest should track markdown files")
    try expect(manifest.selectedFileID == manifest.files.first?.id, "Manifest should track selected file ID")

    let originalFileID = manifest.files[0].id
    let renamedURL = projectURL.appendingPathComponent("Renamed.md")
    try fileManager.moveItem(at: firstURL, to: renamedURL)
    try store.recordMarkdownRename(
        from: firstURL,
        to: renamedURL,
        title: "Renamed",
        contentHash: CueRecordPathPolicy.contentHash("one")
    )
    let renamedManifest = try store.syncManifest(
        markdownURLs: [renamedURL],
        titles: ["Renamed"],
        pages: ["one"],
        selectedURL: renamedURL
    )
    try expect(renamedManifest.files.first?.id == originalFileID, "Renamed markdown should keep its stable file ID")
    try expect(store.selectedMarkdownURL(from: [renamedURL]) == renamedURL, "Selected markdown should resolve from manifest")

    let snapshot = CueRecordFileSnapshot.current(for: renamedURL, cachedText: "one")
    try "outside".write(to: renamedURL, atomically: true, encoding: .utf8)

    do {
        _ = try store.writeMarkdown("inside", to: renamedURL, expectedSnapshot: snapshot)
        throw TestFailure.failed("Stale snapshots should reject writes")
    } catch is CueRecordFileConflictError {
        let diskText = try String(contentsOf: renamedURL, encoding: .utf8)
        try expect(diskText == "outside", "Conflict detection should not overwrite disk changes")
    }

    let freshSnapshot = CueRecordFileSnapshot.current(for: renamedURL, cachedText: "outside")
    _ = try store.writeMarkdown("inside", to: renamedURL, expectedSnapshot: freshSnapshot)
    let updatedText = try String(contentsOf: renamedURL, encoding: .utf8)
    try expect(updatedText == "inside", "Fresh snapshots should allow writes")
}

func testCueRecordTempVaultWorkflow() throws {
    let fileManager = FileManager.default
    let vaultURL = fileManager.temporaryDirectory
        .appendingPathComponent("CueRecordTempVaultWorkflow-\(UUID().uuidString)", isDirectory: true)
    let projectURL = vaultURL.appendingPathComponent("Project", isDirectory: true)
    defer { try? fileManager.removeItem(at: vaultURL) }

    try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
    let store = CueRecordProjectStore(projectURL: projectURL)

    let firstURL = store.uniqueMarkdownURL(title: "Script/Intro")
    let firstSnapshot = try store.writeMarkdown("intro", to: firstURL, expectedSnapshot: nil)
    try expect(firstURL.lastPathComponent == "Script-Intro.md", "Temp-vault workflow should sanitize markdown names")

    let secondURL = store.uniqueMarkdownURL(title: "Script/Intro")
    _ = try store.writeMarkdown("second", to: secondURL, expectedSnapshot: nil)
    try expect(secondURL.lastPathComponent == "Script-Intro 2.md", "Temp-vault workflow should allocate duplicate names")

    let manifest = try store.syncManifest(
        markdownURLs: [firstURL, secondURL],
        titles: ["Script Intro", "Script Intro 2"],
        pages: ["intro", "second"],
        selectedURL: secondURL
    )
    try expect(manifest.files.count == 2, "Temp-vault workflow should create two manifest file records")
    try expect(store.selectedMarkdownURL(from: [firstURL, secondURL]) == secondURL, "Temp-vault workflow should persist selected markdown")

    let renamedURL = store.uniqueMarkdownURL(title: "Final Intro", excluding: firstURL)
    try fileManager.moveItem(at: firstURL, to: renamedURL)
    try store.recordMarkdownRename(
        from: firstURL,
        to: renamedURL,
        title: "Final Intro",
        contentHash: CueRecordPathPolicy.contentHash("intro")
    )
    let renamedManifest = try store.syncManifest(
        markdownURLs: [renamedURL, secondURL],
        titles: ["Final Intro", "Script Intro 2"],
        pages: ["intro", "second"],
        selectedURL: secondURL
    )
    try expect(renamedManifest.files.first?.id == manifest.files.first?.id, "Temp-vault workflow should preserve IDs across rename")

    try "external".write(to: renamedURL, atomically: true, encoding: .utf8)
    do {
        _ = try store.writeMarkdown("stale write", to: renamedURL, expectedSnapshot: firstSnapshot)
        throw TestFailure.failed("External changes after rename should make the old snapshot stale")
    } catch is CueRecordFileConflictError {
        try expect(true, "Temp-vault workflow should reject stale snapshots")
    }
}

func testCueRecordVaultRepairer() throws {
    let fileManager = FileManager.default
    let vaultURL = fileManager.temporaryDirectory
        .appendingPathComponent("CueRecordVaultRepairer-\(UUID().uuidString)", isDirectory: true)
    let projectURL = vaultURL.appendingPathComponent("Project", isDirectory: true)
    defer { try? fileManager.removeItem(at: vaultURL) }

    try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
    let store = CueRecordProjectStore(projectURL: projectURL)
    let firstURL = projectURL.appendingPathComponent("First.md")
    let secondURL = projectURL.appendingPathComponent("Second.md")
    try "one".write(to: firstURL, atomically: true, encoding: .utf8)
    try "two".write(to: secondURL, atomically: true, encoding: .utf8)

    let firstReport = try CueRecordVaultRepairer().repairVault(at: vaultURL)
    try expect(firstReport.scannedProjects == 1, "Repair should scan projects with markdown files")
    try expect(firstReport.createdManifests == 1, "Repair should create a missing manifest")
    try expect(store.loadManifest()?.files.count == 2, "Repair should include existing markdown files")

    let missingURL = projectURL.appendingPathComponent("Missing.md")
    try "missing".write(to: missingURL, atomically: true, encoding: .utf8)
    _ = try store.syncManifest(
        markdownURLs: [firstURL, secondURL, missingURL],
        titles: ["First", "Second", "Missing"],
        pages: ["one", "two", ""],
        selectedURL: missingURL
    )
    try fileManager.removeItem(at: missingURL)

    let staleReport = try CueRecordVaultRepairer().repairVault(at: vaultURL)
    try expect(staleReport.repairedManifests == 1, "Repair should update manifests with stale records")
    try expect(staleReport.removedMissingFileRecords == 1, "Repair should report removed stale records")
    try expect(store.loadManifest()?.files.count == 2, "Repair should remove missing markdown records")

    try Data("{ broken json".utf8).write(to: store.manifestURL)
    let corruptReport = try CueRecordVaultRepairer().repairVault(at: vaultURL)
    try expect(corruptReport.repairedManifests == 1, "Repair should replace corrupt manifests")
    try expect(store.loadManifest()?.files.count == 2, "Repair should recover corrupt manifests")
}

func testTeleprompterLineBreakTokenization() throws {
    let words = splitTextIntoWords("先讲开头|再讲重点｜最后\n收尾")
    let breakCount = words.filter(TeleprompterLineBreak.isBreakToken).count
    let markerBreakCount = words.filter(TeleprompterLineBreak.isMarkerBreakToken).count
    let newlineBreakCount = words.filter { $0 == TeleprompterLineBreak.newlineToken }.count

    try expect(breakCount == 3, "Pipe, full-width pipe, and newline should become teleprompter breaks")
    try expect(markerBreakCount == 2, "Pipe and full-width pipe should become marked breath breaks")
    try expect(newlineBreakCount == 1, "Newlines should remain ordinary line breaks")
    try expect(!words.contains("|"), "ASCII pipe should not be displayed as a word")
    try expect(!words.contains("｜"), "Full-width pipe should not be displayed as a word")
    try expect(words.first == "先", "CJK words should still split into display characters")
    try expect(words.last == "尾", "Trailing text should be preserved after line breaks")
}

func testTeleprompterLineBreakDeduplication() throws {
    let words = splitTextIntoWords("hello||｜\nworld")

    try expect(
        words == ["hello", TeleprompterLineBreak.markerToken, "world"],
        "Consecutive explicit breaks should collapse to one marked visual break"
    )
}

func testTeleprompterPaceCueTokenization() throws {
    let words = splitTextIntoWords("›› 快速带过｜--关键概念\n正常")

    try expect(words.contains(TeleprompterPaceCue.fastToken), "Fast cue should become an internal token")
    try expect(words.contains(TeleprompterPaceCue.slowToken), "Slow cue should become an internal token")
    try expect(words.contains(TeleprompterLineBreak.markerToken), "Breath marker should remain a marked line break")
    try expect(words.contains(TeleprompterLineBreak.newlineToken), "Newline should remain an ordinary line break")
    try expect(!words.contains("››"), "Fast cue marker should not be displayed as a word")
    try expect(!words.contains("--"), "Slow cue marker should not be displayed as a word")
    try expect(Array(words.suffix(2)) == ["正", "常"], "Text after pace cues should be preserved")
}

func testTeleprompterLegacySlowCueTokenization() throws {
    let words = splitTextIntoWords("--(慢)旧稿兼容")

    try expect(words.first == TeleprompterPaceCue.slowToken, "Legacy slow cue should still become an internal token")
    try expect(!words.contains("--(慢)"), "Legacy slow cue marker should not be displayed as a word")
}

func testSpeechTrackingThreeWordAnchorCrossesLineBreaks() throws {
    let words = splitTextIntoWords("alpha beta\ngamma\ndelta epsilon")
    let sourceText = words.joined(separator: " ")
    let match = SpeechTrackingMatcher.immediateThreeWordAnchor(in: sourceText, spoken: "beta gamma delta")

    guard let match else {
        throw TestFailure.failed("Three consecutive spoken words should anchor across line breaks")
    }

    guard let deltaRange = sourceText.range(of: "delta") else {
        throw TestFailure.failed("Fixture should contain delta")
    }

    let expectedEndOffset = sourceText.distance(from: sourceText.startIndex, to: deltaRange.upperBound)
    try expect(match.matchedWordCount == 3, "Anchor should require and report three matched words")
    try expect(match.endOffset == expectedEndOffset, "Anchor should advance through the third matched word")
}

func testSpeechTrackingThreeCJKAnchorCrossesBreakTokens() throws {
    let words = splitTextIntoWords("甲|乙\n丙丁")
    let sourceText = words.joined(separator: " ")
    let match = SpeechTrackingMatcher.immediateThreeWordAnchor(in: sourceText, spoken: "甲乙丙")

    guard let match else {
        throw TestFailure.failed("Three consecutive CJK tokens should anchor across break tokens")
    }

    guard let thirdRange = sourceText.range(of: "丙") else {
        throw TestFailure.failed("Fixture should contain the third CJK token")
    }

    let expectedEndOffset = sourceText.distance(from: sourceText.startIndex, to: thirdRange.upperBound)
    try expect(match.matchedWordCount == 3, "CJK anchor should report three matched tokens")
    try expect(match.endOffset == expectedEndOffset, "CJK anchor should preserve source offsets across breaks")
}

func testRecordingEditorPresentation() throws {
    let firstTake = URL(fileURLWithPath: "/tmp/project/Untitled Project - lesson 1/WindowRecord.mov")
    let secondTake = URL(fileURLWithPath: "/tmp/project/Untitled Project - lesson 2/WindowRecord.mov")

    try expect(
        RecordingEditorPresentation.shouldPresent(currentTakeURL: nil, for: firstTake),
        "A take must get an editor when no editor is open"
    )
    try expect(
        !RecordingEditorPresentation.shouldPresent(currentTakeURL: firstTake, for: firstTake),
        "The take whose editor is already open must not reopen the window"
    )
    try expect(
        RecordingEditorPresentation.shouldPresent(currentTakeURL: firstTake, for: secondTake),
        "A new take must get its own editor even while a stale editor stays open"
    )

    let samePathWrittenDifferently = firstTake
        .deletingLastPathComponent()
        .appendingPathComponent("./WindowRecord.mov")
    try expect(
        !RecordingEditorPresentation.shouldPresent(currentTakeURL: firstTake, for: samePathWrittenDifferently),
        "Equivalent paths must compare as the same take"
    )
}


func testAIVoiceCommandParsing() throws {
    // 规则层：中文口令
    try expect(AIVoiceAssistant.ruleDecision(for: "下一页", pageCount: 5)?.action == .nextPage,
               "「下一页」应识别为翻页")
    try expect(AIVoiceAssistant.ruleDecision(for: "翻页吧", pageCount: 5)?.action == .nextPage,
               "「翻页吧」应识别为翻页")
    try expect(AIVoiceAssistant.ruleDecision(for: "上一页", pageCount: 5)?.action == .previousPage,
               "「上一页」应识别为回退一页")
    try expect(AIVoiceAssistant.ruleDecision(for: "暂停一下", pageCount: 5)?.action == .pauseScroll,
               "「暂停一下」应识别为暂停")
    try expect(AIVoiceAssistant.ruleDecision(for: "继续", pageCount: 5)?.action == .resumeScroll,
               "「继续」应识别为继续")
    try expect(AIVoiceDecision(action: .finishRecording, confidence: 0.9, origin: .rule, utterance: "结束录制")
               == AIVoiceAssistant.ruleDecision(for: "结束录制", pageCount: 5),
               "「结束录制」应识别为结束")

    // 页码口令
    try expect(AIVoiceAssistant.ruleDecision(for: "第 3 页", pageCount: 5)?.action == .jumpPage(2),
               "「第 3 页」应跳到第 2 个索引")
    try expect(AIVoiceAssistant.ruleDecision(for: "跳到第9页", pageCount: 5)?.action == .jumpPage(4),
               "超出总页数时应收敛到最后一页")
    try expect(AIVoiceAssistant.ruleDecision(for: "第一页", pageCount: 5)?.action == .jumpPage(0),
               "「第一页」应跳到开头")

    // 普通讲稿句子不该被当成口令
    try expect(AIVoiceAssistant.ruleDecision(for: "今天我们讲一下工作流的基本结构", pageCount: 5) == nil,
               "正文不得被识别成口令")
    try expect(AIVoiceAssistant.isCommandCandidate("今天我们讲一下工作流的基本结构") == false,
               "长句不是口令候选")
    try expect(AIVoiceAssistant.isCommandCandidate("下一页") == true,
               "短句是口令候选")

    // 模型层 JSON 解析
    let raw = "```json\n{\"action\":\"jump_page\",\"page\":4,\"confidence\":0.82}\n```"
    try expect(AIVoiceAssistant.parse(raw, utterance: "去第四页", pageCount: 6)?.action == .jumpPage(3),
               "模型返回的 jump_page 应转成索引")
    try expect(AIVoiceAssistant.parse("{\"action\":\"next_page\",\"confidence\":0.7}",
                                      utterance: "下一张", pageCount: 6)?.action == .nextPage,
               "模型返回 next_page 应生效")
    try expect(AIVoiceAssistant.parse("完全不是 JSON", utterance: "嗯", pageCount: 6) == nil,
               "非 JSON 响应应返回空")
    try expect(AIVoiceAssistant.parse("{\"action\":\"next_page\",\"confidence\":0.1}",
                                      utterance: "嗯", pageCount: 6) == nil,
               "低置信度应丢弃")
}


func testLocalizationDictionaryHasNoDuplicateKeys() throws {
    // 词条表是字典字面量：重复 key 不会编译报错，但运行时会 trap（曾导致启动即崩）
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = repoRoot.appendingPathComponent("CueRecord/InterfaceLanguage.swift")
    let text = try String(contentsOf: source, encoding: .utf8)

    guard let start = text.range(of: "private static let zhHans: [String: String] = ["),
          let end = text.range(of: "\n    ]", range: start.upperBound..<text.endIndex)
    else {
        throw TestFailure.failed("找不到 zhHans 词条表")
    }
    let block = text[start.upperBound..<end.lowerBound]

    var seen = Set<String>()
    var duplicates: [String] = []
    for line in block.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\""), let colon = trimmed.firstIndex(of: ":") else { continue }
        let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<colon])
        if !seen.insert(key).inserted {
            duplicates.append(key)
        }
    }
    try expect(duplicates.isEmpty, "词条表里有重复 key：\(duplicates.joined(separator: ", "))")
}


func testExportCropTo16x9() throws {
    let fullScreen = CGSize(width: 2940, height: 1912)   // 实测：14 寸 MacBook 整屏 2x
    let cropped = RecordingExportSettings(resolutionPreset: .p1080, bitRatePreset: .medium, cropTo16x9: true)
    try expect(cropped.outputSize(for: fullScreen) == CGSize(width: 1920, height: 1080),
               "16:9 裁切后应为 1920 x 1080")

    let portraitSource = CGSize(width: 1080, height: 1920)
    try expect(cropped.outputSize(for: portraitSource) == CGSize(width: 1080, height: 608),
               "竖屏源裁成 16:9 时以长边为准")

    let uncropped = RecordingExportSettings(resolutionPreset: .p1080, bitRatePreset: .medium, cropTo16x9: false)
    try expect(uncropped.outputSize(for: fullScreen) == CGSize(width: 1920, height: 1248),
               "不裁切时保持原始比例")
}

func testRecordingPreflight() throws {
    try expect(RecordingPreflight.freeSpaceIssue(availableBytes: nil, minimumBytes: 5 << 30) == nil,
               "读不出磁盘余量时应放行，不误伤")
    try expect(RecordingPreflight.freeSpaceIssue(availableBytes: 1 << 30, minimumBytes: 5 << 30) != nil,
               "余量 1GB / 门槛 5GB 应拒绝开录")
    try expect(RecordingPreflight.freeSpaceIssue(availableBytes: 20 << 30, minimumBytes: 5 << 30) == nil,
               "余量 20GB 应放行")

    let damaged = RecordingOutputValidation(
        health: .damaged, issues: ["Output has no video track"], fileSize: 1000, durationSeconds: 0
    )
    try expect(RecordingPreflight.exportBlockReason(for: damaged) != nil,
               "屏幕轨 damaged 时必须阻止导出")
    let healthy = RecordingOutputValidation(
        health: .healthy, issues: [], fileSize: 1000, durationSeconds: 10
    )
    try expect(RecordingPreflight.exportBlockReason(for: healthy) == nil,
               "healthy 应放行")
    let degraded = RecordingOutputValidation(
        health: .degraded, issues: ["Output duration is short: 0.30s"], fileSize: 1000, durationSeconds: 0.3
    )
    try expect(RecordingPreflight.exportBlockReason(for: degraded) == nil,
               "degraded 但可解码时应放行")

    try expect((RecordingPreflight.availableCapacity(on: URL(fileURLWithPath: NSHomeDirectory())) ?? 0) > 0,
               "家目录应能读到正的剩余空间")
}

func testUnfinishedRecordingStore() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("unfinished-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let storeURL = tempDir.appendingPathComponent("unfinished-recordings.json")

    let first = UnfinishedRecordingEntry(id: "A.mov", outputURLPath: "/nonexistent/A.mov", state: "recording")
    UnfinishedRecordingStore.upsert(first, to: storeURL)
    try expect(UnfinishedRecordingStore.load(from: storeURL).count == 1, "开录登记后应有 1 条")

    var paused = first
    paused.state = "paused"
    UnfinishedRecordingStore.upsert(paused, to: storeURL)
    let reloaded = UnfinishedRecordingStore.load(from: storeURL)
    try expect(reloaded.count == 1 && reloaded.first?.state == "paused", "upsert 应按 id 去重并更新状态")

    let existingURL = tempDir.appendingPathComponent("B.mov")
    try Data("x".utf8).write(to: existingURL)
    UnfinishedRecordingStore.upsert(
        UnfinishedRecordingEntry(id: "B.mov", outputURLPath: existingURL.path, state: "recording"),
        to: storeURL
    )
    let gone = UnfinishedRecordingStore.entryIDsWithoutOutput(UnfinishedRecordingStore.load(from: storeURL))
    try expect(gone == ["A.mov"], "只有文件不存在的条目才应被判为可清理")

    UnfinishedRecordingStore.removeEntries(ids: gone, from: storeURL)
    try expect(UnfinishedRecordingStore.load(from: storeURL).map(\.id) == ["B.mov"], "清理后只剩文件仍在的条目")

    UnfinishedRecordingStore.remove(id: "B.mov", from: storeURL)
    try expect(UnfinishedRecordingStore.load(from: storeURL).isEmpty, "停录后清单应清空")
}

func testRecordingMarkerStore() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("markers-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let outputURL = tempDir.appendingPathComponent("ScreenRecord_test.mov")
    let storeURL = RecordingMarkerStore.markersURL(for: outputURL)
    try expect(storeURL.lastPathComponent == "ScreenRecord_test_markers.json",
               "标记侧车应命名为 <base>_markers.json")

    RecordingMarkerStore.append(elapsedSeconds: 3.5, to: storeURL)
    RecordingMarkerStore.append(elapsedSeconds: 9.0, to: storeURL)
    let loaded = RecordingMarkerStore.load(from: storeURL)
    try expect(loaded.count == 2 && loaded[0].index == 0 && loaded[1].index == 1,
               "追加两条后应按序号加载")
    try expect(abs(loaded[1].elapsedSeconds - 9.0) < 0.001,
               "标记时间点应原样保留")
}

func testRecordingTranscriptRecorder() throws {
    var accumulator = RecordingTranscriptAccumulator()

    // 分段一：文本在段内演化，endpoint 定稿
    accumulator.ingestUpdate("打开", at: 1.0)
    accumulator.ingestUpdate("打开浏览器", at: 2.5)
    accumulator.closeSegment(at: 3.2)
    // 分段二：停录时未触发 endpoint，也应定稿保留
    accumulator.ingestUpdate("点击下载", at: 5.0)
    accumulator.ingestUpdate("点击下载按钮", at: 6.4)
    accumulator.closeSegment(at: 6.4)

    try expect(accumulator.segments.count == 2, "应得到两个分段")
    try expect(abs(accumulator.segments[0].start - 1.0) < 0.001
        && abs(accumulator.segments[0].end - 3.2) < 0.001, "首段时间点应取首见/定稿时刻")
    try expect(accumulator.segments[0].text == "打开浏览器", "文本取演化后的最终值")
    try expect(abs(accumulator.segments[1].end - 6.4) < 0.001, "未触发 endpoint 的段在停录时定稿")

    // 空段不应产生记录
    accumulator.closeSegment(at: 7.0)
    try expect(accumulator.segments.count == 2, "空文本分段不应落盘")

    let srt = TranscriptSRTSerializer.srtText(from: accumulator.segments)
    try expect(srt.contains("1\n00:00:01,000 --> 00:00:03,200\n打开浏览器"), "SRT 首块应格式正确")
    try expect(srt.contains("2\n00:00:05,000 --> 00:00:06,400\n点击下载按钮"), "SRT 次块应格式正确")
    try expect(TranscriptSRTSerializer.srtText(from: []) == "", "空分段不应输出 SRT")
    try expect(TranscriptSRTSerializer.timestamp(3661.5) == "01:01:01,500", "小时位应正确进位")

    let outputURL = URL(fileURLWithPath: "/tmp/ScreenRecord_x.mov")
    try expect(TranscriptSRTSerializer.transcriptURL(for: outputURL).lastPathComponent == "ScreenRecord_x_transcript.json",
               "转写侧车命名应为 <base>_transcript.json")
    try expect(TranscriptSRTSerializer.srtURL(for: outputURL).lastPathComponent == "ScreenRecord_x.srt",
               "SRT 应与视频同名")
}

func testCursorEventTrackGeometryAndThrottle() throws {
    let rect = CGRect(x: 100, y: 100, width: 800, height: 600)

    let topLeft = CursorGeometry.normalizedPoint(globalX: 100, globalY: 700, in: rect)
    try expect(topLeft != nil && abs(topLeft!.x) < 0.001 && abs(topLeft!.y) < 0.001,
               "全局坐标画面左上角应映射为归一化 (0,0)（含 Y 翻转）")
    let center = CursorGeometry.normalizedPoint(globalX: 500, globalY: 400, in: rect)
    try expect(center != nil && abs(center!.x - 0.5) < 0.001 && abs(center!.y - 0.5) < 0.001,
               "画面中心应映射为 (0.5,0.5)")
    try expect(CursorGeometry.normalizedPoint(globalX: 5000, globalY: 400, in: rect) == nil,
               "远超录制矩形的点应丢弃")

    try expect(CursorGeometry.shouldRecordMove(lastSample: nil, t: 0, x: 0, y: 0),
               "首个移动样本必须记录")
    let last = CursorEventSample(t: 1.0, x: 0.1, y: 0.1)
    try expect(!CursorGeometry.shouldRecordMove(lastSample: last, t: 1.01, x: 0.5, y: 0.5),
               "间隔不足应跳过（暂停期间时间冻结，自然停采）")
    try expect(!CursorGeometry.shouldRecordMove(lastSample: last, t: 1.5, x: 0.1001, y: 0.1),
               "时间够但几乎没动应跳过")
    try expect(CursorGeometry.shouldRecordMove(lastSample: last, t: 1.5, x: 0.2, y: 0.1),
               "时间够且确有位移应记录")

    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cursor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let outputURL = tempDir.appendingPathComponent("WindowRecord_test.mov")
    let track = CursorEventTrack(
        recordingRect: CursorEventRect(rect),
        events: [CursorEventSample(t: 1, x: 0.2, y: 0.3, c: 1)]
    )
    CursorEventStore.save(track, for: outputURL)
    try expect(CursorEventStore.load(from: CursorEventStore.cursorURL(for: outputURL)) == track,
               "光标轨应可完整往返")
    try expect(CursorEventStore.cursorURL(for: outputURL).lastPathComponent == "WindowRecord_test_cursor.json",
               "光标侧车命名应为 <base>_cursor.json")

    let emptyOutput = tempDir.appendingPathComponent("Empty.mov")
    CursorEventStore.save(CursorEventTrack(events: []), for: emptyOutput)
    try expect(!FileManager.default.fileExists(atPath: CursorEventStore.cursorURL(for: emptyOutput).path),
               "没有事件时不应产生侧车文件")
}

func testCursorSamplerInterpolation() throws {
    var sampler = CursorEventSampler(samples: [
        CursorEventSample(t: 0, x: 0.1, y: 0.1),
        CursorEventSample(t: 1, x: 0.3, y: 0.5),
        CursorEventSample(t: 2, x: 0.5, y: 0.5, c: 1)
    ])
    try expect(sampler.position(at: -1).map { abs($0.x - 0.1) < 1e-9 } == true,
               "早于首样本应取首样本位置")
    try expect(sampler.position(at: 0.5).map { abs($0.x - 0.2) < 1e-9 && abs($0.y - 0.3) < 1e-9 } == true,
               "样本中点应线性插值")
    try expect(sampler.position(at: 5).map { abs($0.x - 0.5) < 1e-9 } == true,
               "晚于末样本应取末样本位置")
    try expect(sampler.activeRipple(at: 2.2) != nil, "点击后 0.2s 内应有波纹")
    try expect(sampler.activeRipple(at: 2.5) == nil, "点击后 0.5s 波纹应已结束")
    try expect(sampler.activeRipple(at: 1.9) == nil, "点击发生前不应有波纹")
}

func testCursorRendererAssets() throws {
    try expect(CursorRenderer.arrowCGImage() != nil, "箭头位图应可生成")
    try expect(CursorRenderer.rippleCGImage() != nil, "波纹位图应可生成")

    let rect = CursorRenderer.contentRect(
        sourceExtent: CGRect(x: 0, y: 0, width: 2940, height: 1912),
        in: CGRect(x: 0, y: 0, width: 1920, height: 1248)
    )
    try expect(abs(rect.width - 1920) < 2 && abs(rect.height - 1248) < 2,
               "同比例画面内容矩形应铺满输出区（预设分辨率取整允许 2px 内偏差）")
    let point = CursorRenderer.contentPoint(x: 0, y: 0, in: rect)
    try expect(abs(point.x - rect.minX) < 0.5 && abs(point.y - rect.maxY) < 0.5,
               "归一化 (0,0) 应映射到内容矩形左上角（CI 左下原点坐标）")
}

func testZoomTimelineEasingAndCrop() throws {
    let range = ZoomRange(startSeconds: 2, endSeconds: 6, centerX: 0.5, centerY: 0.5, zoomScale: 2.0, easingSeconds: 0.4)
    try expect(ZoomTimeline.zoomFactor(at: 1.9, range: range) == 1, "区间开始前不缩放")
    try expect(ZoomTimeline.zoomFactor(at: 4.0, range: range) == 2, "区间平台期应为满倍率")
    try expect(ZoomTimeline.zoomFactor(at: 6.1, range: range) == 1, "区间结束后不缩放")
    try expect(ZoomTimeline.zoomFactor(at: 2.2, range: range) > 1
        && ZoomTimeline.zoomFactor(at: 2.2, range: range) < 2, "进入缓动期倍率应在 1 与满倍率之间")
    try expect(ZoomTimeline.zoomFactor(at: 5.8, range: range) > 1
        && ZoomTimeline.zoomFactor(at: 5.8, range: range) < 2, "退出缓动期倍率应在 1 与满倍率之间")

    try expect(ZoomTimeline.activeCrop(at: 4, ranges: [range]) != nil, "区间内应有裁切")
    try expect(ZoomTimeline.activeCrop(at: 1, ranges: [range]) == nil, "区间外应无裁切")

    let corner = ZoomRange(startSeconds: 0, endSeconds: 5, centerX: 0.02, centerY: 0.02, zoomScale: 2.0, easingSeconds: 0.3)
    guard let crop = ZoomTimeline.activeCrop(at: 2.5, ranges: [corner]) else {
        throw TestFailure.failed("角落聚焦应产生裁切")
    }
    try expect(crop.x >= -1e-9 && crop.y >= -1e-9
        && crop.x + crop.w <= 1 + 1e-9 && crop.y + crop.h <= 1 + 1e-9,
               "角落聚焦的裁切矩形必须被钳制在画面内")
    try expect(abs(crop.x) < 1e-9 && abs(crop.y) < 1e-9, "左上角聚焦应贴住左上角")

    let half: NormalizedCrop = (x: 0.25, y: 0.25, w: 0.5, h: 0.5)
    let inside = ZoomTimeline.mapPointThroughCrop(x: 0.5, y: 0.5, crop: half)
    try expect(inside != nil && abs(inside!.x - 0.5) < 1e-9 && abs(inside!.y - 0.5) < 1e-9,
               "裁切中心点映射后应仍在中心")
    try expect(ZoomTimeline.mapPointThroughCrop(x: 0.1, y: 0.5, crop: half) == nil,
               "裁切外远处的点应判为不可见")
}

func testZoomHeuristicFromClicks() throws {
    try expect(ZoomHeuristic.ranges(from: [CursorEventSample(t: 1, x: 0.5, y: 0.5)]).isEmpty,
               "没有点击不应生成区间")

    let single = ZoomHeuristic.ranges(from: [
        CursorEventSample(t: 1.0, x: 0.3, y: 0.3),
        CursorEventSample(t: 2.0, x: 0.3, y: 0.3, c: 1),
        CursorEventSample(t: 3.0, x: 0.3, y: 0.3)
    ])
    try expect(single.count == 1, "单次点击应生成一个区间")
    if let r = single.first {
        // 点击样本把时间沟切成两段(各 1s)，不足以判定停留，区间就是纯点击区间
        try expect(abs(r.startSeconds - 1.55) < 1e-9, "区间应在点击前 0.45s 开始（实测先导）")
        try expect(abs(r.endSeconds - 3.5) < 1e-9, "区间应在点击后 1.5s 结束（实测保持 1500ms）")
        try expect(abs(r.centerX - 0.3) < 1e-9, "聚焦横坐标应为点击位置")
        try expect(abs(r.centerY - 0.273) < 1e-9, "聚焦中心应向上偏移 2.7%（实测规律）")
        try expect(r.zoomScale == 1.6, "点击倍率应取实测克制值 1.6")
    }

    let burst = ZoomHeuristic.ranges(from: [
        CursorEventSample(t: 1.0, x: 0.4, y: 0.4, c: 1),
        CursorEventSample(t: 1.3, x: 0.41, y: 0.4, c: 1),
        CursorEventSample(t: 1.6, x: 0.4, y: 0.41, c: 1)
    ])
    try expect(burst.count == 1, "近距离连点应合并为一个区间")

    let two = ZoomHeuristic.ranges(from: [
        CursorEventSample(t: 1.0, x: 0.2, y: 0.2, c: 1),
        CursorEventSample(t: 10.0, x: 0.8, y: 0.8, c: 1)
    ])
    try expect(two.count == 2, "远距离两次点击应各自成区间")
}

func testZoomHeuristicDwell() throws {
    // 停在 (0.4,0.4) 约 3.2s 后移走 → 温和缩放区间
    let dwell = ZoomHeuristic.ranges(from: [
        CursorEventSample(t: 1.0, x: 0.4, y: 0.4),
        CursorEventSample(t: 4.2, x: 0.42, y: 0.4),
        CursorEventSample(t: 4.3, x: 0.7, y: 0.7)
    ], totalDuration: 6.0)
    try expect(dwell.count == 1, "悬停停留应生成一个缩放区间")
    if let r = dwell.first {
        let engage = min(0.6, 1.8 * 0.3)
        try expect(abs(r.startSeconds - (1.0 + engage)) < 1e-9, "停留后应延迟进入（喘气不算阅读）")
        try expect(abs(r.endSeconds - 5.0) < 1e-9, "移开后保持 0.8s 再退出")
        try expect(r.zoomScale == 1.4, "停留应使用温和倍率")
    }

    // 时间沟两端位移过大 → 不是停留，是光标去了别处（中间没有采样是异常数据）
    let moved = ZoomHeuristic.ranges(from: [
        CursorEventSample(t: 1.0, x: 0.2, y: 0.2),
        CursorEventSample(t: 4.0, x: 0.9, y: 0.9)
    ], totalDuration: 4.2)
    try expect(moved.isEmpty, "大位移的时间沟不应判为停留")

    // 尾部静默：讲完停住到结束 → 停留区间，终点钳到片长
    let trailing = ZoomHeuristic.ranges(from: [
        CursorEventSample(t: 0.5, x: 0.6, y: 0.6),
        CursorEventSample(t: 0.7, x: 0.62, y: 0.6)
    ], totalDuration: 4.0)
    try expect(trailing.count == 1, "尾部静默也是停留")
    if let r = trailing.first {
        try expect(r.endSeconds <= 4.0 + 1e-9, "区间终点必须钳在片长内")
    }

    // 前导静默：开录 3s 没动鼠标 → 从头停留
    let leading = ZoomHeuristic.ranges(from: [
        CursorEventSample(t: 3.0, x: 0.3, y: 0.3)
    ], totalDuration: 4.0)
    try expect(leading.count == 1, "开录静止也是停留")

    // 持续移动 + 最后把指针搁在屏幕边缘（闲置）→ 无区间
    let busy = ZoomHeuristic.ranges(from: [
        CursorEventSample(t: 0.0, x: 0.1, y: 0.1),
        CursorEventSample(t: 0.2, x: 0.3, y: 0.1),
        CursorEventSample(t: 0.4, x: 0.01, y: 0.5)
    ], totalDuration: 5.0)
    try expect(busy.isEmpty, "持续移动 + 指针搁在边缘闲置，不应缩放")

    // 点击后原地继续停留 → 区间并到停留结束，倍率取点击（操作强于阅读）
    let clickThenDwell = ZoomHeuristic.ranges(from: [
        CursorEventSample(t: 1.0, x: 0.4, y: 0.4),
        CursorEventSample(t: 2.5, x: 0.4, y: 0.4, c: 1),
        CursorEventSample(t: 5.0, x: 0.41, y: 0.4)
    ], totalDuration: 6.0)
    try expect(clickThenDwell.count == 1, "点击与其后停留应合并为一个区间")
    if let r = clickThenDwell.first {
        // 点击区间 [2.05, 4.0] × 停留区间 [3.04, 5.8] → 合并
        try expect(abs(r.startSeconds - 2.05) < 1e-9, "合并后应从点击先导开始")
        try expect(abs(r.endSeconds - 5.8) < 1e-9, "合并后应到停留保持结束")
        try expect(r.zoomScale == 1.6, "重叠时点击倍率优先")
        try expect(abs(r.centerX - 0.40125) < 1e-9, "中心按点击 3 / 停留 1 加权")
    }
}

func testZoomRangeStoreRoundTrip() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("zoom-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let outputURL = tempDir.appendingPathComponent("ScreenRecord_z.mov")
    let file = ZoomRangeFile(ranges: [ZoomRange(startSeconds: 0, endSeconds: 3, centerX: 0.5, centerY: 0.5)])
    ZoomRangeStore.save(file, for: outputURL)
    try expect(ZoomRangeStore.load(from: ZoomRangeStore.zoomURL(for: outputURL)) == file,
               "缩放区间应可完整往返")
    try expect(ZoomRangeStore.zoomURL(for: outputURL).lastPathComponent == "ScreenRecord_z_zoom.json",
               "缩放侧车命名应为 <base>_zoom.json")

    let emptyOutput = tempDir.appendingPathComponent("EmptyZoom.mov")
    ZoomRangeStore.save(ZoomRangeFile(ranges: []), for: emptyOutput)
    try expect(!FileManager.default.fileExists(atPath: ZoomRangeStore.zoomURL(for: emptyOutput).path),
               "没有区间时不应产生侧车文件")
}

/// 像素级验证：自绘光标真的会画到帧上，且缩放裁切外的光标不画。
/// 走的正是导出渲染用的 CIImage 合成路径。
func testCursorPixelRendering() throws {
    // 画布要够大：光标高度按内容高度的比例(5.2%)绘制，64px 画布上箭头只有 3px。
    let size = 512
    guard let baseContext = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let baseImage = {
        baseContext.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        baseContext.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return baseContext.makeImage()
    }() else {
        throw TestFailure.failed("黑底测试画面生成失败")
    }

    guard let arrow = CursorRenderer.arrowCGImage(), let ripple = CursorRenderer.rippleCGImage() else {
        throw TestFailure.failed("箭头/波纹位图生成失败")
    }

    func brightPixelCount(of image: CIImage) -> Int {
        let context = CIContext()
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        context.render(
            image,
            toBitmap: &pixels,
            rowBytes: size * 4,
            bounds: CGRect(x: 0, y: 0, width: size, height: size),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        var bright = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset] > 200 {
            bright += 1
        }
        return bright
    }

    let base = CIImage(cgImage: baseImage)
    let cursorCI = CIImage(cgImage: arrow)
    let rippleCI = CIImage(cgImage: ripple)
    let contentRect = CGRect(x: 0, y: 0, width: size, height: size)

    var sampler = CursorEventSampler(samples: [
        CursorEventSample(t: 0, x: 0.5, y: 0.5),
        CursorEventSample(t: 1, x: 0.5, y: 0.5, c: 1)
    ])
    let withCursor = CursorRenderer.applyCursor(
        to: base, sampler: &sampler, at: 0.6, contentRect: contentRect,
        cursorCI: cursorCI, rippleCI: rippleCI
    )
    try expect(brightPixelCount(of: withCursor) > 30,
               "自绘箭头 + 波纹应把亮像素画上画面")

    var farSampler = CursorEventSampler(samples: [CursorEventSample(t: 0, x: 0.9, y: 0.9)])
    let croppedOut = CursorRenderer.applyCursor(
        to: base, sampler: &farSampler, at: 0, contentRect: contentRect,
        cursorCI: cursorCI, rippleCI: rippleCI,
        crop: (x: 0, y: 0, w: 0.5, h: 0.5)
    )
    try expect(brightPixelCount(of: croppedOut) == 0,
               "光标落在缩放裁切外时不应绘制")
}

func testIdleSpanDetection() throws {
    let transcript: [TranscriptSegment] = [
        TranscriptSegment(start: 2.0, end: 4.0, text: "大家好"),
        TranscriptSegment(start: 6.0, end: 9.0, text: "看这个按钮"),
        TranscriptSegment(start: 12.0, end: 14.0, text: "总结一下")
    ]
    let cursor: [CursorEventSample] = [
        CursorEventSample(t: 2.5, x: 0.3, y: 0.3),
        CursorEventSample(t: 6.5, x: 0.4, y: 0.4, c: 1),
        CursorEventSample(t: 12.5, x: 0.5, y: 0.5)
    ]

    let result = RecordingIdleSpanDetector.detect(
        totalDuration: 15.0, transcript: transcript, cursorEvents: cursor
    )

    try expect(result.suggestedTrimStart == 1.5, "应建议裁掉开录头 1.5s")

    try expect(result.suggestions.count == 2, "应检出两段闲段（实际 \(result.suggestions.count)）")
    if result.suggestions.count == 2 {
        let sorted = result.suggestions.sorted { $0.span.start < $1.span.start }
        try expect(abs(sorted[0].span.start - 4.25) < 0.01 && abs(sorted[0].span.end - 5.75) < 0.01,
                   "第一段闲段应取说话段间的空隙（含保护边）")
        try expect(sorted[0].action == "speed", "约 1.5s 的段应建议加速而不是剪")
        try expect(abs(sorted[1].span.start - 9.25) < 0.01 && abs(sorted[1].span.end - 11.75) < 0.01,
                   "第二段闲段应正确")
        try expect(sorted[1].action == "cut", "≥2.5s 的段应建议剪掉")
    }

    // 没有转写 → 宁缺毋滥，不给闲段建议
    let noTranscript = RecordingIdleSpanDetector.detect(
        totalDuration: 15.0, transcript: [], cursorEvents: cursor
    )
    try expect(noTranscript.suggestions.isEmpty, "转写缺失时不应给闲段建议")
    try expect(noTranscript.suggestedTrimStart == 1.5, "开头裁剪建议仍应给出")

    // 侧车往返
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("idle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let outputURL = tempDir.appendingPathComponent("ScreenRecord_i.mov")
    IdleSpanStore.save(result, for: outputURL)
    try expect(IdleSpanStore.load(from: IdleSpanStore.idleURL(for: outputURL)) == result,
               "闲段建议应可完整往返")
    try expect(IdleSpanStore.idleURL(for: outputURL).lastPathComponent == "ScreenRecord_i_idle.json",
               "闲段侧车命名应为 <base>_idle.json")
}

func testAgentEditPromptAndApplier() throws {
    let context = AgentEditContext(
        outputFileName: "ScreenRecord_test.mov",
        durationSeconds: 42.5,
        resolution: "2940 × 1912",
        hasCameraTrack: false,
        markers: [RecordingMarker(index: 0, elapsedSeconds: 12.3, createdAt: Date(timeIntervalSince1970: 0))],
        transcript: [TranscriptSegment(start: 2, end: 5, text: "大家好")],
        idleSuggestions: IdleSpanFile(
            version: 1,
            suggestedTrimStart: 1.5,
            suggestions: [IdleSuggestion(span: IdleSpan(start: 9.25, end: 11.75), action: "cut", speed: 3)],
            hint: ""
        ),
        zoomRanges: [ZoomRange(startSeconds: 2, endSeconds: 5, centerX: 0.3, centerY: 0.3)]
    )
    let prompt = AgentEditPromptBuilder.prompt(for: context)
    try expect(prompt.contains("大家好"), "提示词应包含转写内容")
    try expect(prompt.contains("标记 1"), "提示词应包含讲师标记")
    try expect(prompt.contains("建议剪掉"), "提示词应包含闲段建议")
    try expect(prompt.contains("edits.json 规范"), "提示词应自带操作规范")
    try expect(prompt.contains("zoomMode"), "规范应说明 zoomMode")

    let specJSON = """
    {"cuts":[{"startTime":1.5,"endTime":42.5}],"zoom":[{"startSeconds":4,"endSeconds":8,"centerX":0.4,"centerY":0.4,"zoomScale":1.6,"easingSeconds":0.38}],"zoomMode":"replace","export":{"resolution":"p1080","cropTo16x9":true}}
    """
    let spec = try JSONDecoder().decode(AgentEditSpec.self, from: Data(specJSON.utf8))
    let existing = [ZoomRange(startSeconds: 2, endSeconds: 5, centerX: 0.3, centerY: 0.3)]

    let application = try AgentEditApplier.apply(spec, existingZoomRanges: existing)
    try expect(application.editDecision.cuts.count == 1
        && abs(application.editDecision.cuts[0].startTime - 1.5) < 1e-9, "cuts 应映射到剪辑决策")
    try expect(application.zoomRanges.count == 1 && application.zoomRanges[0].startSeconds == 4,
               "replace 模式应覆盖自动区间")
    try expect(application.exportSettings.cropTo16x9 == true, "导出设置应映射")

    var mergeSpec = spec
    mergeSpec.zoomMode = "merge"
    let merged = try AgentEditApplier.apply(mergeSpec, existingZoomRanges: existing)
    try expect(merged.zoomRanges.count == 2, "merge 模式应合并自动区间与 AI 区间")

    var noZoomSpec = spec
    noZoomSpec.zoom = nil
    noZoomSpec.zoomMode = nil
    let kept = try AgentEditApplier.apply(noZoomSpec, existingZoomRanges: existing)
    try expect(kept.zoomRanges.count == 1, "AI 未提运镜时应保留自动区间")

    var bad = spec
    bad.cuts = []
    do {
        _ = try AgentEditApplier.apply(bad)
        try expect(false, "空 cuts 应报错")
    } catch {}
}

func testPlatformPresetCanvasSizes() throws {
    let source = CGSize(width: 2940, height: 1912)

    // 发布画幅的画布尺寸（1080p）
    var vertical = RecordingExportSettings.default
    vertical.canvasAspect = .vertical9x16
    let verticalSize = vertical.canvasSize(for: source)
    try expect(verticalSize == CGSize(width: 1080, height: 1920),
               "1080p 竖屏画布应为 1080×1920（实际 \(verticalSize)）")

    var wide = RecordingExportSettings.default
    wide.canvasAspect = .wide16x9
    let wideSize = wide.canvasSize(for: source)
    try expect(wideSize == CGSize(width: 1920, height: 1080),
               "1080p 横屏画布应为 1920×1080（实际 \(wideSize)）")

    // source 保持原逻辑（cropTo16x9 裁切），不受画幅字段影响
    let sourceSize = RecordingExportSettings.default.canvasSize(for: source)
    try expect(sourceSize == RecordingExportSettings.default.outputSize(for: source),
               "source 画幅应退回原有输出逻辑")

    // 平台预设映射
    try expect(PlatformExportPreset.douyin.canvasAspect == .vertical9x16
        && PlatformExportPreset.douyin.beautifyEnabled, "抖音应为竖屏+美化")
    try expect(PlatformExportPreset.xiaohongshu.canvasAspect == .vertical9x16
        && PlatformExportPreset.xiaohongshu.beautifyEnabled, "小红书应为竖屏+美化")
    try expect(PlatformExportPreset.shipinhao.canvasAspect == .vertical9x16, "视频号应为竖屏")
    try expect(PlatformExportPreset.bilibili.canvasAspect == .wide16x9
        && !PlatformExportPreset.bilibili.beautifyEnabled, "B 站应为横屏满幅")
    try expect(PlatformExportPreset.original.canvasAspect == .source
        && !PlatformExportPreset.original.beautifyEnabled, "原样应保持旧逻辑")

    // 美化参数取 HuaStudio 实测默认值
    try expect(abs(RecordingExportSettings.default.beautifyPaddingRatio - 0.1049) < 1e-9,
               "留白默认 10.5%")
    try expect(RecordingExportSettings.default.beautifyCornerRadiusPoints == 20,
               "圆角默认 20pt")
}

func testWindowCaptureGeometry() throws {
    let windows = [
        CGRect(x: 100, y: 100, width: 800, height: 600),
        CGRect(x: 700, y: 400, width: 400, height: 300),   // 重叠弹窗
        CGRect(x: 500, y: 500, width: 20, height: 20)      // 装饰小窗,应被过滤
    ]
    let union = WindowCaptureGeometry.unionRect(ofFrames: windows)
    try expect(union == CGRect(x: 100, y: 100, width: 1000, height: 600),
               "联合矩形应纳入弹窗、排除装饰小窗")
    try expect(WindowCaptureGeometry.unionRect(ofFrames: []) == nil, "空列表应返回 nil")
    try expect(WindowCaptureGeometry.unionRect(ofFrames: [CGRect(x: 0, y: 0, width: 10, height: 10)]) == nil,
               "只有装饰小窗应返回 nil")

    // 包含式扩展：2:1 初始比例，弹窗向下延伸，比例不变且包含
    let base = CGRect(x: 0, y: 0, width: 1000, height: 500)
    let withDialog = CGRect(x: 400, y: 300, width: 1000, height: 800)
    let display = CGRect(x: 0, y: 0, width: 2000, height: 1500)
    let contain = WindowCaptureGeometry.containRect(aspectOf: base, containing: withDialog, in: display)
    try expect(contain.contains(withDialog), "扩展后应完整包含联合范围")
    try expect(abs(contain.width / contain.height - 2.0) < 0.001, "宽高比应保持不变")

    // 联合范围超出屏幕：退回屏幕内同比例最大矩形
    let huge = CGRect(x: 0, y: 0, width: 3000, height: 1400)
    let fallback = WindowCaptureGeometry.containRect(aspectOf: base, containing: huge, in: display)
    try expect(abs(fallback.width - 2000) < 0.5 && abs(fallback.height - 1000) < 0.5,
               "应退回屏幕内同比例最大矩形（2000×1000）")

    // sourceRect 平移（SCK 左上原点系内纯平移）
    let source = WindowCaptureGeometry.sourceRect(
        for: CGRect(x: 150, y: 200, width: 100, height: 80),
        in: CGRect(x: 100, y: 100, width: 1920, height: 1080)
    )
    try expect(source == CGRect(x: 50, y: 100, width: 100, height: 80),
               "sourceRect 应为显示器坐标系内平移")
}

func testResourceWatchdogLevels() throws {
    try expect(ResourceWatchdog.diskLevel(freeDiskBytes: nil) == .ok, "读不出余量不告警")
    try expect(ResourceWatchdog.diskLevel(freeDiskBytes: 20 << 30) == .ok, "20GB 应为正常")
    try expect(ResourceWatchdog.diskLevel(freeDiskBytes: 5 << 30) == .low, "5GB 应为偏低")
    try expect(ResourceWatchdog.diskLevel(freeDiskBytes: 1 << 30) == .critical, "1GB 应为危急")

    let ok = ResourceWatchdog.Snapshot(freeDiskBytes: 20 << 30, memoryMegabytes: 500)
    try expect(ResourceWatchdog.issue(for: ok) == nil, "正常水位无结论")

    let low = ResourceWatchdog.Snapshot(freeDiskBytes: 5 << 30, memoryMegabytes: 500)
    try expect(ResourceWatchdog.issue(for: low)?.contains("尽快收尾") == true, "低水位提示尽快收尾")

    let critical = ResourceWatchdog.Snapshot(freeDiskBytes: 1 << 30, memoryMegabytes: 500)
    try expect(ResourceWatchdog.issue(for: critical)?.contains("立即停止") == true, "危急水位提示立即停止")

    let memory = ResourceWatchdog.Snapshot(freeDiskBytes: 20 << 30, memoryMegabytes: 2000)
    try expect(ResourceWatchdog.issue(for: memory)?.contains("内存") == true, "内存异常应单独告警")

    // 两条同时异常时磁盘优先（更紧急）
    let both = ResourceWatchdog.Snapshot(freeDiskBytes: 1 << 30, memoryMegabytes: 2000)
    try expect(ResourceWatchdog.issue(for: both)?.contains("磁盘") == true, "磁盘危急优先于内存告警")
}

func testRecordingRecoveryInfoRoundTrip() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let outputURL = tempDir.appendingPathComponent("AreaRecord_test.mov")
    let info = RecordingRecoveryInfo(
        version: 1,
        outputFileName: "AreaRecord_test.mov",
        width: 2940,
        height: 1912,
        screenFrameRate: 60,
        pixelFormat: "BGRA",
        codec: "h264",
        averageBitRate: 16_000_000,
        maxKeyFrameIntervalDuration: 2.0,
        hint: "test"
    )
    RecordingRecoveryStore.save(info, for: outputURL)
    let loaded = RecordingRecoveryStore.load(for: outputURL)
    try expect(loaded == info, "恢复参数应可完整往返")
    try expect(RecordingRecoveryInfo.recoveryURL(for: outputURL).lastPathComponent == "AreaRecord_test_recovery.json",
               "恢复文件命名应为 <base>_recovery.json")

    RecordingRecoveryStore.remove(for: outputURL)
    try expect(!FileManager.default.fileExists(atPath: RecordingRecoveryInfo.recoveryURL(for: outputURL).path),
               "正常收尾后恢复文件应被删除")
}

let tests: [(String, () throws -> Void)] = [
    ("AudioStartGate", testAudioStartGate),
    ("BoundedDropOldestBuffer", testBoundedDropOldestBuffer),
    ("ResolvedRecordingTarget", testResolvedRecordingTarget),
    ("MetricsAndValidator", testMetricsURLAndMissingOutputValidation),
    ("RecordingPixelFormatPolicy", testRecordingPixelFormatPolicy),
    ("RecordingExportSettings", testRecordingExportSettings),
    ("RecordingArtifactOrganizer", testRecordingArtifactOrganizer),
    ("RecordingArtifactDeletion", testRecordingArtifactDeletion),
    ("CueRecordPathPolicy", testCueRecordPathPolicy),
    ("CueRecordProjectManifestAndConflictDetection", testCueRecordProjectManifestAndConflictDetection),
    ("CueRecordTempVaultWorkflow", testCueRecordTempVaultWorkflow),
    ("CueRecordVaultRepairer", testCueRecordVaultRepairer),
    ("TeleprompterLineBreakTokenization", testTeleprompterLineBreakTokenization),
    ("TeleprompterLineBreakDeduplication", testTeleprompterLineBreakDeduplication),
    ("TeleprompterPaceCueTokenization", testTeleprompterPaceCueTokenization),
    ("TeleprompterLegacySlowCueTokenization", testTeleprompterLegacySlowCueTokenization),
    ("SpeechTrackingThreeWordAnchorCrossesLineBreaks", testSpeechTrackingThreeWordAnchorCrossesLineBreaks),
    ("SpeechTrackingThreeCJKAnchorCrossesBreakTokens", testSpeechTrackingThreeCJKAnchorCrossesBreakTokens),
    ("RecordingEditorPresentation", testRecordingEditorPresentation),
    ("AIVoiceCommandParsing", testAIVoiceCommandParsing),
    ("LocalizationDictionaryHasNoDuplicateKeys", testLocalizationDictionaryHasNoDuplicateKeys),
    ("ExportCropTo16x9", testExportCropTo16x9),
    ("RecordingPreflight", testRecordingPreflight),
    ("UnfinishedRecordingStore", testUnfinishedRecordingStore),
    ("RecordingMarkerStore", testRecordingMarkerStore),
    ("RecordingTranscriptRecorder", testRecordingTranscriptRecorder),
    ("CursorEventTrackGeometryAndThrottle", testCursorEventTrackGeometryAndThrottle),
    ("CursorSamplerInterpolation", testCursorSamplerInterpolation),
    ("CursorRendererAssets", testCursorRendererAssets),
    ("ZoomTimelineEasingAndCrop", testZoomTimelineEasingAndCrop),
    ("ZoomHeuristicFromClicks", testZoomHeuristicFromClicks),
    ("ZoomHeuristicDwell", testZoomHeuristicDwell),
    ("ZoomRangeStoreRoundTrip", testZoomRangeStoreRoundTrip),
    ("CursorPixelRendering", testCursorPixelRendering),
    ("IdleSpanDetection", testIdleSpanDetection),
    ("AgentEditPromptAndApplier", testAgentEditPromptAndApplier),
    ("PlatformPresetCanvasSizes", testPlatformPresetCanvasSizes),
    ("WindowCaptureGeometry", testWindowCaptureGeometry),
    ("ResourceWatchdogLevels", testResourceWatchdogLevels),
    ("RecordingRecoveryInfoRoundTrip", testRecordingRecoveryInfoRoundTrip)
]

do {
    for (name, test) in tests {
        try test()
        print("PASS \(name)")
    }
    print("PASS recording core tests")
} catch {
    fputs("FAIL \(error)\n", stderr)
    exit(1)
}

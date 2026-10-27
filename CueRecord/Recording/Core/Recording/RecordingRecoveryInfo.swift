import Foundation

/// 崩溃恢复参数文件（学习 Screen Studio 的 unfinishedRecordings 与 HuaStudio 的
/// .bak 思想：**假设崩溃一定发生**，提前把"救回素材所需的全部参数"落盘）。
///
/// 无 moov 的 mdat 用 untrunc 修复时需要一个**同参数健康参考轨**——2026-10-24
/// 与 10-27 两次抢救都是临时翻旧文件找的。这个文件把参数写下来：崩溃后任何
/// Agent/工具不用翻历史，直接按此参数初始化修复。
/// 写入时机：开录即写（第一次帧写出前），停录成功即删。
nonisolated struct RecordingRecoveryInfo: Codable, Sendable, Equatable {
    var version: Int
    var outputFileName: String
    var width: Int
    var height: Int
    var screenFrameRate: Int
    var pixelFormat: String
    /// 编码参数（untrunc 参考轨匹配用）
    var codec: String
    var averageBitRate: Int
    var maxKeyFrameIntervalDuration: Double
    /// 便于人读的恢复步骤
    var hint: String

    static func recoveryURL(for outputURL: URL) -> URL {
        let base = outputURL.deletingPathExtension().path
        return URL(fileURLWithPath: "\(base)_recovery.json")
    }
}

nonisolated enum RecordingRecoveryStore {
    static func save(_ info: RecordingRecoveryInfo, for outputURL: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(info) else { return }
        try? data.write(to: RecordingRecoveryInfo.recoveryURL(for: outputURL), options: .atomic)
    }

    static func remove(for outputURL: URL) {
        try? FileManager.default.removeItem(at: RecordingRecoveryInfo.recoveryURL(for: outputURL))
    }

    static func load(for outputURL: URL) -> RecordingRecoveryInfo? {
        guard let data = try? Data(contentsOf: RecordingRecoveryInfo.recoveryURL(for: outputURL)) else {
            return nil
        }
        return try? JSONDecoder().decode(RecordingRecoveryInfo.self, from: data)
    }
}

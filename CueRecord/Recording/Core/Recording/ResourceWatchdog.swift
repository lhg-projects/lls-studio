import Foundation

/// 录制期资源水位（2026-10-27 长录制损坏事故的防线）。
/// 事故机理：31 分钟录制把内存/磁盘推到极限（swap 95%、盘剩 11GB），
/// 系统扼制写入，停止流程无法收尾 → 两条轨都无 moov。
/// 这组检查不阻止录制，只做两件事：把水位写进日志/metrics（事后可归因），
/// 以及让 UI 有机会提示用户"该停了/该清理了"。
nonisolated enum ResourceWatchdog {
    /// 剩余磁盘低于该值（字节）应立即停止录制。约 3GB：
    /// 双轨写盘峰值 ~90MB/min，3GB 还能撑约 30 分钟，同时给系统留活路。
    static let criticalFreeDiskBytes: Int64 = 3 * 1024 * 1024 * 1024
    /// 剩余磁盘低于该值（字节）应提示用户尽快收尾。
    static let lowFreeDiskBytes: Int64 = 8 * 1024 * 1024 * 1024
    /// 应用内存足迹超过该值（MB）视为异常（正常录制 < 1GB）。
    static let highMemoryMegabytes: Double = 1500

    nonisolated struct Snapshot: Equatable, Sendable {
        var freeDiskBytes: Int64?
        var memoryMegabytes: Double
    }

    static func snapshot(outputDirectory: URL) -> Snapshot {
        Snapshot(
            freeDiskBytes: RecordingPreflight.availableCapacity(on: outputDirectory),
            memoryMegabytes: currentMemoryMegabytes()
        )
    }

    /// 任务物理足迹（MB）。与 Support/MemoryFootprint 同公式，但独立实现，
    /// 让核心测试（swiftc 直编）不必拖入 app 层文件。
    static func currentMemoryMegabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1024 / 1024
    }

    nonisolated enum DiskLevel: Equatable, Sendable {
        case ok
        case low
        case critical
    }

    static func diskLevel(freeDiskBytes: Int64?) -> DiskLevel {
        guard let freeDiskBytes else { return .ok }
        if freeDiskBytes < criticalFreeDiskBytes { return .critical }
        if freeDiskBytes < lowFreeDiskBytes { return .low }
        return .ok
    }

    /// 一次水位巡检的结论（可进日志与 UI）。nil = 一切正常。
    static func issue(for snapshot: Snapshot) -> String? {
        switch diskLevel(freeDiskBytes: snapshot.freeDiskBytes) {
        case .critical:
            let gb = Double(snapshot.freeDiskBytes ?? 0) / 1_073_741_824
            return String(format: "磁盘剩余 %.1f GB，随时可能损坏录制，请立即停止并清理磁盘", gb)
        case .low:
            let gb = Double(snapshot.freeDiskBytes ?? 0) / 1_073_741_824
            return String(format: "磁盘剩余 %.1f GB，长录制请尽快收尾", gb)
        case .ok:
            break
        }
        guard snapshot.memoryMegabytes > highMemoryMegabytes else { return nil }
        return String(format: "应用内存 %.0f MB 异常偏高，建议尽快停止录制", snapshot.memoryMegabytes)
    }
}

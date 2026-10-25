import CoreGraphics
import Foundation

/// 窗口录制（应用级采集）的几何计算。
///
/// 为什么需要它：单窗口滤镜（desktopIndependentWindow）只录那一个窗口，
/// 软件弹出的设置框/对话框是**独立窗口**，根本录不进来（2026-10-24 报障）。
/// 改用应用级滤镜（display + including [app]）后，采集面是整块显示器，
/// 需要：
/// 1. 把该应用所有可见窗口的 frame 取联合矩形（弹窗自然在内）；
/// 2. sourceRect 只采联合范围（显示器坐标系内平移即可——SCWindow/SCDisplay
///    的 frame 同为 SCK 左上原点系，不做 AppKit 翻转）；
/// 3. 输出尺寸开录时固定（AVAssetWriter 约束），联合范围变化时按固定
///    宽高比"包含式"扩展，画面等比缩放，不变形。
nonisolated enum WindowCaptureGeometry {
    /// 应用可见窗口的联合矩形。过滤掉过小的装饰性悬浮窗。
    static func unionRect(ofFrames frames: [CGRect], minimumDimension: CGFloat = 50) -> CGRect? {
        let significant = frames.filter { $0.width >= minimumDimension && $0.height >= minimumDimension }
        guard let first = significant.first else { return nil }
        var rect = first
        for frame in significant.dropFirst() {
            rect = rect.union(frame)
        }
        return rect
    }

    /// 以 base 的宽高比扩展到完整包含 target（中心对齐），并钳制在 display 内。
    /// 放不下时退回 display 内同比例的最大矩形。
    static func containRect(aspectOf base: CGRect, containing target: CGRect, in display: CGRect) -> CGRect {
        guard base.width > 0, base.height > 0, display.width > 0, display.height > 0 else { return display }
        let aspect = base.width / base.height

        var width = max(target.width, base.width)
        var height = width / aspect
        if height < target.height {
            height = target.height
            width = height * aspect
        }

        var rect = CGRect(
            x: target.midX - width / 2,
            y: target.midY - height / 2,
            width: width,
            height: height
        )
        let clamped = rect.intersection(display)
        if clamped.width >= width - 0.5, clamped.height >= height - 0.5 {
            return clamped
        }

        // 联合范围超出屏幕：取屏幕内同比例最大矩形
        let displayAspect = display.width / display.height
        if displayAspect > aspect {
            let fittedHeight = display.height
            return CGRect(
                x: display.midX - fittedHeight * aspect / 2,
                y: display.minY,
                width: fittedHeight * aspect,
                height: fittedHeight
            )
        }
        let fittedWidth = display.width
        return CGRect(
            x: display.minX,
            y: display.midY - fittedWidth / aspect / 2,
            width: fittedWidth,
            height: fittedWidth / aspect
        )
    }

    /// 联合矩形 → 显示器内 sourceRect（同为 SCK 左上原点系，纯平移）
    static func sourceRect(for union: CGRect, in display: CGRect) -> CGRect {
        CGRect(
            x: union.minX - display.minX,
            y: union.minY - display.minY,
            width: union.width,
            height: union.height
        )
    }
}

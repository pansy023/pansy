import Foundation

/// 矩形，用 Double 表达，避免让 `KebiaoCore` 依赖 CoreGraphics / UIKit。
///
/// 对应 Compose 的 `androidx.compose.ui.geometry.Rect`（`left/top/right/bottom`）。
/// App 层在需要时把它转成 `CGRect`。
public struct LayoutRect: Equatable, Sendable {
    public var left: Double
    public var top: Double
    public var width: Double
    public var height: Double

    public init(left: Double, top: Double, width: Double, height: Double) {
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }

    public var right: Double { left + width }
    public var bottom: Double { top + height }
    public var centerX: Double { left + width / 2 }
    public var centerY: Double { top + height / 2 }
}

/// 课表网格的纯几何与文本算法。
///
/// 证据：`apk_work/kb/src2/TimetableGridV2.kt`（这是我们为 Android 端写的同款网格，
/// 与原版 APK 的 `TimetableGridV2Kt` 行为一致）：
/// - 常量块 `:80-103`、`:173-176`
/// - `leftColumnWidth` `:111-112`
/// - `fitTextSize` `:726-731`、`buildingOf`/`roomOf` `:733-741`、`dayIndexOf` `:743-752`
/// - `prettyDate`/`pad2` `:754-763`、`paletteColor` `:765-768`
/// - `mergeAdjacent` `:774-793`、`buildTimeRange` `:796-805`
/// - 卡片纵向几何 `:550-566`、`expandTarget` `:191-207`
public enum TimetableLayout {

    // MARK: - 尺寸常量（dp / pt 数值一一对应）

    /// 未显示周末时的左侧节次列宽度。
    public static let leftColumnWide: Double = 50
    /// 显示周末（7 列）时收窄的左侧节次列宽度。
    public static let leftColumnNarrow: Double = 42
    /// 表头高度。
    public static let headerHeight: Double = 46
    /// 三个时间段面板之间的间距。
    public static let blockGap: Double = 10
    /// 同一节次内上下两张卡片之间的间距。
    public static let cardGap: Double = 5
    /// 卡片最小高度，低于此值的卡片会被撑到该高度，避免完全看不见。
    public static let minCardHeight: Double = 12
    /// 面板圆角。
    public static let panelRadius: Double = 16
    /// 面板内边距。
    public static let panelPadding: Double = 4

    /// 展开卡片与网格边缘之间保留的空隙。
    public static let expandMargin: Double = 14
    /// 展开卡片最小宽度。
    public static let expandMinWidth: Double = 190
    /// 展开卡片最小高度（详情布局实际需要的高度）。
    public static let expandMinHeight: Double = 196

    /// 卡片展开时的目标宽度倍率（`:198`）。
    public static let expandWidthFactor: Double = 1.8
    /// 卡片展开时的目标高度倍率（`:200`）。
    public static let expandHeightFactor: Double = 1.85

    /// 6 天及以上列时收窄左侧列（`:111-112`）。
    public static func leftColumnWidth(dayCount: Int) -> Double {
        dayCount >= 7 ? leftColumnNarrow : leftColumnWide
    }

    // MARK: - 星期

    /// 星期标签 → 1…7（周一…周日），其它一律 0。
    ///
    /// 对应 `TimetableGridV2.kt:743-752`：对**整个字符串**做精确匹配，
    /// 不是取首字符——`"周一"` 会返回 0。
    public static func dayIndexOf(_ weekday: String) -> Int {
        switch weekday {
        case "一": return 1
        case "二": return 2
        case "三": return 3
        case "四": return 4
        case "五": return 5
        case "六": return 6
        case "日": return 7
        default: return 0
        }
    }

    // MARK: - 字号自适应

    /// 根据卡片高度决定字号。
    ///
    /// 对应 `TimetableGridV2.kt:726-731`：
    /// ```
    /// cap = max(configured, 7)
    /// fit = ((heightDp - 8f) / 5f).toInt()      // 向零截断
    /// return fit >= cap ? cap : max(fit, 7)
    /// ```
    /// 用户要求（原始需求 m07988）是「字号保持配置值」，只有在卡片矮到
    /// 物理上放不下时才降级，所以这里默认返回 `configured`。
    ///
    /// - Note: 中间量按 Kotlin 原样用 **Float** 计算（`Dp.value` 是 Float），
    ///   再 `Int(...)` 向零截断；若改用 Double 会在 `(h-8)/5` 恰好落在整数
    ///   边缘时（如 `h = 23f`）出现 2.9999998 / 3.0 的截断差异。
    public static func fitTextSize(configured: Int, heightDp: Double) -> Int {
        let cap = max(configured, 7)
        let fit = Int((Float(heightDp) - 8) / 5)
        return fit >= cap ? cap : max(fit, 7)
    }

    // MARK: - 相邻课程合并

    /// 把同一天里**同名、同地点、同教师**且**节次连续**的课程合并成一张卡片。
    ///
    /// 对应 `TimetableGridV2.kt:774-793`：
    /// - 先按 `startPeriod` 升序排序（Kotlin 的 `sortedBy` 是稳定排序，
    ///   所以这里用下标做次关键字显式保证稳定，避免 Swift 排序不稳定时结果不同）；
    /// - 合并条件：`next.name == cur.name && next.location == cur.location &&
    ///   next.teacher == cur.teacher && next.startPeriod == cur.endPeriod + 1`；
    /// - 合并后 `endPeriod` 取后者的 `endPeriod`；
    /// - 其余字段（含 `id`、`color`）取合并链上**第一张**卡片的值。
    public static func mergeAdjacent(_ input: [Course]) -> [Course] {
        guard !input.isEmpty else { return input }

        let sorted = input.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.startPeriod != rhs.element.startPeriod {
                    return lhs.element.startPeriod < rhs.element.startPeriod
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        var result: [Course] = []
        result.reserveCapacity(sorted.count)
        var current = sorted[0]

        for index in 1..<sorted.count {
            let next = sorted[index]
            let sameCourse = next.name == current.name
                && next.location == current.location
                && next.teacher == current.teacher
            if sameCourse, next.startPeriod == current.endPeriod + 1 {
                current.endPeriod = next.endPeriod
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }

    // MARK: - 时间区间文本

    /// 生成卡片上的时间文本，如 `"08:00-09:40"`。
    ///
    /// 对应 `TimetableGridV2.kt:796-805`：
    /// - 起始取 `timeSlots[startPeriod - 1]` 里第一个 `-` **之前**的部分；
    /// - 结束取 `timeSlots[endPeriod - 1]` 里第一个 `-` **之后**的部分；
    /// - 两者都取 `trim()`；
    /// - 越界（`getOrNull` 返回 null）或该串里根本没有 `-` 时，
    ///   Kotlin 的 `substringBefore/After` 的默认行为是**返回原串**
    ///   （`missingDelimiterValue = this`），这里必须一致；
    /// - 两个都空 → 空串；只有一个空 → 返回另一个；否则 `"起-止"`。
    public static func buildTimeRange(_ course: Course, timeSlots: [String]) -> String {
        let first = slotBoundary(timeSlots, at: course.startPeriod - 1, beforeDelimiter: true)
        let last = slotBoundary(timeSlots, at: course.endPeriod - 1, beforeDelimiter: false)

        switch (first.isEmpty, last.isEmpty) {
        case (true, true): return ""
        case (true, false): return last
        case (false, true): return first
        case (false, false): return "\(first)-\(last)"
        }
    }

    /// `timeSlots.getOrNull(index)?.substringBefore/After("-")?.trim() ?: ""`
    private static func slotBoundary(_ timeSlots: [String], at index: Int, beforeDelimiter: Bool) -> String {
        guard index >= 0, index < timeSlots.count else { return "" }
        let slot = timeSlots[index]
        guard let dash = slot.range(of: "-") else {
            // Kotlin: 找不到分隔符时返回原串。
            return slot.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let piece = beforeDelimiter ? slot[slot.startIndex..<dash.lowerBound] : slot[dash.upperBound...]
        return String(piece).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 日期文本

    /// `"5/2"` → `"05-02"`；任何不符合 `月/日` 形式的输入原样返回。
    /// 对应 `TimetableGridV2.kt:754-761`。
    public static func prettyDate(_ raw: String) -> String {
        let parts = raw.components(separatedBy: "/")
        guard parts.count == 2 else { return raw }
        let trimmedMonth = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDay = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let month = Int(trimmedMonth), let day = Int(trimmedDay) else { return raw }
        return "\(pad2(month))-\(pad2(day))"
    }

    /// 小于 10 补前导零。对应 `TimetableGridV2.kt:763`。
    public static func pad2(_ value: Int) -> String {
        value < 10 ? "0\(value)" : String(value)
    }

    // MARK: - 卡片纵向几何

    // MARK: - 时间段面板
    //
    // 原版把一天拆成最多三个面板（上午 1-4、下午 5-8、晚上 9..rows），每个面板各自
    // 过滤课程、各自从 `prevBottom = 0` 开始排布（`TimetableGridV2.kt:551`）。

    /// 取出某一天落在某个面板内的课程并做相邻合并。
    ///
    /// 逐字对应 `TimetableGridV2.kt:551` 的
    /// `mergeAdjacent(courses.filter { it.dayOfWeek == day && it.endPeriod >= startPeriod && it.startPeriod <= endPeriod })`。
    ///
    /// - Parameter dayOfWeek: 1…7（周一…周日），与 `dayIndexOf` 的取值域一致。
    public static func coursesInBlock(
        _ courses: [Course],
        dayOfWeek: Int,
        blockStartPeriod: Int,
        blockEndPeriod: Int
    ) -> [Course] {
        let filtered = courses.filter {
            $0.dayOfWeek == dayOfWeek
                && $0.endPeriod >= blockStartPeriod
                && $0.startPeriod <= blockEndPeriod
        }
        return mergeAdjacent(filtered)
    }

    /// 一张卡片在它所属时间段面板内的 `top` 与 `height`（单位与 `cellHeight` 一致）。
    ///
    /// 对应 `TimetableGridV2.kt:550-566`：
    /// ```
    /// prevBottom = 0
    /// 对每张卡片：
    ///   start         = card.startPeriod.coerceIn(blockStartPeriod, blockEndPeriod)
    ///   end           = card.endPeriod.coerceIn(start, blockEndPeriod)
    ///   naturalTop    = cellH * (start - blockStartPeriod)
    ///   naturalBottom = cellH * (end - blockStartPeriod + 1) - CardGap
    ///   top           = naturalTop < prevBottom ? prevBottom + CardGap : naturalTop
    ///   h             = max(naturalBottom - top, MinCardHeight)
    ///   prevBottom    = top + h
    /// ```
    /// 这个「不重叠」规则是原版处理同一格内多门课时的手段：后一张卡片永远被推到
    /// 前一张下面，而不是盖住它。
    ///
    /// - Important: `start` / `end` 的 **coerceIn 不能省**（`TimetableGridV2.kt:557-558`）。
    ///   跨面板的课程（例如 4-5 节横跨上午/下午）在两个面板里都会被画到，
    ///   各自被裁到本面板的范围内；漏掉这一步会让卡片的 `top` / `height` 算出负数。
    ///
    /// - Parameter blockStartPeriod: 该面板的起始节次（原版是 1 / 5 / 9）。
    /// - Parameter blockEndPeriod: 该面板的结束节次（原版是 4 / 8 / rows）。
    /// - Parameter previousBottom: 上一张卡片的 `top + height`；面板内第一张传 0。
    public static func cardVerticalGeometry(
        card: Course,
        blockStartPeriod: Int,
        blockEndPeriod: Int,
        cellHeight: Double,
        previousBottom: Double
    ) -> (top: Double, height: Double) {
        let start = Swift.min(Swift.max(card.startPeriod, blockStartPeriod), blockEndPeriod)
        let end = Swift.min(Swift.max(card.endPeriod, start), blockEndPeriod)

        let naturalTop = cellHeight * Double(start - blockStartPeriod)
        let naturalBottom = cellHeight * Double(end - blockStartPeriod + 1) - cardGap
        let top = naturalTop < previousBottom ? previousBottom + cardGap : naturalTop
        let height = max(naturalBottom - top, minCardHeight)
        return (top, height)
    }

    /// 卡片被点击后，展开卡片最终应落在的位置与尺寸（网格坐标系）。
    ///
    /// 对应 `TimetableGridV2.kt:191-207`：
    /// - 卡片绕**自身中心**放大，所以它和被点的那张卡保持空间连续性；
    /// - 宽 = `origin.width * 1.8`，但不超过可用宽度；若小于最小宽度则取最小宽度；
    /// - 高 = `origin.height * 1.85`，下限是最小高度、上限是可用高度；
    /// - 最后把矩形夹回 `[margin, boxSize - margin]`，所以靠边的卡片是被「推回来」
    ///   而不是被挪到屏幕中央。
    public static func expandTarget(
        origin: LayoutRect,
        boxWidth: Double,
        boxHeight: Double,
        margin: Double = expandMargin,
        minWidth: Double = expandMinWidth,
        needHeight: Double = expandMinHeight
    ) -> LayoutRect {
        // Kotlin: maxW = (boxW - margin * 2).coerceAtLeast(origin.width)
        let maxWidth = max(boxWidth - margin * 2, origin.width)
        let maxHeight = max(boxHeight - margin * 2, origin.height)

        var width = min(origin.width * expandWidthFactor, maxWidth)
        if width < minWidth { width = min(minWidth, maxWidth) }
        let height = min(max(origin.height * expandHeightFactor, needHeight), maxHeight)

        let left = (origin.centerX - width / 2)
            .clamped(lower: margin, upper: max(boxWidth - width - margin, margin))
        let top = (origin.centerY - height / 2)
            .clamped(lower: margin, upper: max(boxHeight - height - margin, margin))

        return LayoutRect(left: left, top: top, width: width, height: height)
    }
}

extension Double {
    /// Kotlin `coerceIn(lower, upper)`。调用方必须保证 `lower <= upper`
    /// （原版通过 `coerceAtLeast` 显式保证了这一点）。
    func clamped(lower: Double, upper: Double) -> Double {
        Swift.min(Swift.max(self, lower), upper)
    }
}

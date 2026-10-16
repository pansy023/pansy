import SwiftUI
import KebiaoCore

/// 点开一张卡片时上报的信息：课程本身 + 它在浮层坐标系里的矩形。
///
/// 矩形必须在**浮层坐标系**里测（`TimetableGrid.overlaySpaceName`），
/// 因为 `TimetableView` 的展开浮层挂在同一个坐标系上；用 `.local`
/// 会拿到面板内外不一致的原点，展开起点就会偏。
struct CourseCardTap {
    /// 已做相邻合并的卡片（`id` 为合并链首张的 id）。
    let course: Course
    /// 被点卡片在浮层坐标系里的矩形。
    let frameInOverlay: CGRect
    /// 这张卡是否出现在当前显示的这一周（决定展开卡的透明度基准）。
    let occursThisWeek: Bool
}

/// 课表网格：表头行 + 左列节次 + 三个时间段面板。
///
/// 网格**不自己读**课程数据，全部由 `TimetableView` 传进来：
/// 「显示第几周、今天在哪一列、选中了哪张卡」只有一处真相。
///
/// 布局结构（逐条对应 `apk_work/kb/src2/TimetableGridV2.kt`）：
/// - 表头行高 `HeaderHeight = 46`，左列宽 `leftColumnWidth(dayCount:)`
///   （7 列时 42、否则 50）（`:96-112`、`:684-693`，见 `docs/recon/01-timetable-algorithms.md` §7）。
/// - 每个面板前有一个 `BlockGap = 10` 的间隔（`TimetableGridV2.kt:427`）。
/// - 面板高 `blockHeight = cellH * blockRows`、`blockRows = (end - start + 1).coerceAtLeast(1)`
///   （`:496-500`），面板内边距 `PanelPadding = 4`、圆角 `PanelRadius = 16`。
/// - 卡片纵向几何**必须**由 `TimetableLayout.cardVerticalGeometry` 给出，此处不做二次推导。
struct TimetableGrid: View {

    @EnvironmentObject private var environment: AppEnvironment

    // MARK: - 输入

    /// 当前显示的周次（展开卡的「非本周」判断与标题用）。
    let displayedWeek: Int
    /// 要显示的星期编号，顺序与 `weekDates` 一致（1 = 周一 … 7 = 周日）。
    let visibleWeekdays: [Int]
    /// 与 `visibleWeekdays` 一一对应的日期（`WeekDate.date` 形如 `"5/2"`，`label` 形如 `"一"`）。
    let weekDates: [WeekDate]
    /// 要显示的课程（已按「是否含非本周课程」过滤）。
    let courses: [Course]
    /// `courses` 里每门课是否发生在当前显示周，键为 `Course.id`。
    let occursThisWeek: [Int: Bool]
    /// `TimetableStore.todayColumnIndex`：今天在第几列，nil 表示今天不在这一周内。
    let todayColumnIndex: Int?
    /// 点击一张卡片。
    let onTapCard: (CourseCardTap) -> Void
    /// 展开浮层所在的具名坐标系名。网格上报的矩形都用它测量。
    let overlaySpaceName: String
    /// 把网格矩形（浮层坐标系）回传给浮层，用于夹取展开卡片的位置。
    @Binding var gridFrameInOverlay: CGRect

    // MARK: - 逐卡测量
    //
    // 卡片被点开时要拿到「网格里那张卡片」的真实矩形作为动画起点。
    // 用 `.background(GeometryReader)` 逐卡测量并缓存：`.background` 不参与布局，
    // 不会改变卡片尺寸，因此不会反过来影响几何计算。

    @State private var cardFrames: [Int: CGRect] = [:]

    // MARK: - 派生

    private var store: TimetableStore { environment.store }
    private var settings: AppSettings { store.settings }
    private var dark: Bool { store.uiFlags.isDarkTheme }
    private var optimize: Bool { store.uiFlags.isOptimizeMode }

    /// `cellH = settings.courseCellHeightDp.dp`（`TimetableGridV2.kt:222`）。
    private var cellHeight: CGFloat { CGFloat(settings.courseCellHeightDp) }

    /// 三个面板（上午 1-4 / 下午 5-8 / 晚上 9-rows），直接取 store 的派生值。
    private var blockRanges: [ClosedRange<Int>] { store.periodBlocks }

    /// 今天所在列 — 只有它落在可见列里才生效。
    private var todayColumn: Int? {
        guard let index = todayColumnIndex, index >= 0, index < visibleWeekdays.count else { return nil }
        return index
    }

    /// 面板底色：`panelColor(dark:hasCustomBackground:)`（`TimetableGridV2.kt:126-135`）。
    /// 第二个参数走 `AppSettings.hasCustomBackground`（`!= null && isNotBlank()`，
    /// `:768-771`），不能简化成 `backgroundImageUri != nil`。
    private var panelColor: Color {
        Theme.panelColor(dark: dark, hasCustomBackground: settings.hasCustomBackground)
    }

    // MARK: - 主体

    var body: some View {
        GeometryReader { proxy in
            let dayCount = max(visibleWeekdays.count, 1)
            let leftWidth = CGFloat(TimetableLayout.leftColumnWidth(dayCount: visibleWeekdays.count))
            let dayWidth = max((proxy.size.width - leftWidth) / CGFloat(dayCount), 1)

            VStack(spacing: 0) {
                headerRow(leftWidth: leftWidth, dayWidth: dayWidth)

                ForEach(Array(blockRanges.enumerated()), id: \.offset) { _, block in
                    // 面板前的竖直间隔（`TimetableGridV2.kt:427`）。
                    Color.clear.frame(height: Theme.blockGap)
                    periodBlock(block: block, leftWidth: leftWidth, dayWidth: dayWidth)
                }

                // 原版在三个面板之后再补一个 BlockGap（`TimetableGridV2.kt:427`）。
                Color.clear.frame(height: Theme.blockGap)
            }
            .background(gridFrameReporter)
        }
    }

    /// 把整个网格的矩形（含表头与全部面板）报给浮层。
    private var gridFrameReporter: some View {
        GeometryReader { gridProxy in
            let frame = gridProxy.frame(in: .named(overlaySpaceName))
            Color.clear
                .onAppear { gridFrameInOverlay = frame }
                .onChange(of: frame) { _, newValue in gridFrameInOverlay = newValue }
        }
    }

    // MARK: - 表头行

    /// 表头行：`"周一" + 日期` 的单元格 + 今天列的强调。
    ///
    /// 拆成三个小属性而不是一个 `ZStack` 里塞四段 `if`，纯粹是为了让
    /// Swift 的类型检查器少受点罪（这种多层 `ZStack` + `ForEach` + `if let`
    /// 的组合是 `expression too complex` 的常客）。
    private func headerRow(leftWidth: CGFloat, dayWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            panelColor
            headerTodayColumnHighlight(leftWidth: leftWidth, dayWidth: dayWidth)
            headerCells(leftWidth: leftWidth, dayWidth: dayWidth)
            headerTodayColumnAccent(leftWidth: leftWidth, dayWidth: dayWidth)
        }
        .frame(height: Theme.headerHeight)
        // 表头只圆上面两角（面板各自圆角，表头单独贴在最上方）。
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: Theme.panelRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: Theme.panelRadius,
                style: .continuous
            )
        )
    }

    /// 今天所在列在表头里的整列底色。
    ///
    /// 原版网格不高亮今天（`TimetableGridV2.kt:324-345` 只画星期与日期），
    /// 这是 iOS 端加的正向提示，见 `Theme.todayHighlight` 的说明。
    @ViewBuilder
    private func headerTodayColumnHighlight(leftWidth: CGFloat, dayWidth: CGFloat) -> some View {
        if let todayColumn, !visibleWeekdays.isEmpty {
            Rectangle()
                .fill(Theme.todayHighlight(dark: dark))
                .frame(width: dayWidth, height: Theme.headerHeight)
                .offset(x: leftWidth + dayCellLeft(index: todayColumn, dayWidth: dayWidth))
        }
    }

    /// 今天所在列顶部的一条细线。
    @ViewBuilder
    private func headerTodayColumnAccent(leftWidth: CGFloat, dayWidth: CGFloat) -> some View {
        if let todayColumn, !visibleWeekdays.isEmpty {
            Rectangle()
                .fill(Theme.todayAccent(dark: dark))
                .frame(width: dayWidth, height: 2)
                .offset(
                    x: leftWidth + dayCellLeft(index: todayColumn, dayWidth: dayWidth),
                    y: 0
                )
        }
    }

    /// 表头单元格（星期 + 日期），左列那格留空。
    private func headerCells(leftWidth: CGFloat, dayWidth: CGFloat) -> some View {
        ForEach(Array(visibleWeekdays.enumerated()), id: \.offset) { index, _ in
            weekdayHeaderCell(index: index, dayWidth: dayWidth)
                .frame(width: dayWidth, height: Theme.headerHeight)
                .offset(x: leftWidth + dayCellLeft(index: index, dayWidth: dayWidth))
        }
    }

    /// 表头单元格：`"周一"`（13sp Medium） + `prettyDate(date)`（11sp）。
    /// 对应 `TimetableGridV2.kt:324-345`。
    private func weekdayHeaderCell(index: Int, dayWidth: CGFloat) -> some View {
        let weekday = index < visibleWeekdays.count ? visibleWeekdays[index] : 0
        let rawDate = index < weekDates.count ? weekDates[index].date : ""
        let label = TimetableGrid.weekdayLabel(for: weekday)

        return VStack(spacing: 1) {
            Text("周\(label)")
                .font(Theme.weekdayFont)
                .foregroundColor(
                    todayColumn == index ? Theme.primaryInk(dark: dark) : Theme.secondaryInk(dark: dark)
                )
                .lineLimit(1)
            if !rawDate.isEmpty {
                Text(TimetableLayout.prettyDate(rawDate))
                    .font(Theme.weekdayDateFont)
                    .foregroundColor(Theme.secondaryInk(dark: dark))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 时间段面板

    private func periodBlock(block: ClosedRange<Int>, leftWidth: CGFloat, dayWidth: CGFloat) -> some View {
        // `blockRows = (end - start + 1).coerceAtLeast(1)`；`blockHeight = cellH * blockRows`。
        // 注意 `rows < 4` 时可能出现 `end < start`（例如 rows == 2 的下午面板
        // `5..2`），Kotlin 原文会画出一个高 1 行、没有课程的面板，
        // 见 `docs/recon/01-timetable-algorithms.md` §7.2 的说明与 §10 不确定项 5。
        let blockStart = block.lowerBound
        let blockEnd = block.upperBound
        let blockRows = max(blockEnd - blockStart + 1, 1)
        let panelHeight = cellHeight * CGFloat(blockRows)

        return HStack(spacing: 0) {
            periodLabels(blockStart: blockStart, blockEnd: blockEnd, width: leftWidth)
            dayColumns(blockStart: blockStart, blockEnd: blockEnd, dayWidth: dayWidth)
        }
        .frame(height: panelHeight)
        // 面板底色铺满「左列 + 天列」，与原版每个面板一整块
        // `RoundedCornerShape(PanelRadius)` + `panelColor` 一致。
        .background(
            RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                .fill(panelColor)
        )
        // ⚠️ 刻意**不**加 `.clipped()`：原版允许 `MinCardHeight` 抬升后的卡片溢出面板
        // （`docs/recon/01-timetable-algorithms.md` §8.3 最后一条），
        // 加裁剪会改变观感。
    }

    /// 左列节次：数字 13sp Bold + 起止时间 9sp，单元格高 = `cellH`。
    /// 对应 `TimetableGridV2.kt:510-531`（`offset(y = cellH * (p - startPeriod))`）。
    private func periodLabels(blockStart: Int, blockEnd: Int, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            ForEach(periodNumbers(start: blockStart, end: blockEnd), id: \.self) { period in
                let slot = slotText(for: period)
                VStack(spacing: 0) {
                    Text("\(period)")
                        .font(Theme.periodNumberFont)
                        .foregroundColor(Theme.primaryInk(dark: dark))
                        .lineLimit(1)
                    if !slot.start.isEmpty {
                        Text(slot.start)
                            .font(Theme.periodTimeFont)
                            .foregroundColor(Theme.secondaryInk(dark: dark))
                            .lineLimit(1)
                    }
                    if !slot.end.isEmpty {
                        Text(slot.end)
                            .font(Theme.periodTimeFont)
                            .foregroundColor(Theme.secondaryInk(dark: dark))
                            .lineLimit(1)
                    }
                }
                .frame(width: width, height: cellHeight)
                .offset(y: cellHeight * CGFloat(period - blockStart))
            }
        }
        .frame(width: width)
    }

    /// 每个面板内的所有天列。宽度不足时按 `dayWidth` 平分。
    private func dayColumns(blockStart: Int, blockEnd: Int, dayWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // 面板底色铺在**整个面板**（左列 + 天列）上，见 `periodBlock` 的
            // `.background(...)` —— 所以这里不再重复铺一层，否则两层 alpha 叠加
            // 会比原版更深（原版是 `Color.copy(alpha = a)` 一次铺满）。
            Color.clear

            // 今天整列高亮：先铺，再让卡片盖在上面。
            if let todayColumn {
                Rectangle()
                    .fill(Theme.todayHighlight(dark: dark))
                    .frame(width: dayWidth, height: cellHeight * CGFloat(max(blockEnd - blockStart + 1, 1)))
                    .offset(x: dayCellLeft(index: todayColumn, dayWidth: dayWidth))
            }

            ForEach(Array(visibleWeekdays.enumerated()), id: \.offset) { index, dayOfWeek in
                cardsForDay(
                    dayOfWeek: dayOfWeek,
                    blockStart: blockStart,
                    blockEnd: blockEnd,
                    dayWidth: dayWidth
                )
                .frame(width: dayWidth)
                .offset(x: dayCellLeft(index: index, dayWidth: dayWidth))
            }
        }
        .frame(width: dayWidth * CGFloat(max(visibleWeekdays.count, 1)), alignment: .topLeading)
    }

    /// 一天在某个面板里的全部卡片。纵向 `top` / `height` 全部来自 `TimetableLayout`。
    @ViewBuilder
    private func cardsForDay(
        dayOfWeek: Int,
        blockStart: Int,
        blockEnd: Int,
        dayWidth: CGFloat
    ) -> some View {
        // 逐字对应 `TimetableGridV2.kt:551`：
        // `mergeAdjacent(courses.filter { dayOfWeek == day && endPeriod >= start && startPeriod <= end })`。
        let dayCourses = TimetableLayout.coursesInBlock(
            courses,
            dayOfWeek: dayOfWeek,
            blockStartPeriod: blockStart,
            blockEndPeriod: blockEnd
        )

        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(dayCourses) { course in
                cardView(course: course, blockStart: blockStart, blockEnd: blockEnd, dayWidth: dayWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// 单张卡片：几何 → 样式 → 视图。
    private func cardView(
        course: Course,
        blockStart: Int,
        blockEnd: Int,
        dayWidth: CGFloat
    ) -> some View {
        // ⚠️ `previousBottom` 必须按「本面板内该天已排布的卡片顺序」累计。
        // `coursesInBlock` 已经做过 `mergeAdjacent`（内部按 startPeriod 升序 + 稳定），
        // 所以这里重新按同样顺序遍历一次即可复现原版的逐张累计。
        let geometry = cardGeometry(course: course, blockStart: blockStart, blockEnd: blockEnd)
        let occurs = occursThisWeek[course.id] ?? true
        let style = CourseCardStyle.resolve(
            course: course,
            dark: dark,
            optimize: optimize,
            occursThisWeek: occurs,
            settings: settings,
            cardHeight: geometry.height
        )
        let inset = Theme.cardHorizontalInset
        let cardWidth = max(dayWidth - inset * 2, 1)

        return CourseCard(course: course, style: style, height: geometry.height) {
            onTapCard(
                CourseCardTap(
                    course: course,
                    frameInOverlay: cardFrames[course.id]
                        ?? CGRect(x: 0, y: 0, width: cardWidth, height: geometry.height),
                    occursThisWeek: occurs
                )
            )
        }
        .frame(width: cardWidth)
        .background(
            // 只测量，不参与布局。坐标系用浮层坐标系，供展开动画做起点。
            GeometryReader { cardProxy in
                let frame = cardProxy.frame(in: .named(overlaySpaceName))
                Color.clear
                    .onAppear { cardFrames[course.id] = frame }
                    .onChange(of: frame) { _, newValue in cardFrames[course.id] = newValue }
            }
        )
        .offset(x: inset, y: geometry.top)
    }

    /// 一张卡片在本面板内的 `top` / `height`。
    ///
    /// 这里必须把同一列的卡片按原版顺序遍历，才能拿到正确的 `previousBottom`
    /// （原版是 `forEach` 里逐张累计，见 `TimetableGridV2.kt:550-566`）。
    private func cardGeometry(
        course: Course,
        blockStart: Int,
        blockEnd: Int
    ) -> (top: CGFloat, height: CGFloat) {
        let peers = TimetableLayout.coursesInBlock(
            courses,
            dayOfWeek: course.dayOfWeek,
            blockStartPeriod: blockStart,
            blockEndPeriod: blockEnd
        )

        var previousBottom: Double = 0
        var result: (top: Double, height: Double) = (0, Double(TimetableLayout.minCardHeight))
        for peer in peers {
            let geometry = TimetableLayout.cardVerticalGeometry(
                card: peer,
                blockStartPeriod: blockStart,
                blockEndPeriod: blockEnd,
                cellHeight: Double(cellHeight),
                previousBottom: previousBottom
            )
            previousBottom = geometry.top + geometry.height
            if peer.id == course.id {
                result = geometry
                break
            }
        }
        return (CGFloat(result.top), CGFloat(result.height))
    }

    // MARK: - 小工具

    /// 第 `index` 天的列在「天列区域」里的左偏移。
    private func dayCellLeft(index: Int, dayWidth: CGFloat) -> CGFloat {
        CGFloat(index) * dayWidth
    }

    private func periodNumbers(start: Int, end: Int) -> [Int] {
        guard end >= start else { return [] }
        return Array(start...end)
    }

    /// 左列显示的起止时间：原版用 `timeSlots` 里第 `p-1` 项的
    /// `substringBefore("-")` / `substringAfter("-")`（`TimetableGridV2.kt:510-531`）。
    /// `TimetableStore.timeSlots` 就是同一份 `["08:10-08:55", …]`。
    private func slotText(for period: Int) -> (start: String, end: String) {
        let slots = store.timeSlots
        let index = period - 1
        guard index >= 0, index < slots.count else { return ("", "") }
        let slot = slots[index]
        guard let dash = slot.range(of: "-") else {
            let whole = slot.trimmingCharacters(in: .whitespacesAndNewlines)
            return (whole, "")
        }
        let start = String(slot[slot.startIndex..<dash.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let end = String(slot[dash.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (start, end)
    }

    /// 星期编号 → 单字标签。与 `WeekLogic.weekDates` 的 `label`（"一"…"日"）一致。
    static func weekdayLabel(for weekday: Int) -> String {
        switch weekday {
        case 1: return "一"
        case 2: return "二"
        case 3: return "三"
        case 4: return "四"
        case 5: return "五"
        case 6: return "六"
        case 7: return "日"
        default: return "?"
        }
    }
}

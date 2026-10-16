import SwiftUI
import KebiaoCore

/// 周次横幅：当前周徽标 + 本周日期区间 + 上一周 / 下一周 / 回到本周。
///
/// 数据与动作全部来自 `TimetableStore` 的真实 API：
/// - 徽标：`TimetableStore.weekNumberDisplay` 由 `WeekLogic.weekNumberDisplay(_:)`
///   给出，形如 `"第N周"`（证据：`WeekLogic.swift:212`，对应
///   `TimetableScreenKt.java:301-325` 的 `getWeekNumberDisplay`）；
/// - 日期：`TimetableStore.weekDates`（`WeekLogic.weekDates(weekOffset:showSaturday:showSunday:now:calendar:)`，
///   `WeekLogic.swift:232`），每项是 `WeekDate(date: "5/2", label: "一")`；
/// - 上一周 / 下一周：`shiftWeek(by:)`；回到本周：`resetWeekOffset()`。
///   两者都只改 `weekOffset`（`TimetableStore.swift:304-313`），
///   `displayedWeek = max(currentWeek + weekOffset, 1)`（`:148-150`），
///   课程过滤走 `coursesForDisplayedWeek()`（`:204`），视图不自己算周次。
///
/// 原版对应的 UI 是 `TimetableScreenKt` 里的周次徽标（`TimetableGridV2.kt:296-322`
/// 给了徽标的字号与圆角：数字 19sp Bold、「第」「周」9sp、圆角 10dp）。
struct WeekSwitcher: View {

    @EnvironmentObject private var environment: AppEnvironment

    /// 「回到本周」是否可见。当前周也显示，但置灰不可点 —— 位置固定，
    /// 避免用户翻到第 20 周时按钮突然多出来导致整行跳动。
    var showsBackToCurrentWeek: Bool = true

    private var store: TimetableStore { environment.store }
    private var dark: Bool { store.uiFlags.isDarkTheme }

    var body: some View {
        HStack(spacing: 10) {
            weekBadge

            VStack(alignment: .leading, spacing: 1) {
                Text(dateRangeText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.primaryInk(dark: dark))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(secondaryText)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.secondaryInk(dark: dark))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                stepButton(systemImage: "chevron.left", label: "上一周") {
                    store.shiftWeek(by: -1)
                }
                if showsBackToCurrentWeek {
                    backToCurrentWeekButton
                }
                stepButton(systemImage: "chevron.right", label: "下一周") {
                    store.shiftWeek(by: 1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.panelColor(dark: dark, hasCustomBackground: store.settings.backgroundImageUri != nil))
        )
        .animation(.easeInOut(duration: 0.22), value: store.displayedWeek)
    }

    // MARK: - 周徽标

    /// `"第" 9sp + 数字 19sp Bold + "周" 9sp`，圆角 10，底为主色调的浅色。
    /// 证据：`TimetableGridV2.kt:296-322`。
    private var weekBadge: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("第")
                .font(Theme.weekBadgeAffixFont)
            Text("\(store.displayedWeek)")
                .font(Theme.weekBadgeNumberFont)
                .monospacedDigit()
            Text("周")
                .font(Theme.weekBadgeAffixFont)
        }
        .foregroundColor(Theme.primaryInk(dark: dark))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: Theme.weekBadgeRadius, style: .continuous)
                .fill(Theme.todayHighlight(dark: dark))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(store.weekNumberText)
    }

    // MARK: - 按钮

    private func stepButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.primaryInk(dark: dark))
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(Theme.todayHighlight(dark: dark))
                )
        }
        .accessibilityLabel(label)
    }

    private var backToCurrentWeekButton: some View {
        let isCurrent = store.weekOffset == 0
        return Button {
            store.resetWeekOffset()
        } label: {
            Text("回到本周")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isCurrent ? Theme.secondaryInk(dark: dark) : Theme.primaryInk(dark: dark))
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Theme.todayHighlight(dark: dark).opacity(isCurrent ? 0.4 : 1))
                )
        }
        .disabled(isCurrent)
        .accessibilityLabel("回到本周")
    }

    // MARK: - 文本

    /// `"05-02 ~ 05-08"`。日期串走 `TimetableLayout.prettyDate`（`"5/2"` → `"05-02"`），
    /// 与原版表头用的是同一个格式化函数（`TimetableGridV2.kt:754-761`）。
    private var dateRangeText: String {
        let dates = store.weekDates.map { TimetableLayout.prettyDate($0.date) }
        guard let first = dates.first else { return "—" }
        guard let last = dates.last, dates.count > 1 else { return first }
        return "\(first) ~ \(last)"
    }

    /// 副标题：本周 / 非本周 + 课程条数，给「现在看的是哪一周」一个即时反馈。
    private var secondaryText: String {
        let count = store.coursesForDisplayedWeek().count
        if store.weekOffset == 0 {
            return "本周 · \(count) 门课"
        }
        let direction = store.displayedWeek < store.currentWeek ? "早于本周" : "晚于本周"
        return "\(direction)（本周第 \(store.currentWeek) 周） · \(count) 门课"
    }
}

import Foundation

/// 日历/日期工具：与原版 Android 的 `java.util.Calendar` 用法对齐。
public extension Calendar {

    /// 与原版 `Calendar.getInstance()` 在中文环境下等效的日历。
    ///
    /// - `firstWeekday = 2`（周一）。原版 `getWeekDates` 用
    ///   `calendar.set(Calendar.DAY_OF_WEEK, Calendar.MONDAY)` 定位「本周周一」，
    ///   而 Java 的 `set(DAY_OF_WEEK, …)` 解释为**当前 week-of-year 里的那个星期几**——
    ///   所以结果依赖 `firstDayOfWeek`。原版界面是周一开头（`getWeekDates` 返回
    ///   一/二/三/四/五[/六][/日]，且 `dayIndexOf` 把「一」映射为 1），
    ///   故这里取周一为一周之首。
    ///
    ///   ⚠️ 待确认：Java/Android 对 `zh-CN` 的默认 `firstDayOfWeek` 存在版本差异，
    ///   若为 SUNDAY，则在**周日**当天打开 App 时「本周周一」会指向次日（下周一）。
    ///   详见 `docs/recon/algorithms.md` 的不确定项。
    public static var app: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
}

/// 一周里的一天：格式化后的日期 + 星期标签。
///
/// 对应原版 `getWeekDates` 返回的 `List<Pair<String, String>>`，
/// 其中 `first` 是 `SimpleDateFormat("M/d")` 的结果，`second` 是「一」…「日」。
public struct WeekDate: Equatable, Hashable, Sendable {
    /// 形如 "5/2"（月/日，无前导零）——与原版 `"M/d"` 格式一致。
    public let date: String
    /// 星期标签："一"…"日"。
    public let label: String

    public init(date: String, label: String) {
        self.date = date
        self.label = label
    }
}

/// 周次相关算法。
///
/// 证据（全部来自反编译与 smali）：
/// - `上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/ui/TimetableScreenKt.java:301-325`
///   （`getCurrentTeachingWeek` / `getWeekNumberDisplay` / `isOddWeek`）
/// - `:258-279`（`getWeekDates`）、`:281-299`（`parseDate`）
/// - `:366-442`（`courseOccursInWeek`）
/// - smali 权威版本：`apk_work/proj_dec/smali_classes3/kebiaocom/example/ui/TimetableScreenKt.smali`
///   （`courseOccursInWeek` 在 :9137，`getCurrentTeachingWeek` 在 :9931，
///   `getWeekDates` 在 :10364，`isOddWeek` 在 :10580）
public enum WeekLogic {

    // MARK: - 单双周

    /// `isOddWeek(i) = i % 2 == 1`（`TimetableScreenKt.java:323-325`）。
    ///
    /// 注意负数：Kotlin/Java 的 `%` 对负数返回负值（`-3 % 2 == -1`），
    /// 但 `week` 在调用点始终为正，这里不做额外处理，保持等价。
    public static func isOddWeek(_ week: Int) -> Bool {
        week % 2 == 1
    }

    // MARK: - 课程是否在某周出现

    /// 判断课程 `course` 在第 `week` 教学周是否上课。
    ///
    /// 逐条对应 `TimetableScreenKt.java:366-442`：
    /// 1. `week <= 0` → 不上；
    /// 2. `week` 不在 `[startWeek, endWeek]` 闭区间内 → 不上；
    /// 3. `isOdd == 1` 且该周是双周 → 不上；`isOdd == 2` 且该周是单周 → 不上；
    /// 4. `weekRange` 为空白 → 每周都上；
    /// 5. 清洗：`" "`→`""`，`"，"/"、"/"；"/";"`→`","`；
    /// 6. 清洗后不含 ASCII 数字（`Regex("\\d")`）→ 每周都上；
    /// 7. 记录 `hasOdd = contains("单")`、`hasEven = contains("双")`；
    /// 8. 去掉 `"周次" / "第" / "周" / "(" / ")" / "单" / "双"`，按 `","` 切分、trim、丢空串；
    /// 9. 结果为空 → 每周都上；
    /// 10. 逐段判断：形如 `a-b` 的区间段、或等于该周的单数字段，命中后：
    ///     `hasOdd` → 返回该周是否为单周；否则 `hasEven` → 返回该周是否为双周；
    ///     两者都没有 → 直接返回 true。
    ///
    /// - Important: **第 10 步已由 smali 逐指令确证**（jadx 把它渲染成了空 body：
    ///   `TimetableScreenKt.java:431-437` 的 `if (!contains$default) { }`，读 Java 会
    ///   得出相反结论）。权威指令序列在
    ///   `apk_work/proj_dec/smali_classes3/kebiaocom/example/ui/TimetableScreenKt.smali:9676-9703`：
    ///   ```
    ///   :goto_4
    ///   if-eqz v2, :cond_e        # v2 = contains("单")
    ///   isOddWeek(week); return               # hasOdd  → isOddWeek(week)
    ///   :cond_e
    ///   if-eqz v5, :cond_f        # v5 = contains("双")
    ///   isOddWeek(week); xor-int/2addr v0, v4; return   # hasEven → !isOddWeek(week)
    ///   :cond_f
    ///   return v4                 # 两者都没有 → true
    ///   ```
    ///   区间段（`:9660 goto :goto_4`）与单数字段（`:9674` 落入 `:goto_4`）**共用**同一段
    ///   判定，所以 `"1-16"`、`"3-5"` 这类不含「单/双」字样的区间是**每个匹配周都上课**，
    ///   不是「只在单周」。若按 jadx 的字面读法实现，教务导入的课表会在双周整片消失。
    public static func courseOccursInWeek(_ course: Course, week: Int) -> Bool {
        guard week > 0 else { return false }

        let startWeek = course.startWeek
        guard week <= course.endWeek, startWeek <= week else { return false }

        switch course.parity {
        case .odd:
            if !isOddWeek(week) { return false }
        case .even:
            if isOddWeek(week) { return false }
        case .every:
            break
        }

        if course.weekRange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        var cleaned = course.weekRange
        for (from, to) in [(" ", ""), ("，", ","), ("、", ","), ("；", ","), (";", ",")] {
            cleaned = cleaned.replacingOccurrences(of: from, with: to)
        }

        // Kotlin 的 Regex("\\d") 只匹配 ASCII 0-9。
        guard cleaned.range(of: "[0-9]", options: .regularExpression) != nil else {
            return true
        }

        let hasOdd = cleaned.contains("单")
        let hasEven = cleaned.contains("双")

        var body = cleaned
        for token in ["周次", "第", "周", "(", ")", "单", "双"] {
            body = body.replacingOccurrences(of: token, with: "")
        }

        let parts = body
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else { return true }

        for part in parts {
            if part.contains("-") {
                let bounds = part.components(separatedBy: "-")
                // smali `:9596-9652`：`split("-")` 后要求 size == 2，再对两个**未经 trim**
                // 的片段调用 `toIntOrNull`（Kotlin 的 `toIntOrNull` 不容忍空白），
                // 任一步失败就 `goto :goto_3` 跳过该片段并继续循环。
                guard bounds.count == 2,
                      let lower = Int(bounds[0]),
                      let upper = Int(bounds[1])
                else { continue }
                if lower <= week, week <= upper {
                    return verdictInMatchedRange(week: week, hasOdd: hasOdd, hasEven: hasEven)
                }
            } else if let single = Int(part), week == single {
                // smali `:9663-9676`：单数字段与区间段**共用** `:goto_4` 的判定。
                return verdictInMatchedRange(week: week, hasOdd: hasOdd, hasEven: hasEven)
            }
        }

        return false
    }

    /// 命中某个周次描述后的判定。
    ///
    /// 权威依据：`TimetableScreenKt.smali:9676-9703`（见 `courseOccursInWeek` 的文档）。
    /// 注意判定顺序是**先看「单」**：没有「单」也没有「双」时返回 `true`（每周都上）。
    private static func verdictInMatchedRange(week: Int, hasOdd: Bool, hasEven: Bool) -> Bool {
        if hasOdd { return isOddWeek(week) }
        if hasEven { return !isOddWeek(week) }
        return true
    }

    // MARK: - 当前教学周

    /// 当前是第几教学周。
    ///
    /// 对应 `TimetableScreenKt.java:301-317`：
    /// ```
    /// date = trim(firstWeekStartDate)
    /// if (date.isEmpty() || parseDate(date) == null) return 1
    /// days = (int)((今天零点毫秒 - 开学日零点毫秒) / 86_400_000)
    /// week = if (days >= 0) days / 7 + 1 else 1
    /// return week.coerceIn(1, max(semesterWeeks, 1))
    /// ```
    /// Java 的 `/` 对 long 是**向零截断**，Swift 的 `Int(Double)` 同样是向零截断，
    /// 二者在正负区间都一致。
    public static func teachingWeek(
        firstWeekStartDate: String?,
        semesterWeeks: Int,
        now: Date = Date(),
        calendar: Calendar = .app
    ) -> Int {
        let raw = (firstWeekStartDate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let semesterStart = parseDate(raw, calendar: calendar) else {
            return 1
        }

        let today = calendar.startOfDay(for: now)
        let millisecondsPerDay: Double = 86_400_000
        let elapsed = today.timeIntervalSince1970 * 1000 - semesterStart.timeIntervalSince1970 * 1000
        let days = Int(elapsed / millisecondsPerDay)

        let week = days >= 0 ? (days / 7) + 1 : 1
        return min(max(week, 1), max(semesterWeeks, 1))
    }

    /// `第N周`（`TimetableScreenKt.java:319-321`，`N` 下限为 1）。
    public static func weekNumberDisplay(_ week: Int) -> String {
        "第\(max(week, 1))周"
    }

    // MARK: - 一周的日期

    /// 一周 7 天（或 5/6 天）的日期标签。
    ///
    /// 对应 `TimetableScreenKt.java:258-279`：
    /// ```
    /// cal = now
    /// cal.set(DAY_OF_WEEK, MONDAY)     // 本周周一
    /// cal.add(WEEK_OF_YEAR, weekOffset)
    /// 对 i in 0..6：若 i 在显示列表里，加入 (format("M/d"), "一二三四五六日"[i])；cal.add(DATE, 1)
    /// ```
    /// 显示列表 = `[0,1,2,3,4]`，`showSaturday` 追加 `5`，`showSunday` 追加 `6`。
    ///
    /// - Parameter weekOffset: 相对「现在所在周」的偏移，0 = 本周，-1 = 上周。
    ///   原版 `TimetableViewModel._currentWeekOffset` 就是这个偏移
    ///   （`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/ui/TimetableViewModel.java:33`）。
    public static func weekDates(
        weekOffset: Int,
        showSaturday: Bool,
        showSunday: Bool,
        now: Date = Date(),
        calendar: Calendar = .app
    ) -> [WeekDate] {
        var calendar = calendar
        let labels = ["一", "二", "三", "四", "五", "六", "日"]

        var visibleIndices = [0, 1, 2, 3, 4]
        if showSaturday { visibleIndices.append(5) }
        if showSunday { visibleIndices.append(6) }

        guard let monday = mondayOfWeek(containing: now, calendar: calendar) else { return [] }
        guard let shifted = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: monday) else {
            return []
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M/d"

        var result: [WeekDate] = []
        var day = shifted
        for index in 0..<7 {
            if visibleIndices.contains(index) {
                result.append(WeekDate(date: formatter.string(from: day), label: labels[index]))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    // MARK: - 私有工具

    /// 本周周一（零点）。等价于 `Calendar.set(DAY_OF_WEEK, MONDAY)`。
    static func mondayOfWeek(containing date: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents(
            [.yearForWeekOfYear, .weekOfYear],
            from: date
        )
        components.weekday = 2 // Gregorian: 1 = 周日, 2 = 周一
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.nanosecond = 0
        return calendar.date(from: components)
    }

    /// `"yyyy-MM-dd"` 的 `DateFormatter`，与原版 `SimpleDateFormat("yyyy-MM-dd")`
    /// 对齐：`en_US_POSIX` 固定格式、时区跟随日历、`isLenient = false`
    /// （`TimetableScreenKt.java:281-299`）。
    static func dateFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    /// `Date` → `"yyyy-MM-dd"`。设置页写回 `firstWeekStartDate` 时用，
    /// 与 `parseDate` 共用同一个格式定义，避免两处写法漂移。
    public static func formatDate(_ date: Date, calendar: Calendar = .app) -> String {
        dateFormatter(calendar: calendar).string(from: date)
    }

    /// `"yyyy-MM-dd"` → 当天零点；格式不合法（例如 `2026-02-30`）时返回 nil。
    /// 对应 `TimetableScreenKt.java:281-299` 的 `parseDate`。
    public static func parseDate(_ value: String, calendar: Calendar = .app) -> Date? {
        guard let parsed = dateFormatter(calendar: calendar).date(from: value) else { return nil }

        // ⚠️ Foundation 的 `DateFormatter` 比 Java 的 `SimpleDateFormat` 宽松：
        // 分隔符对不上也会解析成功（`"2026/09/01"` 会被当成 `2026-09-01`），
        // 越界字段的处理也不同。Java 侧是
        // `SimpleDateFormat("yyyy-MM-dd").setLenient(false)`（`TimetableScreenKt.java:281-285`）：
        // 分隔符要逐字匹配、字段要落在合法区间，任一条不满足就抛 `ParseException`，
        // 被 `:296-298` 的 catch 吞成 `null` → `getCurrentTeachingWeek` 返回第 1 周。
        // 这里把解析结果反查一遍：文本按 `-` 切出的三个数字必须与解析出的年月日逐项相等，
        // 任一项对不上就按「解析失败」处理（等价于 Java 的 catch 分支）。
        // 注意**不**要求补零（`"2026-9-1"` 照样通过），因为 Java 的 `MM`/`dd` 也接受 1 位数字。
        let numbers = value.components(separatedBy: "-").compactMap { Int($0) }
        let components = calendar.dateComponents([.year, .month, .day], from: parsed)
        guard numbers.count == 3,
              numbers[0] == components.year,
              numbers[1] == components.month,
              numbers[2] == components.day
        else { return nil }

        return calendar.startOfDay(for: parsed)
    }
}

import Foundation

/// 与 Android 端 `kebiaocom.example.data.AppSettings` 一一对应（27 个属性）。
///
/// 证据：
/// - `上课早枝道-源码-1.11.5/app/src/main/kotlin/kebiaocom/example/data/AppSettings.kt:14-48`
/// - 反编译 Java：`.../data/AppSettings.java`（`@Metadata` 带 data class 标记，
///   合成构造函数里 27 个参数全有默认值）
///
/// ⚠️ 默认值必须逐字保留：Android 端读取旧配置时，缺键会回落到这些默认值；
/// iOS 端若默认值不同，同一份配置在两平台读出来的行为就会分叉。
///
/// 可空性依据：原版构造函数里 `firstPeriodStartTime` / `selectedTimetableProfileId` /
/// `classReminderMode` 有 `Intrinsics.checkNotNullParameter`，故非空；
/// 其余 String 参数为可空。Swift 侧按同一可空性建模。
public struct AppSettings: Codable, Equatable, Sendable {
    public var id: Int
    public var backgroundImageUri: String?
    public var periodsPerDay: Int
    public var periodDurationMinutes: Int
    public var breakDurationMinutes: Int
    public var firstPeriodStartTime: String
    public var firstWeekStartDate: String?
    public var semesterWeeks: Int
    public var showSaturday: Bool
    public var showSunday: Bool
    public var showNonCurrentWeekCourses: Bool
    public var showWeekSlider: Bool
    /// ⚠️ 1.11.5 起该功能已在设置页下架，Android 端 `getReverseMainText()` 被改成恒返回
    /// `false`（`apk_work/proj_dec/smali_classes3/kebiaocom/example/data/AppSettings.smali`
    /// 的 `getReverseMainText()` 方法体为 `const/4 v0, 0x0; return v0`）。
    /// 字段本身仍参与 equals/hashCode/copy，所以为了能读写旧配置必须保留；
    /// 但**取值一律以 `effectiveReverseMainText` 为准**。
    public var reverseMainText: Bool
    public var autoCheckUpdate: Bool
    public var autoSyncTimetableFromJwxt: Bool
    public var selectedTimetableProfileId: String
    public var classReminderEnabled: Bool
    /// 提醒强度："weak"（普通通知）/ "strong"（全屏强提醒）。
    /// iOS 无全屏强提醒等价物，见 `docs/recon/03-reminder-and-refresh.md` 里的
    /// Android→iOS 能力对照表（A1–A15）。
    public var classReminderMode: String
    public var classReminderMinutes: Int
    public var nonCurrentWeekCourseAlphaPercent: Int
    public var courseCardAlphaPercent: Int
    public var courseFrostedIntensityPercent: Int
    public var courseCellHeightDp: Int
    public var courseTextSizeSp: Int
    public var showCourseTime: Bool
    public var showCourseLocation: Bool
    public var showCourseTeacher: Bool

    public init(
        id: Int = 1,
        backgroundImageUri: String? = nil,
        periodsPerDay: Int = 12,
        periodDurationMinutes: Int = 45,
        breakDurationMinutes: Int = 10,
        firstPeriodStartTime: String = "08:00",
        firstWeekStartDate: String? = nil,
        semesterWeeks: Int = 20,
        showSaturday: Bool = false,
        showSunday: Bool = false,
        showNonCurrentWeekCourses: Bool = false,
        showWeekSlider: Bool = false,
        reverseMainText: Bool = false,
        autoCheckUpdate: Bool = true,
        autoSyncTimetableFromJwxt: Bool = false,
        selectedTimetableProfileId: String = "default",
        classReminderEnabled: Bool = false,
        classReminderMode: String = "weak",
        classReminderMinutes: Int = 10,
        nonCurrentWeekCourseAlphaPercent: Int = 45,
        courseCardAlphaPercent: Int = 100,
        courseFrostedIntensityPercent: Int = 100,
        courseCellHeightDp: Int = 69,
        courseTextSizeSp: Int = 10,
        showCourseTime: Bool = true,
        showCourseLocation: Bool = true,
        showCourseTeacher: Bool = true
    ) {
        self.id = id
        self.backgroundImageUri = backgroundImageUri
        self.periodsPerDay = periodsPerDay
        self.periodDurationMinutes = periodDurationMinutes
        self.breakDurationMinutes = breakDurationMinutes
        self.firstPeriodStartTime = firstPeriodStartTime
        self.firstWeekStartDate = firstWeekStartDate
        self.semesterWeeks = semesterWeeks
        self.showSaturday = showSaturday
        self.showSunday = showSunday
        self.showNonCurrentWeekCourses = showNonCurrentWeekCourses
        self.showWeekSlider = showWeekSlider
        self.reverseMainText = reverseMainText
        self.autoCheckUpdate = autoCheckUpdate
        self.autoSyncTimetableFromJwxt = autoSyncTimetableFromJwxt
        self.selectedTimetableProfileId = selectedTimetableProfileId
        self.classReminderEnabled = classReminderEnabled
        self.classReminderMode = classReminderMode
        self.classReminderMinutes = classReminderMinutes
        self.nonCurrentWeekCourseAlphaPercent = nonCurrentWeekCourseAlphaPercent
        self.courseCardAlphaPercent = courseCardAlphaPercent
        self.courseFrostedIntensityPercent = courseFrostedIntensityPercent
        self.courseCellHeightDp = courseCellHeightDp
        self.courseTextSizeSp = courseTextSizeSp
        self.showCourseTime = showCourseTime
        self.showCourseLocation = showCourseLocation
        self.showCourseTeacher = showCourseTeacher
    }

    /// 与 Kotlin `AppSettings()` 无参构造等价的出厂设置。
    public static let `default` = AppSettings()

    /// 原版 1.11.5 的实际生效值：永远是 false（功能已下架）。
    public var effectiveReverseMainText: Bool { false }
}

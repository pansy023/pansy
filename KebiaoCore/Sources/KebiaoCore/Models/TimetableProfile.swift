import Foundation

/// 与 Android 端 `kebiaocom.example.data.TimetableProfile` 一一对应。
///
/// 证据：`上课早枝道-源码-1.11.5/app/src/main/kotlin/kebiaocom/example/data/TimetableProfile.kt:5-10`
/// （四个属性均无默认值；原版用 `java.util.List`，iOS 侧用 Swift 数组）。
///
/// 一套「作息时间方案」：不同教学楼/不同季节的上下课时间不同，原版允许存多套，
/// 由 `AppSettings.selectedTimetableProfileId` 选中，默认档案 id 为 "default"。
public struct TimetableProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// 一天多少节。
    public var periodsPerDay: Int
    /// 每节的起止时间。
    public var periodTimes: [PeriodTime]

    public init(id: String, name: String, periodsPerDay: Int, periodTimes: [PeriodTime]) {
        self.id = id
        self.name = name
        self.periodsPerDay = periodsPerDay
        self.periodTimes = periodTimes
    }
}

public extension TimetableProfile {
    /// 默认档案的 id —— 与 `AppSettings.selectedTimetableProfileId` 的默认值一致。
    static let defaultId = "default"

    /// 出厂内置的作息方案：**10 节，第一节 08:10**。
    ///
    /// 证据：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/data/LocalStorage.java:263-278`
    /// 的 `defaultTimetableProfiles()`，逐对时间原样照抄：
    /// `("08:10","08:55") ("09:05","09:50") ("10:20","11:05") ("11:15","12:00")
    ///  ("14:10","14:55") ("15:05","15:50") ("16:20","17:05") ("17:15","18:00")
    ///  ("19:30","20:15") ("20:25","21:10")`。
    ///
    /// ⚠️ 注意这套默认时间**与 `AppSettings` 的默认值不是一回事**：
    /// `AppSettings.periodsPerDay` 默认 12、`firstPeriodStartTime` 默认 "08:00"，
    /// 那套只在用户把 profile 的 `periodTimes` 清空后才会用到
    /// （见 `docs/recon/01-timetable-algorithms.md` §9.3）。默认情况下生效的是本方案。
    static let defaultProfile = TimetableProfile(
        id: defaultId,
        name: "默认",
        periodsPerDay: 10,
        periodTimes: [
            PeriodTime(index: 1, start: "08:10", end: "08:55"),
            PeriodTime(index: 2, start: "09:05", end: "09:50"),
            PeriodTime(index: 3, start: "10:20", end: "11:05"),
            PeriodTime(index: 4, start: "11:15", end: "12:00"),
            PeriodTime(index: 5, start: "14:10", end: "14:55"),
            PeriodTime(index: 6, start: "15:05", end: "15:50"),
            PeriodTime(index: 7, start: "16:20", end: "17:05"),
            PeriodTime(index: 8, start: "17:15", end: "18:00"),
            PeriodTime(index: 9, start: "19:30", end: "20:15"),
            PeriodTime(index: 10, start: "20:25", end: "21:10")
        ]
    )
}

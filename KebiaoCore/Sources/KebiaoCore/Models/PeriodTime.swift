import Foundation

/// 与 Android 端 `kebiaocom.example.data.PeriodTime` 一一对应。
///
/// 证据：`上课早枝道-源码-1.11.5/app/src/main/kotlin/kebiaocom/example/data/PeriodTime.kt:3-7`
/// （三个属性均无默认值）。
public struct PeriodTime: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// 节次序号，1 起数。
    public var index: Int
    /// 该节次开始时间，形如 "08:00"。
    public var start: String
    /// 该节次结束时间，形如 "08:45"。
    public var end: String

    public var id: Int { index }

    public init(index: Int, start: String, end: String) {
        self.index = index
        self.start = start
        self.end = end
    }
}

public extension PeriodTime {
    /// 供 `TimetableLayout.buildTimeRange` 使用的 "08:00-08:45" 形式，
    /// 与 Android 端 `timeSlots` 列表里每一项的格式一致。
    var slot: String { "\(start)-\(end)" }
}

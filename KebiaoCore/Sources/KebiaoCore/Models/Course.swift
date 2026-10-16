import Foundation

/// 与 Android 端 `kebiaocom.example.data.Course` 一一对应。
///
/// 证据：
/// - `上课早枝道-源码-1.11.5/app/src/main/kotlin/kebiaocom/example/data/Course.kt:3-16`
/// - 反编译 Java：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/data/Course.java`
/// - smali：`apk_work/proj_dec/smali_classes3/kebiaocom/example/data/Course.smali`
///
/// 字段名、顺序、默认值均**不得**改动：本地 JSON 的键名由 Kotlin 属性名生成，
/// 改动会导致无法读取 Android 端已经保存的数据（数据兼容性要求见 m03200 第七节）。
///
/// 原版字段属性：
/// - `name` / `teacher` / `location` / `dayOfWeek` / `startPeriod` / `endPeriod` /
///   `color` / `weekRange` 无默认值，必填；
/// - `id = 0`、`startWeek = 1`、`endWeek = 20`、`isOdd = 0` 有默认值。
public struct Course: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// 课程主键。本地新增课程时由存储层分配。
    public var id: Int
    /// 课程名称（如「高等数学」）。
    public var name: String
    /// 教师姓名。
    public var teacher: String
    /// 上课地点，形如「教学楼A 101」——楼名与教室用**一个空格**分隔，
    /// 见 `TimetableGridV2.kt:733-741` 的 `buildingOf` / `roomOf`。
    public var location: String
    /// 星期，1 = 周一 … 7 = 周日（见 `dayIndexOf`，`TimetableGridV2.kt:743-752`）。
    public var dayOfWeek: Int
    /// 起始节次，1 起数。
    public var startPeriod: Int
    /// 结束节次，1 起数，含端点。
    public var endPeriod: Int
    /// 课程自定义颜色；原版在未开启「优化模式」时改用按课程名 hash 取的莫兰迪色，
    /// 该字段因此常常为 0（见 `MorandiPalette`）。
    public var color: Int
    /// 周次描述字符串，原版教务系统导入后形如「1-16」「1-16周」「1-16(单)」等，
    /// 由 `WeekLogic.courseOccursInWeek` 解析。空串表示全周次。
    public var weekRange: String
    /// 起始周。
    public var startWeek: Int
    /// 结束周。
    public var endWeek: Int
    /// 单双周：0 = 每周，1 = 单周，2 = 双周。
    public var isOdd: Int

    public init(
        id: Int = 0,
        name: String,
        teacher: String,
        location: String,
        dayOfWeek: Int,
        startPeriod: Int,
        endPeriod: Int,
        color: Int,
        weekRange: String,
        startWeek: Int = 1,
        endWeek: Int = 20,
        isOdd: Int = 0
    ) {
        self.id = id
        self.name = name
        self.teacher = teacher
        self.location = location
        self.dayOfWeek = dayOfWeek
        self.startPeriod = startPeriod
        self.endPeriod = endPeriod
        self.color = color
        self.weekRange = weekRange
        self.startWeek = startWeek
        self.endWeek = endWeek
        self.isOdd = isOdd
    }
}

// MARK: - 语义化访问

public extension Course {
    /// `isOdd` 的三种取值。原版直接用 Int 比较（见 `TimetableScreenKt.smali:9137`
    /// 的 `if-eqz/if-eq` 分支），这里给出等价枚举以便阅读。
    enum WeekParity: Int, Sendable {
        /// 每周都上。
        case every = 0
        /// 单周（第 1、3、5… 周）。判定：`week % 2 == 1`。
        case odd = 1
        /// 双周（第 2、4、6… 周）。
        case even = 2
    }

    var parity: WeekParity { WeekParity(rawValue: isOdd) ?? .every }

    /// 楼名：地点里第一个空格之前的部分；没有空格时返回整个字符串。
    /// 对应 `TimetableGridV2.kt:733-736` 的 `buildingOf`。
    var building: String {
        guard let index = location.firstIndex(of: " ") else { return location }
        return String(location[location.startIndex..<index])
    }

    /// 教室：地点里第一个空格之后的部分，并去掉首尾空白；没有空格时返回空串。
    /// 对应 `TimetableGridV2.kt:738-741` 的 `roomOf`。
    var room: String {
        guard let index = location.firstIndex(of: " ") else { return "" }
        return String(location[location.index(after: index)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

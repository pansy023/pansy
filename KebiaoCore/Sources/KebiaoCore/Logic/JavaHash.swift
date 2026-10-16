import Foundation

/// Java `String.hashCode()` 的等价实现。
///
/// 为什么必须手写：原版课程卡片颜色由
/// `paletteColor(name) = MorandiPalette[(name.hashCode() and 0x7fffffff) % 12]`
/// 决定（`apk_work/kb/src2/TimetableGridV2.kt:765-768`，同款逻辑也在
/// `apk_work/proj_dec/smali_classes3/kebiaocom/example/ui/TimetableGridV2Kt.smali`）。
/// Swift 的 `Hasher` / `hashValue` 算法与 Java 完全不同，直接用会让同一门课
/// 在 Android 和 iOS 上显示成不同颜色。
///
/// Java 的算法（`java.lang.String.hashCode` 规范）：
///
///     s[0]*31^(n-1) + s[1]*31^(n-2) + ... + s[n-1]
///
/// 其中 `s[i]` 是 **UTF-16 code unit**（Java 的 `char`），累加在 **32 位有符号 int**
/// 上、溢出即回绕。这两点都要逐字复刻：
/// - 非 BMP 字符（emoji 等）在 Java 里占两个 char，所以必须遍历 `utf16`，
///   不能遍历 Swift 的 `Character`；
/// - 用 `&*` / `&+` 做回绕运算，不能用普通的 `*` / `+`（会触发溢出陷阱）。
public enum JavaHash {

    /// 等价于 Java 的 `someString.hashCode()`。
    public static func stringHashCode(_ value: String) -> Int32 {
        var hash: Int32 = 0
        for unit in value.utf16 {
            // unit 是 UInt16，取值范围 0...65535，可安全装进 Int32。
            hash = 31 &* hash &+ Int32(unit)
        }
        return hash
    }

    /// Kotlin `name.hashCode() and 0x7fffffff`：抹掉符号位，得到非负整数。
    ///
    /// 注意 Kotlin 里 `and` 是**中缀函数**，优先级低于 `%`。原版源码是两个独立语句
    /// （`val h = ... and 0x7fffffff` 然后 `h % size`），所以不存在
    /// `hashCode and (0x7fffffff % 12)` 这种误读。
    public static func nonNegativeBucket(_ value: String) -> Int {
        Int(stringHashCode(value) & 0x7FFF_FFFF)
    }
}

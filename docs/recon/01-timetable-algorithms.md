# 课表核心算法规格（Android → iOS/Swift 移植用）

> 来源优先级：`apk_work\kb\src2\TimetableGridV2.kt`（真 Kotlin，最权威）＞ jadx 反编译 Java（1.11.5）＞ smali。
> 本文所有代码片段均为**原文照抄**。凡无法从现有材料确证的，一律显式标注 `// 不确定：…`。
> 生成时间：本轮 recon（1.11.5 源码 + 1.11.0 smali 交叉验证）。

---

## 0. 材料清单与可信度

| 代号 | 路径 | 说明 |
|---|---|---|
| **K** | `apk_work\kb\src2\TimetableGridV2.kt` | 真 Kotlin 网格源码（1100 行），含配色/合并/时间文本/字号/几何/布局 |
| **J** | `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableScreenKt.java` | jadx，6541 行，含 `courseOccursInWeek` / `getCurrentTeachingWeek` / `generateTimeSlots` |
| **JG** | `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableGridV2Kt.java` | jadx 网格 |
| **JV** | `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableViewModel.java` | jadx |
| **JL** | `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\LocalStorage.java` | jadx，含**默认节次时间表** |
| **JA** | `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\AppSettings.java` | jadx |
| **JW** | `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\widget\WidgetTimetableHelperKt.java` | jadx，`courseOccursInWeek` 的另一份副本（辅助交叉验证） |
| **S** | `apk_work\v1100smali\kebiaocom\example\ui\TimetableScreenKt.smali` | 1.11.0 原始 App 的 smali（绝对权威，用于校验 jadx 丢分支） |

重要事实：**我们自维护的补丁包 `apk_work\kb\` 里，`TimetableScreenKt.access$courseOccursInWeek` 被替换成了桩**
（`apk_work\kb\smali185\kebiaocom\example\ui\TimetableScreenKt.smali:376-389`，方法体仅 `const/4 v0, 0x0` 后 return）。
因此**只能**从 `J` / `JW` / `S` 取 `courseOccursInWeek` 的真实逻辑，K 中 `courseOccursInWeekBridge` 是编译期桩，**不可当算法**。

---

## 1. 课程颜色算法

### 1.1 调色板（12 个 ARGB）

出处：`apk_work\kb\src2\TimetableGridV2.kt:80-93`

```kotlin
private val MorandiPalette: List<Int> = listOf(
    0xFFA8A8C0.toInt(), 0xFFACA7C5.toInt(), 0xFFA795A5.toInt(), 0xFF454350.toInt(),
    0xFF797C67.toInt(), 0xFFC9AA7C.toInt(), 0xFFDAACB6.toInt(), 0xFFD1DBDA.toInt(),
    0xFFBEBAAE.toInt(), 0xFF8D89A2.toInt(), 0xFFB7C0B2.toInt(), 0xFFC8B4A8.toInt()
)
```

| # | ARGB | R | G | B |
|---|---|---|---|---|
| 0 | `0xFFA8A8C0` | 168 | 168 | 192 |
| 1 | `0xFFACA7C5` | 172 | 167 | 197 |
| 2 | `0xFFA795A5` | 167 | 149 | 165 |
| 3 | `0xFF454350` | 69 | 67 | 80 |
| 4 | `0xFF797C67` | 121 | 124 | 103 |
| 5 | `0xFFC9AA7C` | 201 | 170 | 124 |
| 6 | `0xFFDAACB6` | 218 | 172 | 182 |
| 7 | `0xFFD1DBDA` | 209 | 219 | 218 |
| 8 | `0xFFBEBAAE` | 190 | 186 | 174 |
| 9 | `0xFF8D89A2` | 141 | 137 | 162 |
| 10 | `0xFFB7C0B2` | 183 | 192 | 178 |
| 11 | `0xFFC8B4A8` | 200 | 180 | 168 |

### 1.2 索引公式

出处：`apk_work\kb\src2\TimetableGridV2.kt:765-768`

```kotlin
private fun paletteColor(name: String): Int {
    val h = if (name.isEmpty()) 0 else name.hashCode() and 0x7fffffff
    return MorandiPalette[h % MorandiPalette.size]
}
```

jadx 同一逻辑（1.11.5）：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableGridV2Kt.java:5080`

```java
int h = name.length() == 0 ? 0 : Integer.MAX_VALUE & name.hashCode();
```

**关键点（顺序与符号）**：

1. 先判空串 → `h = 0`（**不走** hashCode）。
2. 否则 `h = name.hashCode() and 0x7FFFFFFF`。`and 0x7FFFFFFF` = 清零符号位，把 Java 有符号 `int` 变成非负 `int`。
3. **最后**才 `h % 12`。因为 `h >= 0`，`%` 的符号问题不存在，结果恒在 `0..11`。

`name` 用的是 `course.name`（课程名），见 K `paletteColor(raw.name)`（`TimetableGridV2.kt:584` 一带的卡片刻）。

**Swift 等价实现要点**：

- 必须**自己实现 Java 的 `String.hashCode()`**：`h = 31*h + Int32(unicodeScalar)`，全程 `Int32` 溢出回绕（`&*`、`&+`）。**不能**用 Swift `String.hashValue`（随机种子，跨进程不稳定）。
- Java 的 `hashCode()` 按 UTF-16 code unit 迭代，Swift 应对 `Array(name.utf16)` 迭代。
- 取模：`let idx = Int(UInt32(bitPattern: h) & 0x7FFF_FFFF) % 12`。对正数 `%`，Swift 与 Java 一致。
- 空串 → 0，别让 `hashCode()` 在空串上跑（虽然结果也是 0，但保持语义一致）。
- 若某课程名以组合字符/emoji 出现，UTF-16 迭代可保证与 Android 同色。

---

## 2. 周次判断 `courseOccursInWeek(course, week)`

### 2.1 权威 Java 原文（jadx 1.11.5，`isOddWeek` 见 2.3）

出处：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableScreenKt.java:366-442`
（jadx 头部警告：`JADX WARN: Removed duplicated region for block: B:56:0x01bb` / `B:58:0x01c0`）

```java
public static final boolean courseOccursInWeek(Course course, int i) {
    Integer intOrNull;
    if (i <= 0) {
        return false;
    }
    int startWeek = course.getStartWeek();
    if (i <= course.getEndWeek() && startWeek <= i) {
        int isOdd = course.isOdd();
        if (isOdd == 1) {
            if (!isOddWeek(i)) {
                return false;
            }
        } else if (isOdd == 2 && isOddWeek(i)) {
            return false;
        }
        if (StringsKt.isBlank(course.getWeekRange())) {
            return true;
        }
        String replace$default = StringsKt.replace$default(StringsKt.replace$default(StringsKt.replace$default(StringsKt.replace$default(StringsKt.replace$default(course.getWeekRange(), " ", "", false, 4, (Object) null), "，", ",", false, 4, (Object) null), "、", ",", false, 4, (Object) null), "；", ",", false, 4, (Object) null), ";", ",", false, 4, (Object) null);
        String str = replace$default;
        if (!new Regex("\\d").containsMatchIn(str)) {
            return true;
        }
        boolean contains$default = StringsKt.contains$default((CharSequence) str, (CharSequence) "单", false, 2, (Object) null);
        boolean contains$default2 = StringsKt.contains$default((CharSequence) str, (CharSequence) "双", false, 2, (Object) null);
        List split$default = StringsKt.split$default((CharSequence) StringsKt.replace$default(StringsKt.replace$default(StringsKt.replace$default(StringsKt.replace$default(StringsKt.replace$default(StringsKt.replace$default(StringsKt.replace$default(replace$default, "周次", "", false, 4, (Object) null), "第", "", false, 4, (Object) null), "周", "", false, 4, (Object) null), "(", "", false, 4, (Object) null), ")", "", false, 4, (Object) null), "单", "", false, 4, (Object) null), "双", "", false, 4, (Object) null), new String[]{","}, false, 0, 6, (Object) null);
        ArrayList arrayList = new ArrayList(CollectionsKt.collectionSizeOrDefault(split$default, 10));
        Iterator it = split$default.iterator();
        while (it.hasNext()) {
            arrayList.add(StringsKt.trim((CharSequence) it.next()).toString());
        }
        ArrayList arrayList2 = new ArrayList();
        for (Object obj : arrayList) {
            if (((String) obj).length() > 0) {
                arrayList2.add(obj);
            }
        }
        ArrayList arrayList3 = arrayList2;
        if (arrayList3.isEmpty()) {
            return true;
        }
        ArrayList<String> arrayList4 = arrayList3;
        if (!(arrayList4 instanceof Collection) || !arrayList4.isEmpty()) {
            for (String str2 : arrayList4) {
                String str3 = str2;
                if (StringsKt.contains$default((CharSequence) str3, (CharSequence) "-", false, 2, (Object) null)) {
                    List split$default2 = StringsKt.split$default((CharSequence) str3, new String[]{"-"}, false, 0, 6, (Object) null);
                    if (split$default2.size() == 2 && (intOrNull = StringsKt.toIntOrNull((String) split$default2.get(0))) != null) {
                        int intValue = intOrNull.intValue();
                        Integer intOrNull2 = StringsKt.toIntOrNull((String) split$default2.get(1));
                        if (intOrNull2 != null) {
                            int intValue2 = intOrNull2.intValue();
                            if (intValue <= i && i <= intValue2) {
                                if (!contains$default) {
                                    return isOddWeek(i);
                                }
                                if (contains$default2) {
                                    return !isOddWeek(i);
                                }
                                return true;
                            }
                        } else {
                            continue;
                        }
                    }
                } else {
                    Integer intOrNull3 = StringsKt.toIntOrNull(str2);
                    if (intOrNull3 != null && i == intOrNull3.intValue()) {
                        if (!contains$default) {
                        }
                    }
                }
            }
        }
    }
    return false;
}
```

### 2.2 smali 校验（1.11.0，确认 jadx 未丢分支）

出处：`apk_work\v1100smali\kebiaocom\example\ui\TimetableScreenKt.smali:9137-9705`
方法头：`.method private static final courseOccursInWeek(Lkebiaocom/example/data/Course;I)Z`，`.registers 25`。
逐段解码结果（与 2.1 完全一致）：

1. `if-gtz week` → `return false` ⇒ **`week <= 0` 直接 false**。
2. `week <= endWeek && startWeek <= week`（**双端包含**），否则跳末尾 `return false`。
3. `isOdd == 1` → `!isOddWeek(week)` 则 false；`isOdd == 2` → `isOddWeek(week)` 则 false；`isOdd == 0` 不过滤。
4. `weekRange` 为 blank ⇒ **true**。
5. 归一化 `replace`，**顺序固定**：`" "→""`、`"，"(U+FF0C)→","`、`"、"(U+3001)→","`、`"；"(U+FF1B)→","`、`";"→","`。
6. 归一化后**不含任何数字**（`Regex("\\d").containsMatchIn`）⇒ **true**。
7. `containsSingle = 归一化串.contains("单")`、`containsDouble = 归一化串.contains("双")`（**在去掉单/双字之前判定**）。
8. 再依次 `replace`：`"周次"→""`、`"第"→""`、`"周"→""`、`"("→""`、`")"→""`、`"单"→""`、`"双"→""`。
9. 按 `","` split → 每个元素 `trim()` → 过滤掉空串 ⇒ `parts`。
10. `parts.isEmpty()` ⇒ **true**。
11. 遍历 `parts`：
    - 含 `-`：按 `-` split；**必须恰好 2 段**（否则跳过该段，且**不会** fallthrough 到单数字分支）；两段各自 `toIntOrNull`（整段已在第 9 步 `trim()`，两个边界片段**不再 trim**）：
      - 任一段 `toIntOrNull` 为 null → `continue`
      - `a <= week <= b`（**双端包含**）→ 落入下方 `:goto_4` 收尾判定
    - 不含 `-`：`toIntOrNull(part)`，若 `week == 该值` → **同样落入 `:goto_4`**
    - `:goto_4` 收尾判定（区间段与单数字段**共用**）：

      ```text
      if (containsSingle) return isOddWeek(week)
      if (containsDouble) return !isOddWeek(week)
      return true
      ```

      > ✅ **已确证（本节原标「不确定」，2026-10-16 由 smali 逐指令核实后改写）**
      >
      > 权威指令：`apk_work/proj_dec/smali_classes3/kebiaocom/example/ui/TimetableScreenKt.smali:9676-9703`
      >
      > ```
      > :goto_4
      > if-eqz v2, :cond_e                                  # v2 = contains("单")
      > isOddWeek(week); return                            # 有「单」→ isOddWeek(week)
      > :cond_e
      > if-eqz v5, :cond_f                                  # v5 = contains("双")
      > isOddWeek(week); xor-int/2addr v0, v4; return        # 有「双」→ !isOddWeek(week)
      > :cond_f
      > return v4                                           # v4 = 1 → true
      > ```
      >
      > 区间段在 `:9660 goto :goto_4`，单数字段在 `:9674` 直接落入 `:goto_4`。
      >
      > ⚠️ **判定顺序是先「单」后「双」**，且**两者都没有时返回 `true`**（命中的每一周都上课）。
      > jadx 把整段收尾丢掉了——`TimetableScreenKt.java:431-437` 只剩一个空的
      > `if (!contains$default) { }`——照它字面实现会写成「没有『单』才 `isOddWeek`」，
      > **方向相反**：`weekRange = "1-16"` 这类不含单/双字样的区间会被判成「只在单周出现」，
      > 教务导入的课表在双周整片消失。另有一份副本 `WidgetTimetableHelperKt.java:84-161`
      > 被 jadx 同样删空（`:150-156`），以 smali 为准。

12. 全部遍历完仍未返回 ⇒ `return false`。

> 该分支的同一份代码在 `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\widget\WidgetTimetableHelperKt.java:84-161` 有一份**字节级相同**的副本，其 `TimetableScreenKt.java:434-435` 同样被 jadx 删空（`WidgetTimetableHelperKt.java:150-156`），两份都缺失，无法从 jadx 侧互证。

### 2.3 `isOddWeek`

出处：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableScreenKt.java:323-325`

```java
private static final boolean isOddWeek(int i) {
    return i % 2 == 1;
}
```

> 对正数 `i`，`i % 2 == 1` ⇔ 奇数次周。`week <= 0` 已在入口拦掉，所以不会遇到负数取模。

### 2.4 `Course` 字段

出处：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\Course.java`

- `getStartWeek()` / `getEndWeek()`：Int，闭区间起止周。
- `isOdd()`：Int，`0` = 不限，`1` = 单周，`2` = 双周。
  `// 不确定：` 字段名 `isOdd` 是 jadx 对 Kotlin `isOdd: Int` 的原样保留；取值 `0/1/2` 的语义从 2.1/2.2 的分支反推，未找到赋值侧的字符串常量定义。
- `getWeekRange()`：String，形如 `"1-16周"`、`"1,3,5"`、`"1-8,10-16"`、`"单周"`、`"1-16周(单)"`。

### 2.5 Swift 等价实现要点

- `week <= 0` 提前返回 `false`。
- 双端闭区间：`startWeek <= week && week <= endWeek`。
- `isOddWeek(week)` = `week % 2 == 1`。
- **字符串归一化必须逐条按顺序 replace**，特别是 `containsSingle/containsDouble` 要在**只做了 5 条标点归一化**的串上判定。别先删了单/双字再判。
- `Regex("\\d").containsMatchIn` 语义 = **存在任意一个 ASCII 数字**（Java `\d` 默认只匹配 `[0-9]`）。Swift 用 `s.rangeOfCharacter(from: .decimalDigits)` 时要小心：`CharacterSet.decimalDigits` **包含全角等 Unicode 数字**，与 Java `\d` 不同。建议 `s.contains { $0.isASCII && $0.isNumber }`。
- `split(",")`：Kotlin 对空串 split 返回 `[""]`，再被 `filter { it.length > 0 }` 清空 ⇒ `parts.isEmpty()` ⇒ 返回 `true`。**所以 `"周"` 这种删完变空的串，最终是 true**。Swift `"".split(separator: ",")` 返回 `[]`，结果同样为空，行为一致；但 `"a,,"` 这类要确保空元素被过滤。
- `trim()` = 去掉首尾所有 `Character.isWhitespace`。
- `toIntOrNull` 会接受前导 `+`/`-`；`" 5"` → null（`Integer.parseInt` 本体不接受前后空白）。Swift `Int(s)` 语义相近。
- **整数溢出**：这里没有算术溢出风险，全是比较。
- 区间分支要求 `split("-").count == 2`：`"1-2-3"` 会被**跳过**（因为 `contains("-")` 为 true 就走区间分支，size != 2 则该 part 直接不匹配，**不会** fallthrough 到单数字分支）。

---

## 3. 当前周次计算

### 3.1 学期起始日期的来源

- 字段：`AppSettings.firstWeekStartDate: String?`（`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\AppSettings.java:25`、`:167`、`:272`）。
- 持久化 key：`"firstWeekStartDate"`（`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\LocalStorage.java:64`、`:74`）。
- UI 里由日期选择器写入，格式 `SimpleDateFormat("yyyy-MM-dd")`（`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\SettingsScreenKt.java:383-387`、`:1592-1597`）。

### 3.2 `getCurrentTeachingWeek(firstWeekStartDate, semesterWeeks)`

出处：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableScreenKt.java:301-317`

```java
private static final int getCurrentTeachingWeek(String str, int i) {
    Calendar parseDate;
    String obj = str != null ? StringsKt.trim((CharSequence) str).toString() : null;
    if (obj == null) {
        obj = "";
    }
    if (obj.length() == 0 || (parseDate = parseDate(obj)) == null) {
        return 1;
    }
    Calendar calendar = Calendar.getInstance();
    calendar.set(11, 0);
    calendar.set(12, 0);
    calendar.set(13, 0);
    calendar.set(14, 0);
    int timeInMillis = (int) ((calendar.getTimeInMillis() - parseDate.getTimeInMillis()) / CalendarModelKt.MillisecondsIn24Hours);
    return RangesKt.coerceIn(timeInMillis >= 0 ? (timeInMillis / 7) + 1 : 1, 1, RangesKt.coerceAtLeast(i, 1));
}
```

要点：

- `11/12/13/14` = `Calendar.HOUR_OF_DAY / MINUTE / SECOND / MILLISECOND`，即把「今天」抹成 00:00:00.000。
- `MillisecondsIn24Hours` = `86400000L`。
- `(int)` 强转：**差值毫秒先除 86400000 再转 int**，所以不会溢出（天数级别）。
- 天数差 `< 0`（学期还没开始）⇒ `currentWeek = 1`。
- 否则 `currentWeek = 天数差 / 7 + 1`（**整除向下取整**，第 0..6 天 = 第 1 周）。
- 最后 `coerceIn(1, max(semesterWeeks, 1))`：**上界被学期总周数截断**。

### 3.3 `parseDate`

出处：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableScreenKt.java:281-299`

```java
private static final Calendar parseDate(String str) {
    Calendar calendar = Calendar.getInstance();
    SimpleDateFormat simpleDateFormat = new SimpleDateFormat("yyyy-MM-dd");
    simpleDateFormat.setLenient(false);
    calendar.setLenient(false);
    try {
        calendar.setTime(simpleDateFormat.parse(str));
    } catch (ParseException unused) {
        return null;
    }
    calendar.set(11, 0);
    calendar.set(12, 0);
    calendar.set(13, 0);
    calendar.set(14, 0);
    return calendar;
}
```

> **严格解析**（`setLenient(false)`）：`"2024-1-5"`、`"2024-13-01"`、任意非 `yyyy-MM-dd` 串 → `parse` 抛异常 → `null` → `getCurrentTeachingWeek` 返回 `1`。

### 3.4 `currentWeekOffset` 的作用

出处：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableViewModel.java:33`、`:74-76`、`:104-106`、`:117-119`

```java
private final MutableStateFlow<Integer> _currentWeekOffset;   // :33
private final StateFlow<Integer> currentWeekOffset;           // :40

MutableStateFlow<Integer> MutableStateFlow7 = StateFlowKt.MutableStateFlow(0);  // :74  初值 0
this._currentWeekOffset = MutableStateFlow7;                                    // :75
this.currentWeekOffset = FlowKt.asStateFlow(MutableStateFlow7);                 // :76

public final void setCurrentWeekOffset(int offset) {          // :117-119
    this._currentWeekOffset.setValue(Integer.valueOf(offset));
}
```

**显示周 = clamp(currentTeachingWeek + currentWeekOffset, 最小值 1)**
出处：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableScreenKt.java:713-715`

```java
final int intValue = ((Number) rememberedValue).intValue();          // = getCurrentTeachingWeek(...)
startRestartGroup.endReplaceableGroup();
final int coerceAtLeast = RangesKt.coerceAtLeast(intValue + TimetableScreen$lambda$15(collectAsState4), 1);
```

`TimetableScreen$lambda$15(State<Integer>)` 就是 `state.getValue().intValue()`（`TimetableScreenKt.java:6527-6530`），即 `currentWeekOffset`。
**注意：显示周只有下界 1（`coerceAtLeast(..., 1)`），上界没有 clamp 到 `semesterWeeks`。**

offset 的写入点：

- `TimetableScreenKt.java:3374` → `setCurrentWeekOffset(0)`（回到本周）
- `TimetableScreenKt.java:1794` → `setCurrentWeekOffset(i20)`（周次列表直接选某一周）
- `TimetableScreenKt.java:1815` / `:1835` → `setCurrentWeekOffset(当期 offset + 1)` / `(offset - 1)`（上一周 / 下一周）
- `TimetableScreenKt.java:3904` → `setCurrentWeekOffset(RangesKt.coerceIn((int) f, 1, coerceAtLeast22) - i23)`（周次滑杆：滑杆值 − (currentTeachingWeek − 1)，让滑杆的 1 对应第 1 周）

### 3.5 周次展示文本与超范围

出处：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableScreenKt.java:319-321`

```java
public static final String getWeekNumberDisplay(int i) {
    return "第" + RangesKt.coerceAtLeast(i, 1) + "周";
}
```

K 侧（网格徽标）：`TimetableGridV2.kt:296-322`，`if (week > 0) week.toString() else "-"`。
**超范围处理**：`currentWeek` 本身被 `coerceIn(1, semesterWeeks)`；但**显示周可被 offset 推出 `[1, semesterWeeks]`**（只有下界）。此时网格仍渲染该周，`courseOccursInWeek` 对 `week > endWeek` 的课程返回 false（若开启 `showNonCurrentWeekCourses` 则以降低 alpha 显示）。

### 3.6 Swift 等价实现要点

- **日历差必须按「抹零后的本地日」计算**：先把 today 与 firstWeekStartDate 都抹到 00:00:00 本地时区，再取 `Calendar.current.dateComponents([.day], from: start, to: today).day!`。**不要**用 `timeIntervalSince` 直接除 86400（DST 会差 1 小时导致天数错位）。
- Java 用 `Calendar.getInstance()` 默认时区；iOS 用 `Calendar.current`（同语义）。
- 严格日期解析：Swift 用固定 `DateFormatter`（`locale = Locale(identifier: "en_US_POSIX")`、`dateFormat = "yyyy-MM-dd"`、`isLenient = false`）。**`DateFormatter` 即便 `isLenient = false` 也可能接受 `"2024-1-5"`**，建议在 `date(from:)` 成功后再做一次「三段长度 4/2/2、全 ASCII 数字」的手工校验。
- `RangesKt.coerceIn(v, lo, hi)` 要求 `lo <= hi`，否则 Kotlin 抛 `IllegalArgumentException`。这里 `lo = 1`、`hi = max(semesterWeeks, 1) >= 1`，安全。Swift 写 `min(max(v, lo), hi)`。
- 整数：天数差用 `Int`，无溢出风险。

---

## 4. 相邻课程合并

### 4.1 权威 Kotlin（真源码）`mergeAdjacent`

出处：`apk_work\kb\src2\TimetableGridV2.kt:774-793`

```kotlin
private fun mergeAdjacent(input: List<Course>): List<Course> {
    if (input.isEmpty()) return input
    val sorted = input.sortedBy { it.startPeriod }
    val out = ArrayList<Course>(sorted.size)
    var cur = sorted[0]
    for (i in 1 until sorted.size) {
        val next = sorted[i]
        val sameCourse = next.name == cur.name && next.location == cur.location && next.teacher == cur.teacher
        if (sameCourse && next.startPeriod == cur.endPeriod + 1) {
            cur = cur.copy(endPeriod = next.endPeriod)
        } else { out.add(cur); cur = next }
    }
    out.add(cur)
    return out
}
```

**合并条件与结果**：

- 先按 `startPeriod` **升序稳定排序**。
- 相邻两项满足：`name`、`location`、`teacher` **三者全等**，且 `next.startPeriod == cur.endPeriod + 1`（**严格紧邻，中间不留空节**）。
- 合并：保留 `cur` 的所有其它字段，仅把 `endPeriod` 改为 `next.endPeriod`（**startPeriod 不动**）。
- **不比较** `dayOfWeek` / `weekRange` / `startWeek` / `endWeek` / `isOdd`。
- **是否只处理同一天？** 函数自身不知道天，但**调用方已按天过滤**：调用处为
  `TimetableGridV2.kt:551` `mergeAdjacent(courses.filter { it.dayOfWeek == day && it.endPeriod >= startPeriod && it.startPeriod <= endPeriod })`
  —— 所以实际效果是**同一天 + 同一面板节次范围内**才可能合并。

### 4.2 与原 App 的差异（重要）

原始 App 的导入解析器 `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\QiangzhiJwxtParser.java:863` 附近的 `mergeAdjacent` **额外要求**：同 `dayOfWeek`、`endPeriod + 1 == startPeriod`、同 `weekRange`、同 `startWeek`、同 `endWeek`、同 `isOdd`。

> 也就是说 **K 版本比原 App 更宽松**（会把单双周不同、周次范围不同的同名课程也合并）。若 iOS 要与**当前 Android 版**一致，按 4.1；若要更保守，加上 4.2 的额外字段比较。

### 4.3 Swift 等价实现要点

- `sortedBy { it.startPeriod }` 是**稳定排序**；Swift `sorted(by:)` **不保证稳定**，需 `enumerated().sorted { ($0.1.startPeriod, $0.0) < ($1.1.startPeriod, $1.0) }`，才能与 Kotlin 完全一致（对同 `startPeriod` 的课程顺序敏感）。
- `cur.copy(endPeriod = next.endPeriod)` = 值类型拷贝，Swift `struct` 直接 `cur.endPeriod = next.endPeriod` 即可（注意 `cur` 需为 `var`）。
- `next.startPeriod == cur.endPeriod + 1` 是**精确相邻 +1**，不是 `>=`。

---

## 5. 课程时间文本

### 5.1 `buildTimeRange(course, timeSlots)`

K 出处：`apk_work\kb\src2\TimetableGridV2.kt:795-805`

```kotlin
private fun buildTimeRange(course: Course, timeSlots: List<String>): String {
    val first = timeSlots.getOrNull(course.startPeriod - 1)?.substringBefore("-")?.trim() ?: ""
    val last  = timeSlots.getOrNull(course.endPeriod - 1)?.substringAfter("-")?.trim() ?: ""
    return when {
        first.isEmpty() && last.isEmpty() -> ""
        first.isEmpty() -> last
        last.isEmpty() -> first
        else -> "$first-$last"
    }
}
```

原 App 同逻辑（jadx，函数名不同）：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableScreenKt.java:169-196`，方法签名

```java
private static final String buildCourseTimeRange(Course course, List<String> list)
```

其分支与上面**语义完全相同**（`obj + "-" + str2`；两者皆空 → `""`；仅一方空 → 用另一方）。

**索引规则**：`timeSlots[i]` 对应**第 `i+1` 节**，元素形如 `"08:10-08:55"`。

- `first` = 第 `startPeriod` 节的**开始时间**（`-` 之前，trim）
- `last` = 第 `endPeriod` 节的**结束时间**（`-` 之后，trim）
- 越界（`period - 1` 超出 list）→ `getOrNull` 返回 null → 该侧 `""`。
- **无 `-` 的 slot**：`substringBefore("-")` 返回**整个串**；`substringAfter("-")` 在无分隔符时也返回**整个串**（Kotlin 语义：找不到 delimiter 时 `substringAfter` 返回原串，不是空串！）。⚠️ 这与直觉相反，Swift 移植必须复刻。

### 5.2 `dayPeriodLine`

**`// 不确定：` 全代码库中未找到名为 `dayPeriodLine` 的函数。**

- 在 `apk_work\kb\src2\TimetableGridV2.kt` 全文无此符号。
- 在 `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\` 全树 grep `dayPeriodLine|dayPeriod` 无匹配。
- 与之功能最接近的是 **`getTodayLabel()`**（`TimetableScreenKt.java:327-358`），它返回「今天」的标题行：

```java
private static final String getTodayLabel() {
    String str;
    Calendar calendar = Calendar.getInstance();
    SimpleDateFormat simpleDateFormat = new SimpleDateFormat("M月d日", Locale.getDefault());
    switch (calendar.get(7)) {
        case 1: str = "日"; break;
        case 2: str = "一"; break;
        case 3: str = "二"; break;
        case 4: str = "三"; break;
        case 5: str = "四"; break;
        case 6: str = "五"; break;
        case 7: str = "六"; break;
        default: str = ""; break;
    }
    return simpleDateFormat.format(calendar.getTime()) + "  周" + str;
}
```

> 即输出形如 `"5月2日  周五"`。`calendar.get(7)` = `DAY_OF_WEEK`，`1=周日 … 7=周六`。
> 若 iOS 侧已有 `dayPeriodLine` 的名字，其含义应为「日期 + 星期」这一行；请以 `getTodayLabel` 为准。

### 5.3 `prettyDate` / `pad2`

出处：`apk_work\kb\src2\TimetableGridV2.kt:754-763`

```kotlin
private fun prettyDate(raw: String): String {   // "5/2" -> "05-02"
    val parts = raw.split("/")
    if (parts.size != 2) return raw
    val m = parts[0].trim().toIntOrNull() ?: return raw
    val d = parts[1].trim().toIntOrNull() ?: return raw
    return pad2(m) + "-" + pad2(d)
}

private fun pad2(v: Int): String = if (v < 10) "0$v" else v.toString()
```

jadx 同逻辑：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableGridV2Kt.java:5057-5075`。
输入来自 `getWeekDates` 的 `SimpleDateFormat("M/d")` 输出（`TimetableScreenKt.java:258-279`），即 `"5/2"` → `"05-02"`。
`pad2` 对 `v >= 10` 直接 `toString()`；对 `v < 0` 会输出 `"0-1"`（**无保护**，但月份/日不会为负）。

### 5.4 `dayIndexOf`（星期映射：**周一 = 1**）

出处：`apk_work\kb\src2\TimetableGridV2.kt:743-752`

```kotlin
private fun dayIndexOf(weekday: String): Int = when (weekday) {
    "一" -> 1
    "二" -> 2
    "三" -> 3
    "四" -> 4
    "五" -> 5
    "六" -> 6
    "日" -> 7
    else -> 0
}
```

jadx 同逻辑：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableGridV2Kt.java:5021`（`switch (weekday.hashCode())`）。
**返回值：周一 = 1，周日 = 7，未知 = 0。** 与 `course.dayOfWeek` 的取值域一致（1..7）。
⚠️ 注意这与 `getTodayLabel` 里 `Calendar.DAY_OF_WEEK`（1 = 周日）**不是同一套编号**，移植时别混。

### 5.5 节次 → 时间映射

#### 5.5.1 有用户配置时：`TimetableProfile.periodTimes`

出处：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableScreenKt.java:227-256`

```java
private static final List<String> getEffectiveTimeSlots(AppSettings appSettings, List<TimetableProfile> list) {
    // 1. 找 id == appSettings.getSelectedTimetableProfileId() 的第一个 profile，找不到为 null
    // 2. if (profile == null || profile.getPeriodTimes().isEmpty())
    //        return generateTimeSlots(appSettings.getFirstPeriodStartTime(),
    //                                 appSettings.getPeriodDurationMinutes(),
    //                                 appSettings.getBreakDurationMinutes(),
    //                                 appSettings.getPeriodsPerDay());
    // 3. 否则：periodTimes 按 getIndex() 升序排序，逐项拼 "start-end"
}
```

- 排序：`CollectionsKt.sortedWith(profile.getPeriodTimes(), compareBy { it.getIndex() })`
- 拼接：`result.add(periodTime.getStart() + "-" + periodTime.getEnd())`

#### 5.5.2 无配置时：`generateTimeSlots` 推导

出处：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableScreenKt.java:198-225`

```java
public static final List<String> generateTimeSlots(String firstPeriodStartTime, int periodDuration, int breakDuration, int periodsPerDay) {
    ArrayList arrayList = new ArrayList();
    List split$default = StringsKt.split$default((CharSequence) firstPeriodStartTime, new String[]{":"}, false, 0, 6, (Object) null);
    Integer intOrNull = StringsKt.toIntOrNull((String) split$default.get(0));
    int intValue = intOrNull != null ? intOrNull.intValue() : 8;      // 默认小时 8
    Integer intOrNull2 = StringsKt.toIntOrNull((String) split$default.get(1));
    int intValue2 = intOrNull2 != null ? intOrNull2.intValue() : 0;   // 默认分钟 0
    for (int i4 = 0; i4 < periodsPerDay; i4++) {
        String format  = String.format("%02d:%02d", intValue, intValue2);
        intValue2 += periodDuration;
        if (intValue2 >= 60) { intValue += intValue2 / 60; intValue2 %= 60; }
        String format2 = String.format("%02d:%02d", intValue, intValue2);
        arrayList.add(format + "-" + format2);
        if (i4 < periodsPerDay - 1 && (intValue2 = intValue2 + breakDuration) >= 60) {
            intValue += intValue2 / 60;
            intValue2 %= 60;
        }
    }
    return arrayList;
}
```

要点：

- 起始时间串按 `":"` split；**若串中没有冒号，`split$default.get(1)` 会抛 `IndexOutOfBoundsException`**（无保护）。
- `toIntOrNull` 失败时回退 `8` 小时 / `0` 分。
- 每节课：`start = 当前时刻`，`end = 当前时刻 + periodDuration`（跨小时自动进位）。
- 节间休息：除最后一节外，累加 `breakDuration`。
- 输出格式 `"%02d:%02d"`，即 `"08:10-08:55"`。

#### 5.5.3 `PeriodTime` 结构

出处：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\PeriodTime.java`

```kotlin
data class PeriodTime(val index: Int, val start: String, val end: String)
```

- `getIndex()`：节次序号（1 起）。用于排序，**不用于索引 timeSlots**（timeSlots 的顺序即最终顺序）。
- `getStart()` / `getEnd()`：`"HH:mm"`。
- JSON：`optString("start", "08:00")` / `optString("end", "08:45")`（`LocalStorage.java:225-230`）。

#### 5.5.4 `TimetableProfile`

出处：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\TimetableProfile.java`

```kotlin
data class TimetableProfile(val id: String, val name: String, val periodsPerDay: Int, val periodTimes: List<PeriodTime>)
```

### 5.6 Swift 等价实现要点

- **`substringAfter("-")` 无分隔符时返回原串**（Kotlin/Java `substringAfter` 语义）。Swift 常见写法 `s.split(separator: "-")` 行为不同。必须手写：

  ```swift
  func substringAfter(_ s: String, _ d: Character) -> String {
      guard let i = s.firstIndex(of: d) else { return s }   // 原串！
      return String(s[s.index(after: i)...])
  }
  func substringBefore(_ s: String, _ d: Character) -> String {
      guard let i = s.firstIndex(of: d) else { return s }
      return String(s[..<i])
  }
  ```

- `trim()` 语义同 Swift `.trimmingCharacters(in: .whitespacesAndNewlines)`（Java `trim()` 只去 `<= U+0020`；实际输入只有 ASCII 空格，够用）。
- `String.format("%02d:%02d", h, m)` → `String(format: "%02d:%02d", h, m)`。
- **索引越界**：`getOrNull(period - 1)` 返回 nil 是关键；Swift 用 `timeSlots.indices.contains(i) ? timeSlots[i] : nil`，**不要**直接下标。
- `startPeriod - 1` 若 `startPeriod == 0` 会变成 `-1`，Kotlin `getOrNull(-1)` 返回 null（负数索引安全）；Swift `indices.contains(-1)` 为 false，同样安全。

---

## 6. 字号自适应 `fitTextSize`

出处：`apk_work\kb\src2\TimetableGridV2.kt:726-731`

```kotlin
private fun fitTextSize(configured: Int, heightDp: Float): Int {
    val cap = configured.coerceAtLeast(7)
    val fit = ((heightDp - 8f) / 5f).toInt()
    return if (fit >= cap) cap else fit.coerceAtLeast(7)
}
```

jadx 同逻辑：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableGridV2Kt.java:3354-3379` 一带（`fitTextSize(settings.getCourseTextSizeSp(), h)`）。

**完整公式与阈值**：

- `cap = max(configuredSp, 7)` —— 用户配置的字号下限 7。
- `fit = Int((heightDp - 8) / 5)` —— Java/Kotlin 的 `Float.toInt()` 是**向零截断**。
- 若 `fit >= cap` → 用 `cap`（**不会超过用户配置值**）。
- 否则用 `max(fit, 7)`（**绝不低于 7sp**）。
- 结论：实际字号 ∈ `[7, cap]`，其中 `cap = max(configured, 7)`。

**Swift 等价实现要点**：

- `Float.toInt()` 是**向零截断**：Swift `Int(x)` 对有限浮点同样是向零截断，语义一致。用 `Int((heightDp - 8) / 5)`。
- **负数分支**：`heightDp < 8` 时 `fit` 为负，最终被 `coerceAtLeast(7)` 抬到 7，与 Kotlin 一致。
- 传入的 `heightDp` 是**布局后的卡片高度** `h.value`（`TimetableGridV2.kt:588` 一带）。
- 派生小字号：`small = (textSize - 2).coerceAtLeast(7)`，`smallLine = (small + 2).sp`（`TimetableGridV2.kt:644-712` 区间的 CourseTile）。

---

## 7. 网格几何

出处：`apk_work\kb\src2\TimetableGridV2.kt:96-112`（常量 + 左列宽度）

```kotlin
private val LeftColumnWide: Dp = 50.dp
private val LeftColumnNarrow: Dp = 42.dp
private val HeaderHeight: Dp = 46.dp
private val BlockGap: Dp = 10.dp
private val CardGap: Dp = 5.dp
private val MinCardHeight: Dp = 12.dp
private val PanelRadius: Dp = 16.dp
private val PanelPadding: Dp = 4.dp

private fun leftColumnWidth(dayCount: Int): Dp = if (dayCount >= 7) LeftColumnNarrow else LeftColumnWide
```

即：

| 名称 | 值 | 规则 |
|---|---|---|
| `LeftColumnWide` | 50dp | `dayCount <= 6` 时 |
| `LeftColumnNarrow` | 42dp | `dayCount >= 7` 时 |
| `leftColumnWidth(dayCount)` | 50dp / 42dp | `if (dayCount >= 7) 42.dp else 50.dp` |
| `HeaderHeight` | 46dp | 固定 |
| `BlockGap` | 10dp | 三个面板之间的**竖直间隔** |
| `CardGap` | 5dp | 同一天相邻卡片的**竖直间隔** |
| `MinCardHeight` | 12dp | 卡片高度下限 |
| `PanelRadius` | 16dp | 面板圆角 |
| `PanelPadding` | 4dp | 面板内边距 |

### 7.1 `cellH` 与 `rows`

出处：`apk_work\kb\src2\TimetableGridV2.kt:221-222`

```kotlin
val rows = if (rowCount > 0) rowCount else 1
val cellH: Dp = settings.courseCellHeightDp.dp
```

- `cellH` = 用户设置 `AppSettings.courseCellHeightDp`（**单位 dp，直接当每节课的高度**）。
- `rowCount` 为 0 时按 1 行处理，避免零高度。

### 7.2 三面板分区（上午 / 下午 / 晚上）

出处：`apk_work\kb\src2\TimetableGridV2.kt:362-427`

```kotlin
// 上午
startPeriod = 1
endPeriod = if (rows < 4) rows else 4
// 下午
startPeriod = 5
endPeriod = if (rows < 8) rows else 8
// 晚上
startPeriod = 9
endPeriod = rows
```

- 每个面板前有一个裸 `Box(height = BlockGap)` 作为间隔，底部再补一个 `BlockGap`（`:427`）。
- `blockRows = (endPeriod - startPeriod + 1).coerceAtLeast(1)`（`:496-500`）
- `blockHeight = cellH * blockRows`（`:496-500`）

> ⚠️ `rows < 4 → endPeriod = rows`：当 `rows == 2` 时上午面板只有 1..2 节，下午面板 `5 .. if (2 < 8) 2` → `endPeriod = 2 < startPeriod = 5`，`blockRows = (2 - 5 + 1).coerceAtLeast(1) = 1`。**该面板会出现但高度为 1 行、无课程**。Kotlin 原文如此（见 §10 不确定项 5）。

### 7.3 左列节次单元格

出处：`apk_work\kb\src2\TimetableGridV2.kt:510-531`

```kotlin
val slot = timeSlots.getOrNull(p - 1) ?: ""
// 数字：13.sp / lineHeight 15.sp Bold
// slot.substringBefore("-").trim() 与 slot.substringAfter("-").trim()：9.sp / 11.sp
// Modifier: offset(y = cellH * (p - startPeriod))
//           .fillMaxWidth().height(cellH)
//           .padding(horizontal = 1.dp, vertical = 1.dp)
//           .clip(RoundedCornerShape(8.dp))
```

### 7.4 面板配色

出处：`apk_work\kb\src2\TimetableGridV2.kt:126-135`

```kotlin
private fun panelColor(dark: Boolean, hasCustomBackground: Boolean): Color {
    val a = if (hasCustomBackground) 0.62f else 0.88f
    return if (dark) Color(0xFF1C1C1C).copy(alpha = a) else Color(0xFFFFFFFF).copy(alpha = a)
}

private fun hasCustomBackground(settings: AppSettings): Boolean {
    val uri = settings.backgroundImageUri
    return uri != null && uri.isNotBlank()
}
```

### 7.5 周次徽标与日期表头

出处：`apk_work\kb\src2\TimetableGridV2.kt:296-344`

- 徽标 Box：`width(leftWidth).padding(horizontal = 3.dp, vertical = 3.dp).clip(RoundedCornerShape(10.dp)).background(scheme.surfaceVariant)`
  - `"第"`：9.sp，`offset(x = 5.dp, y = 1.dp)`
  - 周数：`if (week > 0) week.toString() else "-"`，19.sp Bold，居中
  - `"周"`：9.sp，`Alignment.BottomEnd`，`offset(x = (-4).dp, y = (-2).dp)`
- 日期表头（`:331-344`）：
  - `"周" + entry.second` → 13.sp / lineHeight 16.sp Medium
  - `prettyDate(entry.first)` → 11.sp / lineHeight 13.sp，颜色 `onSurfaceVariant`

### 7.6 Swift 等价实现要点

- 全部用 `CGFloat` + 常量；`leftColumnWidth` 依赖 `dayCount >= 7`（`dayCount = 5 + (showSaturday ? 1 : 0) + (showSunday ? 1 : 0)`）。
- dp↔pt：Android `1.dp` ≈ iOS `1pt`（同为密度无关单位），数值直接搬运。
- `cellH * blockRows`：Kotlin `Dp * Int`，Swift 写 `CGFloat(blockRows) * cellH`。
- 左列 `offset(y:)` 是**面板内相对坐标**；三个面板各自独立坐标系（高度 `cellH * blockRows`），**不要**用全局 `(p - 1) * cellH`。

---

## 8. 相邻/重叠课程布局

### 8.1 权威 Kotlin 原文

出处：`apk_work\kb\src2\TimetableGridV2.kt:550-592`

```kotlin
var prevBottom = 0.dp
mergeAdjacent(courses.filter { it.dayOfWeek == day && it.endPeriod >= startPeriod && it.startPeriod <= endPeriod }).forEach { raw ->
    val occurs = courseOccursInWeekBridge(raw, week)
    val weekAlpha = if (showNonCurrentWeek && !occurs) settings.nonCurrentWeekCourseAlphaPercent.coerceIn(0, 100) / 100f else 1.0f
    val alpha = (cardAlpha * weekAlpha).coerceIn(0f, 1f)
    val start = raw.startPeriod.coerceIn(startPeriod, endPeriod)
    val end = raw.endPeriod.coerceIn(start, endPeriod)
    val naturalTop = cellH * (start - startPeriod)
    val naturalBottom = cellH * (end - startPeriod + 1) - CardGap
    val top = if (naturalTop < prevBottom) prevBottom + CardGap else naturalTop
    var h = naturalBottom - top
    if (h < MinCardHeight) h = MinCardHeight
    prevBottom = top + h
    // ...
    // textSize = fitTextSize(settings.courseTextSizeSp, h.value)
    // modifier = Modifier.fillMaxWidth().padding(horizontal = 2.dp).offset(y = top).height(h)
}
```

其中 `cardAlpha`、`cardTint`、`cardInk`、`optimize` 在同一面板循环外（每个 day Box 内）计算，出处 `apk_work\kb\src2\TimetableGridV2.kt:542-549`：

```kotlin
val optimize = OptimizeMode.isEnabled()
val cardTint = if (optimize) { if (dark) 0xFFFFFFFF.toInt() else 0xFF1A1A1A.toInt() } else 0
val cardInk  = if (optimize) { if (dark) 0xFF1A1A1A.toInt() else 0xFFFFFFFF.toInt() } else 0xFFFFFFFF.toInt()
val cardAlpha = settings.courseCardAlphaPercent.coerceIn(0, 100) / 100f
```

卡片刻的 tint 选择（`:584` 一带）：`tint = if (optimize) cardTint else paletteColor(raw.name)`，`ink = cardInk`。

jadx 同逻辑（1.11.5）：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableGridV2Kt.java:3342`（`occurs = TimetableScreenKt.courseOccursInWeek(raw, week)`）与 `:3354-3379`：

```java
float alpha = RangesKt.coerceIn(cardAlpha * weekAlpha, 0.0f, 1.0f);
int start = RangesKt.coerceIn(raw.getStartPeriod(), i18, endPeriod);
int end   = RangesKt.coerceIn(raw.getEndPeriod(), start, endPeriod);
int other$iv2 = start - i18;                       // i18 = startPeriod
float naturalTop = Dp.m5868constructorimpl(other$iv2 * cellH);
int other$iv3 = (end - i18) + 1;
float arg0$iv = Dp.m5868constructorimpl(other$iv3 * cellH);
float arg0$iv2 = Dp.m5868constructorimpl(arg0$iv - CardGap);
other$iv = Dp.compareTo(naturalTop, prevBottom3) < 0 ? prevBottom3 + CardGap : naturalTop;
float h = arg0$iv2 - other$iv;
if (Dp.compareTo(h, MinCardHeight) < 0) h = MinCardHeight;
float prevBottom4 = other$iv + h;
final CardStyle style = new CardStyle(optimize ? cardTint : paletteColor(raw.getName()), cardInk, alpha, fitTextSize(settings.getCourseTextSizeSp(), h));
```

### 8.2 逐项语义

- **调用方过滤**：`it.dayOfWeek == day && it.endPeriod >= startPeriod && it.startPeriod <= endPeriod`（**同日 + 与当前面板节次区间有交集**）。
- `start = clamp(raw.startPeriod, startPeriod, endPeriod)`
- `end = clamp(raw.endPeriod, start, endPeriod)` —— **下界是刚算出的 `start`**，保证 `end >= start`。
- `naturalTop = cellH * (start - startPeriod)`：相对面板顶部的「自然」位置。
- `naturalBottom = cellH * (end - startPeriod + 1) - CardGap`：**减掉一个 `CardGap` 作为卡片间缝**；末节独占时高度为 `cellH - CardGap`。
- `top = naturalTop < prevBottom ? prevBottom + CardGap : naturalTop`：**与上一张卡片重叠时下移**，下移量是「上一张底部 + CardGap」。
- `h = naturalBottom - top`；`if (h < MinCardHeight) h = MinCardHeight`（**下限 12dp**，因此可能溢出面板，Kotlin 不做裁剪）。
- `prevBottom = top + h`（供下一张卡片使用）。
- `prevBottom` 初值 `0.dp`，作用域是**每个 day Box / 每个面板**（`:550` 就在该 forEach 前）——即**每个面板每列独立重置**。
- 重叠策略是**单向贪心下推**，不是并排分列：后一张永远在前一张下面。

### 8.3 Swift 等价实现要点

- 逐条照搬顺序：先算 `start`/`end`（`end` 的下界用 `start`），再算 `naturalTop`/`naturalBottom`/`top`/`h`，最后 `prevBottom = top + h`。
- Kotlin `Dp` 的 `<` 即数值比较，Swift 用 `CGFloat`/`Double` 直接 `<`。
- **`endPeriod` 的 clamp 顺序不可交换**：`clamp(raw.endPeriod, start, endPeriod)`。
- 上下界都是闭区间。
- 建议将 `prevBottom` 声明在「每一天 + 每个面板」的循环体内，与 Kotlin 作用域一致。
- 由于 `MinCardHeight` 抬升可能导致 `top + h` 超过 `blockHeight`，最终卡片**允许溢出面板**；iOS 若加 `clipped()` 会改变观感，需保持一致。

---

## 9. 默认节次-时间表（**存在**，iOS 需要）

### 9.1 默认值来源

默认 profile 由 `LocalStorage.defaultTimetableProfiles()` 生成：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\LocalStorage.java:263-278`

```java
private final List<TimetableProfile> defaultTimetableProfiles() {
    List listOf = CollectionsKt.listOf((Object[]) new Pair[]{
        TuplesKt.to("08:10", "08:55"), TuplesKt.to("09:05", "09:50"),
        TuplesKt.to("10:20", "11:05"), TuplesKt.to("11:15", "12:00"),
        TuplesKt.to("14:10", "14:55"), TuplesKt.to("15:05", "15:50"),
        TuplesKt.to("16:20", "17:05"), TuplesKt.to("17:15", "18:00"),
        TuplesKt.to("19:30", "20:15"), TuplesKt.to("20:25", "21:10")
    });
    // ... 逐项构造 PeriodTime(index = i2, start = pair.first, end = pair.second)
    return CollectionsKt.listOf(new TimetableProfile("default", "默认", size, arrayList));
}
```

（`:275`：`arrayList.add(new PeriodTime(i2, (String) pair.getFirst(), (String) pair.getSecond()));`
`:278`：`return CollectionsKt.listOf(new TimetableProfile("default", "默认", size, arrayList));`）

### 9.2 完整对照表（**10 节，注意不是 12 节**）

| 节次 | 开始 | 结束 | 备注 |
|---|---|---|---|
| 1 | 08:10 | 08:55 | 上午 |
| 2 | 09:05 | 09:50 | 上午 |
| 3 | 10:20 | 11:05 | 上午（大课间 30 分钟） |
| 4 | 11:15 | 12:00 | 上午 |
| 5 | 14:10 | 14:55 | 下午 |
| 6 | 15:05 | 15:50 | 下午 |
| 7 | 16:20 | 17:05 | 下午（大课间 30 分钟） |
| 8 | 17:15 | 18:00 | 下午 |
| 9 | 19:30 | 20:15 | 晚上 |
| 10 | 20:25 | 21:10 | 晚上 |

### 9.3 与 `AppSettings` 默认的关系（易踩坑）

`LocalStorage.getSettings()` 的另一套默认（`LocalStorage.java:69-86`）**与上表不一致**：

```java
int i  = this.prefs.getInt("periodsPerDay", 12);                          // 12 节
int i2 = this.prefs.getInt("periodDurationMinutes", 45);                  // 45 分钟
String string2 = this.prefs.getString("firstPeriodStartTime", "08:00");   // 08:00
int i4 = this.prefs.getInt("semesterWeeks", 20);                          // 20 周
String string4 = this.prefs.getString("selectedTimetableProfileId", "default");
```

即：

- `selectedTimetableProfileId` 默认 `"default"` → 命中 9.1 的 profile（**10 节，08:10 起**）→ `getEffectiveTimeSlots` 用 profile，**不用** `generateTimeSlots`。
- 只有当用户删掉/清空 profile 的 `periodTimes` 时，才会用 `firstPeriodStartTime = "08:00"`、`periodDuration = 45`、`breakDuration = ?`、`periodsPerDay = 12` 生成。
- `// 不确定：` `breakDurationMinutes` 的 SharedPreferences 默认值未直接读到（`LocalStorage.java:71` 那一行被 grep 的匹配截断）。需要时读该行原文确认。

> iOS 端建议：**默认内置 9.2 的 10 节表**（`id = "default"`，`name = "默认"`），并在用户未自定义时使用它。

---

## 10. 汇总：不确定项

1. **§2.2 第 11 条「不含 `-` 的单数字分支」**：jadx 在 `TimetableScreenKt.java:434-435` 把 `if (!contains$default) { }` 的方法体删空；`WidgetTimetableHelperKt.java:150-156` 的副本同样缺失。smali 显示该分支与区间分支同构（都走 `containsSingle`/`containsDouble`/`isOddWeek` 三元逻辑），但**未能逐字节读到该分支的 smali 指令**，故标记为不确定。本文按「与区间分支同构」给出移植建议。
2. **§5.2 `dayPeriodLine`**：**全代码库不存在该函数**。最接近的是 `getTodayLabel()`（§5.2 原文）。
3. **§9.3 `breakDurationMinutes` 默认值**：未直接读到 `LocalStorage.java:71` 的默认字面量。
4. **§2.4 `Course.isOdd` 的取值语义**：`0/1/2` 是从 `courseOccursInWeek` 的分支反推，未定位到赋值侧的常量定义。
5. **§7.2 三面板在 `rows < 5` 时的退化行为**：`endPeriod = rows` 会产生 `endPeriod < startPeriod` 的面板；`blockRows` 被 `coerceAtLeast(1)` 兜住，但面板仍会被渲染。Kotlin 原文如此，未确认上层是否有条件阻止该情况。
6. **§3.2 与 `CourseReminderScheduler.calculateTeachingWeek` 的一致性**：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\reminder\CourseReminderScheduler.java:204` 另有一份独立实现（`calculateTeachingWeek(String firstWeekStartDate, Calendar target)`），本次未逐行比对；若 iOS 端的提醒功能也依赖它，需另做一次核对。
7. **§1.2 `optimize` 开关的默认值**：`OptimizeMode.isEnabled()` 的真值与持久化 key 未在本次 recon 中确证（`apk_work\kb\chk_sig.py:7` 显示 `ui/theme/OptimizeMode.smali` 有 `isEnabled` / `resolveColor` / `resolveTextColor`，`apk_work\kb\probe9.py:12` 曾在探测其默认值，但结果未回收）。






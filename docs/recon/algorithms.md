# 课表核心算法控制流核实（以 smali 字节码为准）

本文只回答 5 个问题：`courseOccursInWeek`、`fitTextSize`、`dayIndexOf`、`mergeAdjacent`/`buildTimeRange`、课表卡片纵向几何（含 `expandTarget`、`paletteColor`、`MorandiPalette`）。每条结论都给出字节码行号；凡是字节码无法确证的，写进该节「不确定项」，不做推测填充。

## 0. 数据源与实际行号

| 数据源 | 说明 |
| --- | --- |
| `apk_work\proj_dec\smali_classes3\kebiaocom\example\ui\TimetableScreenKt.smali` | 原 App 的课表逻辑。`courseOccursInWeek` 在 **9137–9704**，`isOddWeek` 在 **10580–10597**，合成桥 `access$courseOccursInWeek` 在 8950 |
| `apk_work\proj_dec\smali_classes3\kebiaocom\example\ui\TimetableGridV2Kt.smali` | **APK 内已经包含我们这版网格**（`TimetableGridV2Kt`），所以第 2–5 题同样能用字节码确证：`buildTimeRange` 22815–23039、`dayIndexOf` 23087–23246、`expandTarget` 23248–23452、`fitTextSize` 23454–23493、`mergeAdjacent` 23586–23817、`paletteColor` 23857–23919、`<clinit>`（调色板与 Dp 常量）198–580、卡片几何循环 14320–14674 |
| `apk_work\proj_dec\smali_classes3\kebiaocom\example\ui\TimetableGridV2Kt$mergeAdjacent$$inlined$sortedBy$1.smali` | `mergeAdjacent` 的排序比较器，69–129 |
| `apk_work\kb\src2\TimetableGridV2.kt` | 同款网格源码 |
| `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableScreenKt.java` | jadx 输出，仅作差异对照 |

> **行号校正**：任务里给的 `TimetableGridV2.kt` 行号是估算值，与文件实际不符。实际为：`MorandiPalette` 80–93、`MinCardHeight` 101、`ExpandMargin/ExpandMinWidth/ExpandMinHeight` 174–176、`expandTarget` 191–207、`cellH` 222、卡片纵向循环 535–594（`prevBottom` 550、`naturalTop` 559、`naturalBottom` 562、`top` 563、`h` 564–565、`prevBottom` 更新 566、`paletteColor` 568、`fitTextSize` 571）、`fitTextSize` 726–731、`dayIndexOf` 743–752、`paletteColor` 765–768、`mergeAdjacent` 774–793、`buildTimeRange` 796–805。下文全部使用上述**实际**行号。

---

## 1. `courseOccursInWeek(course: Course, week: Int): Boolean`

### 结论

字节码等价伪代码（寄存器级逐条还原，行号见「证据」）：

```kotlin
private fun courseOccursInWeek(course: Course, week: Int): Boolean {
    if (week <= 0) return false                                   // 9144-9146

    val startWeek = course.startWeek                              // 9150-9152
    val endWeek   = course.endWeek                                // 9154-9156
    if (week > endWeek || startWeek > week) return false           // 9158-9160 → :cond_10 → 9701-9703

    // ---- 第一层：isOdd 字段门禁 ----
    when (course.isOdd) {                                         // 9163-9175
        1    -> if (!isOddWeek(week)) return false                 // :cond_2 9188-9195
        2    -> if (isOddWeek(week))  return false                 // :cond_1 9178-9185
        else -> { /* 不约束 */ }                                   // 9175 goto :goto_0
    }

    // ---- 第二层：weekRange 文本 ----
    if (course.weekRange.isBlank()) return true                    // 9200-9212

    var s = course.weekRange
        .replace(" ", "")    // 9225-9233
        .replace("，", ",")   // 9240-9248   U+FF0C
        .replace("、", ",")   // 9251-9257   U+3001
        .replace("；", ",")   // 9260-9266   U+FF1B
        .replace(";",  ",")  // 9269-9275

    if (!Regex("\\d").containsMatchIn(s)) return true              // 9278-9294（无数字就直接 true）

    val hasOdd  = s.contains("单")                                 // 9298-9306
    val hasEven = s.contains("双")                                 // 9309-9315

    val body = s.replace("周次", "").replace("第", "").replace("周", "")
                .replace("(", "").replace(")", "")
                .replace("单", "").replace("双", "")               // 9322-9402

    val parts = body.split(",").map { it.trim() }.filter { it.isNotEmpty() }   // 9409-9526
    if (parts.isEmpty()) return true                               // 9529-9535

    for (p in parts) {                                             // 9542-9700（Kotlin `any{}` 内联展开）
        if (p.contains("-")) {                                     // 9583-9593
            val ab = p.split("-")                                  // 9596-9610
            if (ab.size != 2) continue                             // 9613-9619
            val a = ab[0].toIntOrNull() ?: continue                // 9623-9637
            val b = ab[1].toIntOrNull() ?: continue                // 9640-9654
            if (!(a <= week && week <= b)) continue                // 9656-9658（闭区间）
        } else {
            val n = p.toIntOrNull() ?: continue                    // 9664-9672
            if (week != n) continue                                // 9674
        }
        // ★ 命中：区间分支与「单个数字」分支共用同一段收尾（:goto_4，9676）
        return if (hasOdd) isOddWeek(week)                         // 9677-9684
               else if (hasEven) !isOddWeek(week)                  // 9687-9696（xor 1）
               else true                                          // 9698-9699
    }
    return false                                                   // :cond_10/:goto_5 9701-9703
}

private fun isOddWeek(week: Int): Boolean = week % 2 == 1           // 10580-10597
```

逐条回答提问：

1. **「单个数字」分支（不含 `-`）到底做了什么？** jadx 渲染成空 body 的那段，真实语义是：
   ```kotlin
   val n = part.toIntOrNull()
   if (n != null && week == n) { /* 跳到 :goto_4，与区间分支共用收尾 */ }
   ```
   即：`toIntOrNull()` 成功且**恰好等于** week 时算命中，随后执行与区间分支**完全相同**的收尾（`hasOdd → isOddWeek(week)` / `hasEven → !isOddWeek(week)` / 否则 `true`，三者都是**直接 return 出整个函数**）。jadx 丢了这段收尾，所以它在 Java 里表现为「命中后什么都不做、循环继续、最后 `return false`」——这是与真机行为相反的地方（见第 6 节）。
2. **区间分支**：`a <= week && week <= b`，**两端都是闭区间**（`if-gt a, week → continue`；`if-gt week, b → continue`）。
3. **`contains("单")` / `contains("双")` 的判定时机**：在「空格 + 分隔符归一化」这 5 步**之后**、在删除 `周次/第/周/(/)/单/双` **之前**；并且在 `Regex("\\d")` 守卫**之后**（无数字已提前 `return true`）。清洗顺序经字节码逐条确认为：`" "→""` → `"，"→","` → `"、"→","` → `"；"→","` → `";"→","`（注意 `、` 也在内，且**没有** `"|"→","`），然后按 `","` 切分 → `trim()` → 丢弃空串。
4. **`isOdd` 语义**：`1` = 单周（要求 `isOddWeek(week) == true`，否则 false）；`2` = 双周（要求 `isOddWeek(week) == false`，否则 false）；`其它值`（含默认 `0`）= 每周/不约束。字节码只确证行为，命名见「不确定项」。
5. **`week <= 0` 返回 `false`**（9144-9146）。

行为要点（易踩坑）：
- 无数字守卫的后果：`weekRange` 若不是空白但**整串不含数字**（例如 `"单周"`、`"第单周"`），函数**直接 `return true`**，其中的单/双字样完全不参与判断。此时只有 `isOdd` 字段那一层在起作用。
- `parts.isEmpty()` 分支（9529-9535，返回 `true`）在数字守卫下**不可达**：数字不会被 `trim()` 或那 7 个 `replace` 删除，故删除后仍含数字 → 按 `","` 切分后至少有一段非空。

### 证据

`apk_work\proj_dec\smali_classes3\kebiaocom\example\ui\TimetableScreenKt.smali`

| 位置 | 关键指令 |
| --- | --- |
| 9137 | `.method private static final courseOccursInWeek(Lkebiaocom/example/data/Course;I)Z`，`.locals 23` |
| 9140-9146 | `move/from16 v0, p1`；`if-gtz v0, :cond_0`；`return v1`（v1=0）→ `week <= 0` 返回 false |
| 9150-9160 | `getStartWeek()`/`getEndWeek()`；`if-gt v0, v3, :cond_10`；`if-gt v2, v0, :cond_10` |
| 9163-9175 | `isOdd()`；`const/4 v3, 0x2`、`const/4 v4, 0x1`；`if-eq v2, v4, :cond_2`；`if-eq v2, v3, :cond_1`；`goto :goto_0` |
| 9178-9185 | `:cond_1`（isOdd==2）：`isOddWeek(p1)`；`if-eqz v2, :cond_3`；`return v1` |
| 9188-9195 | `:cond_2`（isOdd==1）：`isOddWeek(p1)`；`if-nez v2, :cond_3`；`return v1` |
| 9200-9212 | `getWeekRange()`；`StringsKt->isBlank`；`if-eqz v2, :cond_4`；`return v4`（true） |
| 9225-9275 | 5 次 `replace$default`，常量字面量 `" "`、`"\uff0c"`、`"\u3001"`、`"\uff1b"`、`";"` → 均替换为 `","`（首条替换为 `""`），mask 均为 4（ignoreCase 取默认 false） |
| 9278-9294 | `new-instance Regex`，`const-string v5, "\\d"`；`containsMatchIn`；`if-nez v2, :cond_5`；`return v4` |
| 9298-9315 | `const-string v2, "\u5355"`（单）→ `contains$default` → v2；`const-string v7, "\u53cc"`（双）→ `contains$default` → v5；mask=2 |
| 9322-9402 | 7 次 `replace$default`：`"\u5468\u6b21"`(周次)、`"\u7b2c"`(第)、`"\u5468"`(周)、`"("`、`")"`、`"\u5355"`(单)、`"\u53cc"`(双) → 全部替换为 `""` |
| 9409-9421 | `filled-new-array {","}`；`split$default(…, false, 0, 6, …)`（limit=0、mask=6） |
| 9441-9473 | `trim(CharSequence).toString()` 映射 |
| 9496-9522 | `length() > 0` 过滤 |
| 9529-9535 | `List->isEmpty()`；`if-eqz v8, :cond_9`；`return v4` |
| 9542-9570 | `instance-of Collection` + `isEmpty` → `goto/16 :goto_5`（Kotlin `any{}` 内联展开）；迭代器循环 |
| 9583-9619 | `const-string v10, "-"`；`contains`；`if-eqz v11, :cond_d`；`split("-")`；`if-eq v9, v3, :cond_c`（v3=2）；`goto :goto_3` |
| 9623-9658 | `toIntOrNull` ×2；`if-gt v9, v0, :cond_b`；`if-gt v0, v8, :cond_b`；`goto :goto_4` |
| 9663-9674 | `:cond_d`：`toIntOrNull`；`if-ne v0, v8, :cond_b` |
| 9676-9699 | `:goto_4`：`if-eqz v2, :cond_e` → `isOddWeek(p1)` `return`（.line 291）；`if-eqz v5, :cond_f` → `xor-int/2addr v0, v4` `return`（.line 292）；`:cond_f` `return v4` |
| 9701-9704 | `:cond_10`/`:goto_5` `return v1`；`.end method` |
| 10580-10597 | `isOddWeek`：`rem-int/lit8 p0, p0, 0x2`；`const/4 v0, 0x1`；`if-ne p0, v0, :cond_0` → 等价 `week % 2 == 1` |

### 不确定项

- `isOdd` 的**命名语义**（1=单周、2=双周）：字节码只确证行为配对（1 要求 `isOddWeek(week)` 为真、2 要求为假）。命名来自 jadx 旁证，**不是**字节码直接确证：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\reminder\CourseReminderScheduler.java:244-258`（isOdd==1 → `week % 2 != 1` 返回 false；isOdd==2 && `week % 2 != 0` 返回 false）、`...\data\QiangzhiJwxtParser.java:1329-1334`（`单周|(单)` → 1，`双周|(双)` → 2）、`...\ui\AddCourseScreenKt.java:303`（`listOf("全周","单周","双周")`）与 `AddCourseScreenKt$AddCourseScreen$2$1.java:115`（`coerceIn(course.isOdd(), 0, 2)`）。
- `isOddWeek` 对**负数** week 的取模（Java `%` 结果为负，会得到 false）无法通过 `courseOccursInWeek` 观察到——`week <= 0` 已提前返回。该函数是 `private static final`，字节码显示只有 9137/8950 两处调用路径，均受同一守卫保护。
- 「`parts.isEmpty()` 不可达」是我基于「数字守卫 + 7 个 replace 均不删除数字」的推理，字节码本身没有分支可达性信息。

---

## 2. `fitTextSize(configured: Int, heightDp: Float): Int`

### 结论

```kotlin
private fun fitTextSize(configured: Int, heightDp: Float): Int {
    val cap = configured.coerceAtLeast(7)              // max(configured, 7)
    val fit = ((heightDp - 8f) / 5f).toInt()           // 常量 8.0f / 5.0f；toInt() = 向零截断
    return if (fit >= cap) cap else fit.coerceAtLeast(7)   // 即 max(fit, 7)
}
```

- `cap = max(configured, 7)`。
- `fit = ((heightDp - 8f) / 5f).toInt()`，`toInt()` 对应 `float-to-int`（JVM `f2i`），**向零截断**（不是 floor、不是四舍五入）。`heightDp < 8` 时 `fit` 可能为负或 0。
- 最后比较就是 `if (fit >= cap) cap else max(fit, 7)`，**不是**任何别的写法（例如不是 `coerceIn`、不是 `min(cap, max(fit,7))` 的源码写法，但两者等价：结果恒为 `max(7, min(fit, cap))`，且因 `cap >= 7`，返回值恒落在 `[7, cap]`）。

### 证据

`apk_work\proj_dec\smali_classes3\kebiaocom\example\ui\TimetableGridV2Kt.smali:23454-23493`

- 23454：`.method private static final fitTextSize(IF)I`，`.param p0, "configured"`、`.param p1, "heightDp"`
- 23460-23467：`const/4 v0, 0x7`；`RangesKt->coerceAtLeast(II)I`；`.local v1, "cap":I`
- 23468-23479：`const/high16 v2, 0x41000000 # 8.0f`；`sub-float`；`const/high16 v3, 0x40a00000 # 5.0f`；`div-float/2addr`；`float-to-int v2, v2`；`.local v2, "fit":I`
- 23480-23492：`if-lt v2, v1, :cond_11` → `move v0, v1`（返回 cap）；`:cond_11` → `coerceAtLeast(fit, 7)`（v0 恒为 7）

### 不确定项

无。表达式、常量、截断方向与比较方向均可从字节码逐条确证，且与 `apk_work\kb\src2\TimetableGridV2.kt:726-731` 一致；jadx 版 `...\ui\TimetableGridV2Kt.java:4988-4992` 也完全一致。

---

## 3. `dayIndexOf(weekday: String): Int`

### 结论

```kotlin
private fun dayIndexOf(weekday: String): Int = when (weekday) {
    "一" -> 1; "二" -> 2; "三" -> 3
    "四" -> 4; "五" -> 5; "六" -> 6
    "日" -> 7
    else -> 0
}
```

- 输入类型是 **`String`**（不是 `Char`）。
- 映射方式：**整个字符串的精确相等**（`String.hashCode()` 走 sparse-switch，命中后再用 `String.equals` 复核），**不取首字符、不做 trim、不做 substring**。
- 因此：空串 `""` → `0`；`" "` → `0`；`"星期一"`/`"周一"`/`"一 "` → `0`；`"1"` → `0`；其它 → `0`。
- 返回 `0` 的消费端行为见 `apk_work\kb\src2\TimetableGridV2.kt:536`（`val day = dayIndexOf(entry.second)`）与 551（`courses.filter { it.dayOfWeek == day ... }`）：`0` 不会匹配任何课程的 `dayOfWeek`（1..7）。

### 证据

`apk_work\proj_dec\smali_classes3\kebiaocom\example\ui\TimetableGridV2Kt.smali:23087-23246`

- 23087：`.method private static final dayIndexOf(Ljava/lang/String;)I`，`.param p0, "weekday"`
- 23092-23099：`invoke-virtual {p0}, Ljava/lang/String;->hashCode()I`；`sparse-switch v0, :sswitch_data_58`；`:goto_7` → `goto :goto_55`
- 23101-23116：`:sswitch_8`：`"\u65e5"`(日) → `equals`；`if-nez v0, :cond_11`；`:cond_11` `const/4 v0, 0x7`（.line 750）
- 23119-23134：`:sswitch_13`：`"\u56db"`(四) → `const/4 v0, 0x4`（.line 747）
- 23137-23152：`:sswitch_1e`：`"\u516d"`(六) → `const/4 v0, 0x6`（.line 749）
- 23155-23170：`:sswitch_29`：`"\u4e94"`(五) → `const/4 v0, 0x5`（.line 748）
- 23173-23188：`:sswitch_34`：`"\u4e8c"`(二) → `const/4 v0, 0x2`（.line 745）
- 23191-23206：`:sswitch_3f`：`"\u4e09"`(三) → `const/4 v0, 0x3`（.line 746）
- 23209-23224：`:sswitch_4a`：`"\u4e00"`(一) → `const/4 v0, 0x1`（.line 744）
- 23226-23232：`:goto_55` `const/4 v0, 0x0`（.line 751，else 分支）；`:goto_56` `return v0`
- 23236-23245：`.sparse-switch` 键：`0x4e00`(一)、`0x4e09`(三)、`0x4e8c`(二)、`0x4e94`(五)、`0x516d`(六)、`0x56db`(四)、`0x65e5`(日)

### 不确定项

无。七项映射与 else→0 都由 `equals` 复核 + 返回值常量确证；`apk_work\kb\src2\TimetableGridV2.kt:743-752` 与之一致。

---

## 4. `mergeAdjacent(input: List<Course>)` 与 `buildTimeRange(course, timeSlots)`

### 结论 4.1 `mergeAdjacent`

```kotlin
private fun mergeAdjacent(input: List<Course>): List<Course> {
    if (input.isEmpty()) return input                       // 返回同一个实例，不是副本
    val sorted = input.sortedBy { it.startPeriod }           // 升序、稳定
    val out = ArrayList<Course>(sorted.size)
    var cur = sorted[0]
    for (i in 1 until sorted.size) {
        val next = sorted[i]
        val sameCourse = next.name == cur.name &&
                         next.location == cur.location &&
                         next.teacher == cur.teacher      // 只有这 3 个字段
        if (sameCourse && next.startPeriod == cur.endPeriod + 1) {
            cur = cur.copy(endPeriod = next.endPeriod)        // 保留 cur.startPeriod
        } else {
            out.add(cur)
            cur = next
        }
    }
    out.add(cur)
    return out
}
```

- **判等字段**：`name`、`location`、`teacher`（`Intrinsics.areEqual`，null 安全）。**不比较** `dayOfWeek`、`weekRange`、`startWeek`、`endWeek`、`isOdd`、`color`、`id`。
- **合并条件**：必须 **`next.startPeriod == cur.endPeriod + 1`**（严格相邻，缺一节就断开）。
- **排序**：按 `startPeriod` 升序（比较器用 `getStartPeriod()` + `ComparisonsKt.compareValues`）；`sortedWith` 走 `Collections.sort`，**稳定**——`startPeriod` 相同的元素保持输入顺序。
- **合并后**：保留 `cur.startPeriod`，`endPeriod` 取 `next.endPeriod`（`copy` 只改这一个字段）。
- 空输入**原样返回传入的 List 引用**。
- 行为要点：由于只比 3 个字段，同名/同地点/同老师但 `weekRange` 或单双周设置不同的两门课，只要节次相邻就会被并成一张卡。

### 结论 4.2 `buildTimeRange`

```kotlin
private fun buildTimeRange(course: Course, timeSlots: List<String>): String {
    val first = timeSlots.getOrNull(course.startPeriod - 1)?.substringBefore("-")?.trim() ?: ""
    val last  = timeSlots.getOrNull(course.endPeriod   - 1)?.substringAfter("-")?.trim()  ?: ""
    return when {
        first.isEmpty() && last.isEmpty() -> ""
        first.isEmpty() -> last
        last.isEmpty()  -> first
        else -> "$first-$last"
    }
}
```

- `startPeriod`/`endPeriod` 为 **1-based**，索引取 `- 1`；用 **`getOrNull`**（越界或负索引返回 null，不抛异常）。
- 越界 / `timeSlots` 为空 → `getOrNull` 返回 null → 对应字段为 `""`；两者都空 → 返回 `""`；只有一端可用则返回那一段（不加 `-`）；两端都有 → `"first-last"`。
- `substringBefore("-")` / `substringAfter("-")` 用默认 `missingDelimiterValue`（分隔符不存在时返回原串），随后 `trim()`。

### 证据

`apk_work\proj_dec\smali_classes3\kebiaocom\example\ui\TimetableGridV2Kt.smali`（`mergeAdjacent`）

| 位置 | 关键指令 |
| --- | --- |
| 23586-23608 | `.method private static final mergeAdjacent(Ljava/util/List;)Ljava/util/List;`；`List->isEmpty()`；`if-eqz v0, :cond_7`；`return-object p0`（返回入参本身） |
| 23611-23637 | `sortedWith(Iterable, Comparator)`（`sortedBy` 内联）；`.local v0, "sorted"` |
| 23621-23627 | `new-instance TimetableGridV2Kt$mergeAdjacent$$inlined$sortedBy$1`；`CollectionsKt->sortedWith` |
| 23638-23647 | `new ArrayList(sorted.size())`；`.local v1, "out"` |
| 23648-23657 | `const/4 v2, 0x0`；`get(0)`；`.local v3, "cur"` |
| 23658-23666 | `const/4 v4, 0x1`（i=1）；`if-ge v4, v5, :cond_98` |
| 23668-23678 | `get(i)`；`.local v21, "next"` |
| 23679-23737 | `getName()`/`getName()` → `Intrinsics->areEqual`；`getLocation()`/`getLocation()` → `areEqual`；`getTeacher()`/`getTeacher()` → `areEqual`；`.local v22, "sameCourse"` |
| 23738-23750 | `if-eqz v22, :cond_90`；`next.getStartPeriod()`；`cur.getEndPeriod()`；`add-int/2addr v8, v7`（+1）；`if-ne v6, v8, :cond_90` |
| 23752-23789 | `next.getEndPeriod()` 放入 v13（= `copy$default` 的 `endPeriod` 形参位）；`const/16 v19, 0xfbf`（mask，仅 bit 64 清零 → 只改 endPeriod）；`Course->copy$default(...)` |
| 23792-23796 | `:cond_90`：`ArrayList->add(cur)`；`move-object/from16 v3, v21`（cur = next） |
| 23806-23816 | `:cond_98`：`add(cur)`；`check-cast v2, List`；`return-object v2` |

`...\TimetableGridV2Kt$mergeAdjacent$$inlined$sortedBy$1.smali:69-129`：`compare(Object,Object)` 内两次 `Course->getStartPeriod()` 后 `ComparisonsKt->compareValues(Comparable, Comparable)`。

`apk_work\proj_dec\smali_classes3\kebiaocom\example\ui\TimetableGridV2Kt.smali`（`buildTimeRange`，22815-23039）

| 位置 | 关键指令 |
| --- | --- |
| 22830-22843 | `.line 797`；`getStartPeriod()`；`const/4 v1, 0x1`；`sub-int/2addr v0, v1`；`CollectionsKt->getOrNull(List, I)`；`check-cast String` |
| 22845-22874 | `const/4 v2, 0x2`、`const-string v3, "-"`、`const-string v4, ""`；`if-eqz v0, :cond_26`；`StringsKt->substringBefore$default(String, String, String, I, Object)`（mask=2）；`if-eqz v0, :cond_26`；`StringsKt->trim`；`:cond_26 move-object v0, v4`；`.local v0, "first"` |
| 22879-22912 | `.line 798`；`getEndPeriod()`；`sub-int/2addr v6, v1`；`getOrNull`；`substringAfter$default`；`trim`；`:cond_46 move-object v2, v4`；`.local v2, "last"` |
| 22919-22962 | `.line 800`：`first.length()==0 && last.length()==0` → `goto :goto_9a`（返回 v4=""） |
| 22964-22988 | `.line 801`：`first` 空 → 返回 `last` |
| 22990-23012 | `.line 802`：`last` 空 → 返回 `first` |
| 23014-23038 | `.line 803`：`StringBuilder` 拼 `first + "-" + last`；`:goto_9a return-object v4` |

### 不确定项

- `mergeAdjacent` 的 `sortedBy` 稳定性：字节码只显示调用 `CollectionsKt->sortedWith`（其实现最终为 `Collections.sort`，Java TimSort 稳定）。「稳定」是对 JDK/ART 实现的依赖，字节码本身不携带该信息。
- `Course.copy` 的形参顺序（`endPeriod` 位于 `copy$default` 第 7 个字段位）由 `Course` 构造签名推定（`id,name,teacher,location,dayOfWeek,startPeriod,endPeriod,color,weekRange,startWeek,endWeek,isOdd`），与 mask `0xfbf`（bit 64 清零）互相印证；未逐条反查 `Course.smali` 的构造器。
- `buildTimeRange` 无其它不确定项（`getOrNull` 的越界语义由 `CollectionsKt->getOrNull` 定义）。

---

## 5. 课表卡片的纵向几何、`expandTarget`、`paletteColor`、`MorandiPalette`

### 结论 5.1 纵向几何（每天的列内累计，`apk_work\kb\src2\TimetableGridV2.kt:535-594` 的实际字节码）

```kotlin
val cellH: Dp = settings.courseCellHeightDp.dp          // 每个面板固定一档行高

var prevBottom = 0.dp                                    // 每个 day 列 / 每个 ScheduleBlock 内部重置
mergeAdjacent(courses.filter { it.dayOfWeek == day && it.endPeriod >= startPeriod && it.startPeriod <= endPeriod })
    .forEach { raw ->
        val start = raw.startPeriod.coerceIn(startPeriod, endPeriod)
        val end   = raw.endPeriod.coerceIn(start, endPeriod)

        val naturalTop    = cellH * (start - startPeriod)
        val naturalBottom = cellH * (end - startPeriod + 1) - CardGap

        val top = if (naturalTop < prevBottom) prevBottom + CardGap else naturalTop
        var h   = naturalBottom - top
        if (h < MinCardHeight) h = MinCardHeight          // 下限；无上限
        prevBottom = top + h
    }
```

- `cellH = settings.courseCellHeightDp.dp`（把用户设置的**行高**整体当作一节的高度）。
- `naturalTop = cellH * (start - startPeriod)`（Dp 乘法）。
- `naturalBottom = cellH * (end - startPeriod + 1) - CardGap`（注意 `+ 1` 是闭区间补偿；`CardGap` 从**底边**扣）。
- `top`：当 `naturalTop < prevBottom`（与上一张卡重叠）时改为 `prevBottom + CardGap`，否则用 `naturalTop`。这就是「卡与卡之间必定留 5dp 且永不重叠」的机制。
- `h = naturalBottom - top`；`if (h < MinCardHeight) h = MinCardHeight`。
- `prevBottom = top + h`（用**实际**绘制后的底边，含被夹到下限后的高度）。
- 常量（均来自 `<clinit>`）：`CardGap = 5.dp`、`MinCardHeight = 12.dp`。卡片高度**下限 12.dp，没有上限**（上限只受 `naturalBottom` 约束）。
- 起始值 `prevBottom = 0.dp` 在每个 day 列/每个时间区块的循环内声明一次。

### 结论 5.2 `expandTarget`

```kotlin
private val ExpandMargin: Dp = 14.dp      // 174
private val ExpandMinWidth: Dp = 190.dp   // 175
private val ExpandMinHeight: Dp = 196.dp  // 176

private fun expandTarget(origin: Rect, boxW: Float, boxH: Float, density: Density): Rect {
    val margin = with(density) { ExpandMargin.toPx() }     // 14dp → px
    val minW   = with(density) { ExpandMinWidth.toPx() }   // 190dp → px
    val needH  = with(density) { ExpandMinHeight.toPx() }  // 196dp → px
    val maxW = (boxW - margin * 2f).coerceAtLeast(origin.width)
    val maxH = (boxH - margin * 2f).coerceAtLeast(origin.height)

    var w = (origin.width * 1.8f).coerceAtMost(maxW)
    if (w < minW) w = minW.coerceAtMost(maxW)
    val h = (origin.height * 1.85f).coerceAtLeast(needH).coerceAtMost(maxH)

    val cx = (origin.left + origin.right) / 2f
    val cy = (origin.top + origin.bottom) / 2f
    val left = (cx - w / 2f).coerceIn(margin, (boxW - w - margin).coerceAtLeast(margin))
    val top  = (cy - h / 2f).coerceIn(margin, (boxH - h - margin).coerceAtLeast(margin))
    return Rect(left, top, left + w, top + h)
}
```

- 放大倍率：宽 `× 1.8f`、高 `× 1.85f`（**不相等**）。
- 宽先夹到 `maxW`，再在小于 `minW` 时用 `min(minW, maxW)` 顶上来；高先 `coerceAtLeast(needH)` 再夹到 `maxH`。
- 目标矩形以**原卡片中心**为中心，左右/上下各用 `coerceIn(margin, max(box − size − margin, margin))` 推回屏内。
- 三个 dp 值：`ExpandMargin = 14.dp`、`ExpandMinWidth = 190.dp`、`ExpandMinHeight = 196.dp`。

### 结论 5.3 `paletteColor` 与 `MorandiPalette`

```kotlin
private fun paletteColor(name: String): Int {
    val h = if (name.isEmpty()) 0 else name.hashCode() and 0x7fffffff
    return MorandiPalette[h % MorandiPalette.size]     // size == 12
}
```

`MorandiPalette` 共 **12** 项，顺序与 ARGB 值（`smali` 使用等价的负数 int 字面量）：

| # | smali 常量 | ARGB |
| --- | --- | --- |
| 0 | `-0x575740` | `0xFFA8A8C0` |
| 1 | `-0x53583b` | `0xFFACA7C5` |
| 2 | `-0x586a5b` | `0xFFA795A5` |
| 3 | `-0xbabcb0` | `0xFF454350` |
| 4 | `-0x868399` | `0xFF797C67` |
| 5 | `-0x365584` | `0xFFC9AA7C` |
| 6 | `-0x25534a` | `0xFFDAACB6` |
| 7 | `-0x2e2426` | `0xFFD1DBDA` |
| 8 | `-0x414552` | `0xFFBEBAAE` |
| 9 | `-0x72765e` | `0xFF8D89A2` |
| 10 | `-0x483f4e` | `0xFFB7C0B2` |
| 11 | `-0x374b58` | `0xFFC8B4A8` |

取色只在**优化模式关闭**时使用：`if (optimize) cardTint else paletteColor(name)`（`apk_work\kb\src2\TimetableGridV2.kt:543-545, 568`）。

### 证据

纵向几何（`apk_work\proj_dec\smali_classes3\kebiaocom\example\ui\TimetableGridV2Kt.smali`）

| 位置 | 关键指令 |
| --- | --- |
| 15483-15504 | `.line 222`；`AppSettings->getCourseCellHeightDp()I`；`const/4 v1, 0x0`；`int-to-float`；`Dp->constructor-impl(F)F`；`.local v8, "cellH":F` |
| 14205 | `move/from16 v15, p0`（v15 = 面板的 `startPeriod`；v14 = `endPeriod`） |
| 14226 | `TimetableGridV2Kt->mergeAdjacent(List)List`（.line 551） |
| 14363-14381 | `getStartPeriod()` → `RangesKt->coerceIn(III)`（v15, v14）→ `.local v0, "start"`；`getEndPeriod()` → `coerceIn(start, endPeriod)` → `.local v8, "end"` |
| 14387-14412 | `.line 559`；`sub-int v5, v0, v15`；`const/16 v91, 0x0`（`times-u2uoSUM`）；`int-to-float v0, v5`；`mul-float v0, v0, p8`（p8 = `cellH`）；`Dp->constructor-impl`；`.local v0, "naturalTop":F` |
| 14413-14460 | `.line 562`；`sub-int v5, v8, v15`；`const/16 v91, 0x1`；`add-int/lit8 v5, v5, 0x1`；`int-to-float`；`mul-float v8, v8, p8`；`Dp->constructor-impl`；`sget v8, …->CardGap:F`；`sub-float v92, v5, v8`；`.local v5, "naturalBottom":F` |
| 14461-14492 | `.line 563`；`Dp->compareTo-0680j_4(naturalTop, prevBottom)`；`if-gez v8, :cond_a47`；重叠时 `sget CardGap`；`add-float`（`prevBottom + CardGap`）；`:cond_a47 move v8, v0` |
| 14495-14511 | `.line 564`；`sub-float v92, v5, v8`；`Dp->constructor-impl`；`.local v92, "h":F` |
| 14517-14535 | `.line 565`；`sget v0, …->MinCardHeight:F`；`Dp->compareTo-0680j_4(h, MinCardHeight)`；`if-gez v0, :cond_a65`；`:cond_a65` 前 `sget v92, MinCardHeight`；`move/from16 v2, v92` |
| 14538-14554 | `.line 566`；`add-float v92, v8, v2`（top + h）；`Dp->constructor-impl`；`.local "prevBottom":F` |
| 14562-14582 | `.line 568`：优化模式开 → `cardTint`；关 → `Course->getName()` + `paletteColor(String)I` |
| 14597-14603 | `.line 571`：`AppSettings->getCourseTextSizeSp()I` → `fitTextSize(IF)I` |
| 450-466 | `<clinit>`：`const/4 v0, 0x5` → `CardGap`（= 5.dp） |
| 469-485 | `<clinit>`：`const/16 v0, 0xc` → `MinCardHeight`（= 12.dp） |

`expandTarget`（同文件 23248-23452）

| 位置 | 关键指令 |
| --- | --- |
| 23256-23268 | `sget v2, …->ExpandMargin:F`；`Density->toPx-0680j_4(F)F`；`.local v0, "margin":F` |
| 23273-23289 | `sget v3, …->ExpandMinWidth:F`；`toPx`；`.local v1, "minW":F` |
| 23290-23306 | `sget v4, …->ExpandMinHeight:F`；`toPx`；`.local v2, "needH":F` |
| 23307-23322 | `const/high16 v3, 0x40000000 # 2.0f`；`mul-float v4, v0, v3`；`sub-float v4, p1, v4`；`Rect->getWidth()`；`coerceAtLeast(FF)`；`.local v4, "maxW":F` |
| 23323-23336 | 同构：`boxH - 2*margin` vs `Rect->getHeight()` → `.local v5, "maxH":F` |
| 23337-23350 | `Rect->getWidth()`；`const v7, 0x3fe66666 # 1.8f`；`mul-float`；`coerceAtMost(maxW)`；`.local v6, "w":F` |
| 23351-23360 | `cmpg-float v7, v6, v1`；`if-gez v7, :cond_49`；`coerceAtMost(minW, maxW)` |
| 23361-23378 | `Rect->getHeight()`；`const v8, 0x3feccccd # 1.85f`；`coerceAtLeast(needH)`；`coerceAtMost(maxH)`；`.local v7, "h":F` |
| 23379-23405 | `getLeft()+getRight()` / 2 → `.local v8, "cx"`；`getTop()+getBottom()` / 2 → `.local v9, "cy"` |
| 23407-23424 | `cx - w/2`；`(boxW - w - margin).coerceAtLeast(margin)`；`coerceIn(margin, …)`；`.local v10, "left":F` |
| 23425-23442 | 同构（`boxH`, `h`）→ `.local v3, "top":F` |
| 23443-23451 | `new-instance Rect`，`(left, top, left+w, top+h)`；`return-object` |
| 525-542 | `<clinit>`：`const/16 v0, 0xe` → `ExpandMargin`（= 14.dp） |
| 544-561 | `<clinit>`：`const/16 v0, 0xbe` → `ExpandMinWidth`（= 190.dp） |
| 563-580 | `<clinit>`：`const/16 v0, 0xc4` → `ExpandMinHeight`（= 196.dp） |

`paletteColor` 与调色板（同文件）

| 位置 | 关键指令 |
| --- | --- |
| 23857-23896 | `.method private static final paletteColor(Ljava/lang/String;)I`；`CharSequence->length()`；`if-nez v0, :cond_c` → `const/4 v0, 0x1`（空串走 `goto :goto_18`）；`:cond_10` `String->hashCode()`；`const v1, 0x7fffffff`；`and-int/2addr`；`.local v0, "h":I` |
| 23898-23918 | `sget-object v1, …->MorandiPalette:Ljava/util/List;`；`size()`；`rem-int v2, v0, v2`；`get(v2)`；`Number->intValue()`；`return` |
| 198-200 | `<clinit>`：`const/16 v0, 0xc`；`new-array v0, v0, [Ljava/lang/Integer;`（12 项） |
| 202-235 | 下标 0 `-0x575740`、1 `-0x53583b`、2 `-0x586a5b` |
| 241-249 | 下标 3 `-0xbabcb0` |
| 255-263 | 下标 4 `-0x868399` |
| 269-277 | 下标 5 `-0x365584` |
| 283-291 | 下标 6 `-0x25534a` |
| 297-305 | 下标 7 `-0x2e2426` |
| 311-319 | 下标 8 `-0x414552` |
| 325-333 | 下标 9 `-0x72765e` |
| 339-347 | 下标 10 `-0x483f4e` |
| 353-361 | 下标 11 `-0x374b58` |
| 366-371 | `CollectionsKt->listOf`；`sput-object …->MorandiPalette` |

### 不确定项

- `settings.courseCellHeightDp` 的**默认值/取值范围**不在本节函数内，字节码只确证 `cellH = 该设置的 dp`（未展开 `AppSettings` 与设置界面）。同理 `settings.courseTextSizeSp` 只确证被传入 `fitTextSize`。
- `origin` / `boxW` / `boxH` 的坐标空间（根坐标系、网格盒）来自 `apk_work\kb\src2\TimetableGridV2.kt:178-190` 的注释，字节码本身不含坐标系语义。
- `paletteColor` 的 `h % 12`：`h` 已被 `and 0x7fffffff` 保证非负，故不存在负下标；这一点由 23893 的 `and-int` 直接确证。
- `Rect` 的 `right/bottom` 语义（`left + w` / `top + h`，即非闭区间表示）由 23445-23449 的四参构造确证，无不确定。

---

## 6. 与 Java 反编译的差异

只列 jadx 输出**丢失或可能失真**的地方。

1. **`courseOccursInWeek` 的「单个数字」分支被清空（最危险）**
   `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableScreenKt.java:431-437`：
   ```java
   } else {
       Integer intOrNull3 = StringsKt.toIntOrNull(str2);
       if (intOrNull3 != null && i == intOrNull3.intValue()) {
           if (!contains$default) {
           }
       }
   }
   ```
   判断条件还在，**整个 body 只剩一个空的 `if (!contains$default) { }`**，被丢掉的正是 smali `9676-9699`（`:goto_4`）的收尾：`if (hasOdd) return isOddWeek(i); else if (hasEven) return !isOddWeek(i); else return true;`。
   后果：对形如 `"1,3,5"`（只有裸周次、没有 `-`）的 `weekRange`，jadx 版会走到 `TimetableScreenKt.java:441` 的 `return false`，即判定「该课本周不出现」；真机在命中周次时返回 `true`（无单双字样时）。**按 jadx 版实现会漏掉整门课。**
2. **同一段收尾在区间分支里又「反写」成另一种形状**
   `TimetableScreenKt.java:419-425` 写成
   ```java
   if (!contains$default) { return isOddWeek(i); }
   if (contains$default2) { return !isOddWeek(i); }
   return true;
   ```
   这与 smali `if (hasOdd) … else if (hasEven) … else …` 语义**等价**（`!hasOdd` 与 `else` 同义），但形状不同：单看 Java 会以为「单」「双」可以同时成立且单优先。真正的判定顺序以 smali 为准（`单` 优先）。
3. **`any{}` 内联产物易被误读为冗余检查**
   `TimetableScreenKt.java:404-410` 里 `if (arrayList3.isEmpty()) return true;` 紧接 `if (!(arrayList4 instanceof Collection) || !arrayList4.isEmpty())`。后半句是 Kotlin `any{}` 的内联展开（对应 smali `9542-9556`），并非重复判断；`isEmpty() → return true` 才是源码里的显式分支（smali `9529-9535`）。此处 jadx **没有丢语义**，但极易被当成可以删掉的冗余代码。
4. **可见性失真**
   真机 `courseOccursInWeek` 是 `private static final`（smali 9137），jadx 输出为 `public static final`（Java `366`）。原因是 Kotlin `private` + 内联调用生成了合成桥 `access$courseOccursInWeek`（smali 8950）。用 jadx 版判断可见性/调用点会得出错误结论。
5. **`dayIndexOf` 的 switch 被 jadx 明确标记为无法还原**
   `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableGridV2Kt.java:5014-5020` 带有
   `JADX WARN: Can't fix incorrect switch cases order, some code will duplicate` 与
   `JADX WARN: Failed to restore switch over string`，并附 `Code decompiled incorrectly, please refer to instructions dump.`。逐 case 核对后**返回值本身与 smali 一致**（如 `case 19968: return !weekday.equals("一") ? 0 : 1;`、`case 19977: … return 3;`，键 `19968 = 0x4e00`、`19977 = 0x4e09`），但该处已被 jadx 自己标记为不可信区域。
6. **无差异的对照项（供参考，避免过度怀疑）**
   - `fitTextSize`：`TimetableGridV2Kt.java:4988-4992` 与 smali `23454-23493` 完全一致。
   - `buildTimeRange`：`TimetableGridV2Kt.java:5116-5138` 与 smali `22815-23039` 一致（`getOrNull` + `substringBefore/After` + 四种组合都保留）。
   - `mergeAdjacent`：`TimetableGridV2Kt.java:5106` 的 `copy` 调用只改 `endPeriod`，与 smali mask `0xfbf` 一致。
   - `TimetableScreenKt.java:368-380`（`i <= 0` 早返回、闭区间、isOdd 门禁）与 smali `9144-9195` 一致；`.line` 映射显示这段 Kotlin 源码位于 243–245 行附近。

---

## 附：5 问确证情况一览

| 问题 | 结论 | 是否由字节码确证 |
| --- | --- | --- |
| 1 `courseOccursInWeek` 全流程（含裸数字分支、单双判定时机、清洗顺序、闭区间、`week<=0`） | 见第 1 节 | ✅ 全部确证（`isOdd` 的取名靠 jadx 旁证；`parts.isEmpty()` 分支不可达属推理） |
| 2 `fitTextSize` 精确表达式 | 见第 2 节 | ✅ 确证 |
| 3 `dayIndexOf` 输入类型与映射 | 见第 3 节 | ✅ 确证 |
| 4 `mergeAdjacent` 判等/合并条件 + `buildTimeRange` | 见第 4 节 | ✅ 确证（排序稳定性依赖 JDK/ART 实现；`Course.copy` 形参位序由 mask 互证） |
| 5 卡片纵向几何、`expandTarget`、`paletteColor`、12 个 ARGB | 见第 5 节 | ✅ 确证（`courseCellHeightDp` 默认值在别处，未展开） |

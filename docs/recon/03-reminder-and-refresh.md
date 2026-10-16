# 03 · 上课提醒（Course Reminder）与课表自动刷新（Timetable Auto Refresh）——反编译源码逐字提取

> 目的：为 iOS（`UserNotifications` + `BGTaskScheduler`）等价实现提供**逐字**业务规格。
> 来源：jadx 反编译产物 `上课早枝道-源码-1.11.5/app/src/main/java/...`（Kotlin → Java，`/* compiled from: XXX.kt */`）。
> 真实运行行为以 **APK 内清单** `apk_work/proj_dec/AndroidManifest.xml` 为准（见 §10 的清单版本差异）。
> 每条给出**文件路径 + 行号 + 原样代码片段 + iOS 对应机制/限制**。无法确证的写 `// 不确定：…`，不编造。
> 生成时间基准版本：1.11.5（`app_release`）。

---

## 0. 关键结论速览（TL;DR）

| 项 | Android 实现（确切值） | iOS 替代 |
|---|---|---|
| 提醒触发时刻 | 上课时刻 **向前** `max(classReminderMinutes, 1)` 分钟 | `UNCalendarNotificationTrigger` / `UNTimeIntervalNotificationTrigger` |
| 时刻来源 | **profile.periodTimes**（非 `PeriodTime` 单例、非 timeSlots 字符串字段）→ `start` 字符串 `"HH:mm"`，取 `-` 前缀 | 同一份 `periodTimes` 数据模型即可 |
| 调度 API | `AlarmManager.setExactAndAllowWhileIdle(0, t, pi)`，catch 回退 `setAndAllowWhileIdle` | 无精确闹钟；`UNUserNotificationCenter` + BGTask |
| 请求码 | `abs((courseId + "_" + triggerMillis).hashCode())` | 无 requestCode 概念；用 `identifier` 字符串 |
| 调度窗口 | **未来 15 天**（`while (i2 < 15)`） | iOS 待发通知上限 **64** 条 → 需滚动窗口 + 重算 |
| 去重/取消 | **每次全量** `cancelAll`（按保存的 id 列表逐个 cancel）后重建 | 同策略：`removeAllPendingNotificationRequests()` 后重建 |
| 自动刷新 | **不是** `PeriodicWorkRequest`；是 `setAlarmClock` 定时（01:00 / 13:00）→ 入队 `OneTimeWorkRequest` | `BGAppRefreshTask`（不保证准点）+ 本地通知兜底 |
| 刷新时刻 | 本地时间 **hour=1**（REQ_01=774401）、**hour=13**（REQ_13=774413），minute=0 | `BGAppRefreshTaskRequest(earliestBeginDate:)`，系统不保证 01:00/13:00 |
| 开机重建 | `BOOT_COMPLETED` → `rescheduleFromStorage()`；另外 `Application.onCreate` 每次都重建 | iOS 无开机广播；靠 `BGTaskScheduler` 注册 + 前台重算 |
| 强提醒 | 独立 Activity，清单 `showOnLockScreen/turnScreenOn` + 响铃震动循环 | 无法全屏接管锁屏；用 `interruptionLevel: .critical`/`.timeSensitive` + 通知声音 |

---

## 1. 提醒触发时间（提前几分钟 + 如何由 startPeriod 推出时刻）

### 1.1 提前分钟数常量

配置字段 `classReminderMinutes`，**默认 10**，来自 Kotlin 默认参数（`AppSettings` 合成构造器位掩码 `262144`）。

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/data/AppSettings.java:264`

```java
public /* synthetic */ AppSettings(int i, String str, int i2, int i3, int i4, String str2, String str3, int i5, boolean z, boolean z2, boolean z3, boolean z4, boolean z5, boolean z6, boolean z7, String str4, boolean z8, String str5, int i6, int i7, int i8, int i9, int i10, int i11, boolean z9, boolean z10, boolean z11, int i12, DefaultConstructorMarker defaultConstructorMarker) {
    this((i12 & 1) != 0 ? 1 : i, (i12 & 2) != 0 ? null : str, (i12 & 4) != 0 ? 12 : i2, (i12 & 8) != 0 ? 45 : i3, (i12 & 16) != 0 ? 10 : i4, (i12 & 32) != 0 ? "08:00" : str2, (i12 & 64) == 0 ? str3 : null, (i12 & 128) != 0 ? 20 : i5, (i12 & 256) != 0 ? false : z, (i12 & 512) != 0 ? false : z2, (i12 & 1024) != 0 ? false : z3, (i12 & 2048) != 0 ? false : z4, (i12 & 4096) != 0 ? false : z5, (i12 & 8192) != 0 ? true : z6, (i12 & 16384) != 0 ? false : z7, (i12 & 32768) != 0 ? "default" : str4, (i12 & 65536) != 0 ? false : z8, (i12 & 131072) != 0 ? "weak" : str5, (i12 & 262144) != 0 ? 10 : i6, (i12 & 524288) != 0 ? 45 : i7, (i12 & 1048576) != 0 ? 100 : i8, (i12 & 2097152) != 0 ? 100 : i9, (i12 & 4194304) != 0 ? 69 : i10, (i12 & 8388608) != 0 ? 10 : i11, (i12 & 16777216) != 0 ? true : z9, (i12 & 33554432) != 0 ? true : z10, (i12 & AccessibilityEventCompat.TYPE_VIEW_TARGETED_BY_SCROLL) != 0 ? true : z11);
}
```

字段声明与 getter：`AppSettings.java:18` `private final int classReminderMinutes;`、`AppSettings.java:319-321` `getClassReminderMinutes()`。

**iOS 对应**：直接映射为 `reminderLeadMinutes: Int = 10`；iOS 无最小值限制，但需与 Android 的「至少 1 分钟」钳制保持一致（见 1.3）。

### 1.2 时刻来源：走 profile.periodTimes，**不**走 PeriodTime 单例、**不**走 timeSlots 字段

`scheduler` 先把当前选中 profile 的 `periodTimes` 按 `index` 升序排序，再拼成 `"start-end"` 字符串列表：

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/CourseReminderScheduler.java:260-289`

```java
private final List<String> getEffectiveTimeSlots(AppSettings settings, List<TimetableProfile> profiles) {
    Object obj;
    Iterator<T> it = profiles.iterator();
    while (true) {
        if (!it.hasNext()) {
            obj = null;
            break;
        }
        obj = it.next();
        if (Intrinsics.areEqual(((TimetableProfile) obj).getId(), settings.getSelectedTimetableProfileId())) {
            break;
        }
    }
    TimetableProfile timetableProfile = (TimetableProfile) obj;
    if (timetableProfile == null || !(!timetableProfile.getPeriodTimes().isEmpty())) {
        return CollectionsKt.emptyList();
    }
    List<PeriodTime> sortedWith = CollectionsKt.sortedWith(timetableProfile.getPeriodTimes(), new Comparator() { // from class: kebiaocom.example.reminder.CourseReminderScheduler$getEffectiveTimeSlots$$inlined$sortedBy$1
        @Override // java.util.Comparator
        public final int compare(T t, T t2) {
            return ComparisonsKt.compareValues(Integer.valueOf(((PeriodTime) t).getIndex()), Integer.valueOf(((PeriodTime) t2).getIndex()));
        }
    });
    ArrayList arrayList = new ArrayList(CollectionsKt.collectionSizeOrDefault(sortedWith, 10));
    for (PeriodTime periodTime : sortedWith) {
        arrayList.add(periodTime.getStart() + "-" + periodTime.getEnd());
    }
    return arrayList;
}
```

注意三个硬约束：
1. 必须能找到 `settings.selectedTimetableProfileId` 对应的 profile（默认 `"default"`，见 §8）；
2. 该 profile 的 `periodTimes` **不能为空**，否则直接 `return emptyList()` → `rescheduleAll` 早退，**一条提醒都不排**（`CourseReminderScheduler.java:55-57`）；
3. 索引关系是 `effectiveTimeSlots[startPeriod - 1]`。

**iOS 对应**：同一份数据模型（profile → periodTimes[index].start/end）。iOS 侧建议直接存 `[(index:Int, start:String, end:String)]`，排序与索引语义完全照抄。

### 1.3 由 startPeriod → 具体时刻（完整表达式）

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/CourseReminderScheduler.java:80-89`

```java
String str = (String) CollectionsKt.getOrNull(effectiveTimeSlots, course2.getStartPeriod() - 1);
if (str != null && (parseMinute = INSTANCE.parseMinute(StringsKt.substringBefore$default(str, "-", (String) null, 2, (Object) null))) != null) {
    int intValue = parseMinute.intValue();
    Object clone = calendar2.clone();
    Intrinsics.checkNotNull(clone, "null cannot be cast to non-null type java.util.Calendar");
    Calendar calendar3 = (Calendar) clone;
    calendar3.set(11, intValue / 60);
    calendar3.set(12, intValue % 60);
    calendar3.add(12, -RangesKt.coerceAtLeast(settings.getClassReminderMinutes(), 1));
    if (calendar3.getTimeInMillis() > calendar.getTimeInMillis()) {
```

逐步语义（**逐字**）：

1. `str = effectiveTimeSlots[course.startPeriod - 1]`（越界返回 `null`，该课跳过）；
2. `str.substringBefore("-")` → `"HH:mm"`；`parseMinute` 解析：

   出处：`CourseReminderScheduler.java:171-182`

    ```java
    private final Integer parseMinute(String hhmm) {
        Integer intOrNull;
        List split$default = StringsKt.split$default((CharSequence) StringsKt.trim((CharSequence) hhmm).toString(), new String[]{":"}, false, 0, 6, (Object) null);
        if (split$default.size() == 2 && (intOrNull = StringsKt.toIntOrNull((String) split$default.get(0))) != null) {
            int intValue = intOrNull.intValue();
            Integer intOrNull2 = StringsKt.toIntOrNull((String) split$default.get(1));
            if (intOrNull2 != null) {
                return Integer.valueOf((intValue * 60) + intOrNull2.intValue());
            }
        }
        return null;
    }
    ```
    → 返回**当日零点起的分钟数**（`hh*60+mm`）；解析失败（不是 `a:b` 两段数字）返回 `null`，该课跳过。
3. 以「今天 + i 天」的 `Calendar` 为底（时刻字段已被清成 `00:00:00.000`，见 `CourseReminderScheduler.java:63-66`）；
4. `set(Calendar.HOUR_OF_DAY=11, minute/60)`、`set(Calendar.MINUTE=12, minute%60)`；
5. `add(Calendar.MINUTE=12, -coerceAtLeast(classReminderMinutes, 1))` ← **提前量在此扣除，且下限为 1 分钟**；
6. **只有当触发时刻严格晚于 `now`（`calendar` = `Calendar.getInstance()`，见 `:58`）才排程**。

**iOS 对应**：`triggerDate = 当天零点 + startMinutes - max(lead,1) 分钟`；仅当 `triggerDate > Date()` 时创建 `UNNotificationRequest`。注意 iOS 的 `UNCalendarNotificationTrigger` 对「过去时刻」不会立即触发，必须与 Android 一样自行过滤过去时间。

### 1.4 调度窗口：未来 15 天

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/CourseReminderScheduler.java:58-69`

```java
Calendar calendar = Calendar.getInstance();
ArrayList arrayList = new ArrayList();
int i = 0;
int i2 = 0;
while (i2 < 15) {
    Calendar calendar2 = Calendar.getInstance();
    calendar2.add(6, i2);
    calendar2.set(13, i);
    calendar2.set(14, i);
    Intrinsics.checkNotNull(calendar2);
    int mondayBasedDay = toMondayBasedDay(calendar2);
    int calculateTeachingWeek = calculateTeachingWeek(settings.getFirstWeekStartDate(), calendar2);
```

- `i = 0` 即秒、毫秒清零；`i2` = dayOffset，范围 `0..14`（共 15 天）；
- 这里的 `15` 是**内联字面量**，没有命名常量；
- `calendar2` 保留当天的时/分（随后在 1.3 第 3 步被覆盖），但**保留了 DayOfWeek/日期**，这是「按星期几+教学周筛选课程」的基准。

**iOS 对应**：iOS 待发本地通知硬上限 64 条，不能照抄 15 天 × 全部课程。建议：滚动窗口（如 7 天）+ 每次前台/后台刷新时重算，并用 `identifier = "rem_<courseId>_<epochMinute>"` 做幂等。

### 1.5 星期映射（周一=1 … 周日=7）

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/CourseReminderScheduler.java:184-202`

```java
private final int toMondayBasedDay(Calendar cal) {
    switch (cal.get(7)) {
        case 1:
            return 7;
        case 2:
        default:
            return 1;
        case 3:
            return 2;
        case 4:
            return 3;
        case 5:
            return 4;
        case 6:
            return 5;
        case 7:
            return 6;
    }
}
```

`Calendar.get(7)` = `DAY_OF_WEEK`（SUNDAY=1 … SATURDAY=7）；映射后周日=7、周一=1，与 `Course.dayOfWeek` 同域。

**iOS 对应**：`Calendar.current.component(.weekday,...)` 是 SUNDAY=1 … SATURDAY=7，语义**正好等于** `Calendar.DAY_OF_WEEK`；需做同样的 -1/+1 映射（`mondayBased = (weekday + 5) % 7 + 1`）。

### 1.6 教学周计算

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/CourseReminderScheduler.java:204-242`

```java
private final int calculateTeachingWeek(String firstWeekStartDate, Calendar target) {
    Integer intOrNull;
    String obj = firstWeekStartDate != null ? StringsKt.trim((CharSequence) firstWeekStartDate).toString() : null;
    if (obj == null) {
        obj = "";
    }
    String str = obj;
    if (StringsKt.isBlank(str)) {
        return 1;
    }
    List split$default = StringsKt.split$default((CharSequence) str, new String[]{"-"}, false, 0, 6, (Object) null);
    if (split$default.size() != 3 || (intOrNull = StringsKt.toIntOrNull((String) split$default.get(0))) == null) {
        return 1;
    }
    int intValue = intOrNull.intValue();
    Integer intOrNull2 = StringsKt.toIntOrNull((String) split$default.get(1));
    if (intOrNull2 == null) {
        return 1;
    }
    int intValue2 = intOrNull2.intValue();
    Integer intOrNull3 = StringsKt.toIntOrNull((String) split$default.get(2));
    if (intOrNull3 == null) {
        return 1;
    }
    int intValue3 = intOrNull3.intValue();
    Calendar calendar = Calendar.getInstance(Locale.getDefault());
    calendar.set(1, intValue);
    calendar.set(2, intValue2 - 1);
    calendar.set(5, intValue3);
    calendar.set(11, 0);
    calendar.set(12, 0);
    calendar.set(13, 0);
    calendar.set(14, 0);
    long timeInMillis = (target.getTimeInMillis() - calendar.getTimeInMillis()) / CalendarModelKt.MillisecondsIn24Hours;
    if (timeInMillis < 0) {
        return 1;
    }
    return 1 + ((int) (timeInMillis / 7));
}
```

- `firstWeekStartDate` 格式：`"yyyy-M-d"`，以 `-` 分割成 3 段整数（**注意不是 `yyyy-MM-dd` 也兼容**，因为用 `toIntOrNull`）；
- 非法/空/段数≠3 → 恒返回 **1**；
- 差值 < 0（第一周还没到）→ 返回 **1**；
- 公式：`week = 1 + floor(daysBetween / 7)`，除法是 **整除截断**（`long / long`），`MillisecondsIn24Hours` 来自 `androidx.compose.material3.CalendarModelKt`（= 86400000）。
- 关键副作用：**该公式按「绝对天数/7」而非「按自然周对齐」**，因此 `firstWeekStartDate` 若不是周一，周次边界会与直觉不同 —— 这是要逐字复刻的行为。

**iOS 对应**：`Int((target.timeIntervalSince(startOfFirstWeek)) / 86400) / 7 + 1`，同样用日期**时间戳差**（不是 `Calendar.dateComponents` 的自然日），否则行为会漂移。

### 1.7 周次/单双周过滤

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/CourseReminderScheduler.java:244-258`

```java
private final boolean occursInWeek(Course course, int week) {
    int startWeek = course.getStartWeek();
    if (week > course.getEndWeek() || startWeek > week) {
        return false;
    }
    int isOdd = course.isOdd();
    if (isOdd == 1) {
        if (week % 2 != 1) {
            return false;
        }
    } else if (isOdd == 2 && week % 2 != 0) {
        return false;
    }
    return true;
}
```

- `isOdd == 1` → **单周**（`week % 2 == 1`）；`isOdd == 2` → **双周**（`week % 2 == 0`）；`0` → 每周。
- 判定顺序：先 `startWeek <= week <= endWeek`，再单双周。
- 课程筛选条件（`:71-76`）：`course.dayOfWeek == mondayBasedDay && occursInWeek(course, teachingWeek)`。

**iOS 对应**：逐字照抄三分支；`week % 2` 在 Swift 中对正数行为一致。

---

## 2. 调度机制（AlarmManager 方法 / requestCode / 版本分支）

### 2.1 AlarmManager 的取用

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/CourseReminderScheduler.java:49-52`

```java
Object systemService = context.getSystemService(NotificationCompat.CATEGORY_ALARM);
Intrinsics.checkNotNull(systemService, "null cannot be cast to non-null type android.app.AlarmManager");
AlarmManager alarmManager = (AlarmManager) systemService;
cancelAll(context, alarmManager);
```

`NotificationCompat.CATEGORY_ALARM = "alarm"`。

### 2.2 实际调度调用：`setExactAndAllowWhileIdle` + `setAndAllowWhileIdle` 回退

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/CourseReminderScheduler.java:100-107`

```java
PendingIntent broadcast = PendingIntent.getBroadcast(context, abs, intent, 201326592);
long timeInMillis = calendar3.getTimeInMillis();
try {
    alarmManager.setExactAndAllowWhileIdle(0, timeInMillis, broadcast);
} catch (Throwable unused) {
    alarmManager.setAndAllowWhileIdle(0, timeInMillis, broadcast);
}
arrayList.add(str2);
```

- 类型参数 `0` = `AlarmManager.RTC_WAKEUP`；
- **`setRepeating` / `setInexactRepeating` / `setAlarmClock` 在提醒路径均未使用**（全仓搜索仅命中 §6 的自动刷新与 widget）；
- **没有 `if (SDK_INT >= 31 && !canScheduleExactAlarms())` 分支**：本路径用 **try/catch** 兼容，异常（如 `SecurityException` / `IllegalStateException`）时降级为非精确。
- `canScheduleExactAlarms()` 只在 `AppPermissionHelper`（权限引导，见 §8.4）与 widget（§11）里出现。

**iOS 不可用**：无精确闹钟、无 idle 豁免。替代：
- 普通提醒 → `UNCalendarNotificationTrigger(repeats:false)`（系统不保证秒级准点，但通常准）；
- 「强提醒/闹钟」语义 → `UNNotificationInterruptionLevel.critical`（需 Apple 批准 `com.apple.developer.usernotifications.critical-alerts` entitlement）或退一步 `.timeSensitive`；
- 后台补算/重排 → `BGAppRefreshTask`（不含准点保证）。

### 2.3 requestCode 生成（由 courseId + 触发毫秒派生）

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/CourseReminderScheduler.java:90-91`

```java
String str2 = course2.getId() + "_" + calendar3.getTimeInMillis();
int abs = Math.abs(str2.hashCode());
```

- **alarm id 字符串 = `"<courseId>_<triggerEpochMillis>"`**，同时被持久化（§3.2）；
- `requestCode = abs(Java String.hashCode(id字符串))` —— 注意 `Math.abs(Integer.MIN_VALUE)` 仍是负数（Java 已知陷阱），且存在哈希碰撞可能；
- **是否用 courseId 派生**：是，但**不是**单独的 courseId，而是 `courseId + "_" + 触发毫秒` 的组合串哈希 → **同一门课在不同日期/不同触发时刻会得到不同 requestCode**。

### 2.4 PendingIntent 构建与 flags

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/CourseReminderScheduler.java:92-100`

```java
Intent intent = new Intent(context, (Class<?>) CourseReminderReceiver.class);
it = it2;
intent.putExtra("courseName", course2.getName());
intent.putExtra("location", course2.getLocation());
intent.putExtra("teacher", course2.getTeacher());
intent.putExtra("startPeriod", course2.getStartPeriod());
intent.putExtra("endPeriod", course2.getEndPeriod());
intent.putExtra("mode", settings.getClassReminderMode());
PendingIntent broadcast = PendingIntent.getBroadcast(context, abs, intent, 201326592);
```

**flags `201326592` = `0x0C000000`** = `FLAG_CANCEL_CURRENT (0x08000000) | FLAG_IMMUTABLE (0x04000000)`
（校验：`"{0:X8}" -f 201326592` → `0C000000`）。

**System.currentTimeMillis 语义**：`timeInMillis = calendar3.getTimeInMillis()`，赋给 `setExactAndAllowWhileIdle(type=0 RTC_WAKEUP, ...)`，即**绝对 UTC 毫秒**。

**iOS 对应**：无 requestCode/flag 机制；用稳定 `identifier`。**重要**：Android 的 requestCode 依赖「触发毫秒」，若 iOS 也把 epoch 编进 identifier，重算后永远 dedupe 不上 → iOS 建议 `identifier = "rem_<courseId>_<yyyyMMddHHmm>"`（或只 `rem_<courseId>_<yyyyMMdd>`，同日单次）。

### 2.5 版本分支（SDK<31 / >=31）现状

**提醒路径：无 SDK 分支**，只有 try/catch（§2.2）。`canScheduleExactAlarms()` 出现在：

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/permission/AppPermissionHelper.java:34-44`

```java
public final boolean exactAlarmNeedsSettings(Context context) {
    boolean canScheduleExactAlarms;
    Intrinsics.checkNotNullParameter(context, "context");
    if (Build.VERSION.SDK_INT < 31) {
        return false;
    }
    Object systemService = context.getSystemService(NotificationCompat.CATEGORY_ALARM);
    Intrinsics.checkNotNull(systemService, "null cannot be cast to non-null type android.app.AlarmManager");
    canScheduleExactAlarms = ((AlarmManager) systemService).canScheduleExactAlarms();
    return !canScheduleExactAlarms;
}
```

→ 语义：`SDK < 31` 永不需要用户去设置页；`SDK >= 31` 且 `!canScheduleExactAlarms()` 时返回 `true`（需引导）。

**iOS 不可用**：无「精确闹钟权限」开关。等价引导项是「通知权限」+「后台 App 刷新」开关，以及（若申请到）专注模式/Critical Alerts。

---

## 3. 提醒去重与取消

### 3.1 每次全量重建（核心去重策略）

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/CourseReminderScheduler.java:41-57`

```java
public final void rescheduleAll(Context context, List<Course> courses, AppSettings settings, List<TimetableProfile> profiles) {
    ...
    AlarmManager alarmManager = (AlarmManager) systemService;
    cancelAll(context, alarmManager);
    if (settings.getClassReminderEnabled()) {
        List<String> effectiveTimeSlots = getEffectiveTimeSlots(settings, profiles);
        if (effectiveTimeSlots.isEmpty()) {
            return;
        }
```

顺序：**先无条件 `cancelAll`，再重建**。这保证了「课程被删/编辑/周次不匹配/设置改动」后的残留 alarm 全部清除。

触发 `rescheduleAll` 的全部调用点（grep 结果）：

| 调用点 | 文件:行 |
|---|---|
| 启动加载数据 | `上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/ui/TimetableViewModel$loadSavedData$1.java:84` |
| 新增课程 | `.../ui/TimetableViewModel$insertCourse$1.java:77` |
| 批量新增 | `.../ui/TimetableViewModel$insertCourses$1.java:69` |
| 更新课程 | `.../ui/TimetableViewModel$updateCourse$1.java:90` |
| 删除课程 | `.../ui/TimetableViewModel$deleteCourse$1.java:75` |
| 删除全部课程 | `.../ui/TimetableViewModel$deleteAllCourses$1.java:66` |
| 手动刷新课表 | `.../ui/TimetableViewModel$refreshTimetable$1.java:140` |
| 更新设置 | `.../ui/TimetableViewModel$updateSettings$1.java:67` |
| 新增作息方案 | `.../ui/TimetableViewModel$addTimetableProfile$1.java:111` |
| 保存作息方案 | `.../ui/TimetableViewModel$saveTimetableProfiles$1.java:65` |
| 修改节次时间 | `.../ui/TimetableViewModel$updatePeriodTime$1.java:118` |
| 自动同步成功后 | `.../sync/TimetableAutoRefreshWorker.java:151` |

### 3.2 cancelAll 的精确实现（按持久化 id 列表逐个 cancel）

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/CourseReminderScheduler.java:122-141`

```java
private final void cancelAll(Context context, AlarmManager alarmManager) {
    Iterator<T> it = loadAlarmIds(context).iterator();
    while (it.hasNext()) {
        PendingIntent broadcast = PendingIntent.getBroadcast(context, Math.abs(((String) it.next()).hashCode()), new Intent(context, (Class<?>) CourseReminderReceiver.class), 603979776);
        if (broadcast != null) {
            alarmManager.cancel(broadcast);
            broadcast.cancel();
        }
    }
    saveAlarmIds(context, CollectionsKt.emptyList());
}

private final void saveAlarmIds(Context context, List<String> ids) {
    JSONArray jSONArray = new JSONArray();
    Iterator<T> it = ids.iterator();
    while (it.hasNext()) {
        jSONArray.put((String) it.next());
    }
    context.getSharedPreferences(PREFS, 0).edit().putString(KEY_ALARM_IDS, jSONArray.toString()).apply();
}
```

- **cancel 用的 flags `603979776` = `0x24000000`** = `FLAG_NO_CREATE (0x20000000) | FLAG_IMMUTABLE (0x04000000)` → 不存在则返回 `null`，所以有 `if (broadcast != null)` 判断；
- **Intent 里不带任何 extra**（只比 `component` + `requestCode`），因此能和调度时的 PendingIntent 匹配上（`FLAG_CANCEL_CURRENT` 不参与匹配）；
- 持久化结构：`Prefs("timetable_prefs").getString("reminder_alarm_ids", "")` = **JSON 数组字符串**，元素形如 `"<courseId>_<triggerMillis>"`；
- 读取时的健壮性：空白 → `emptyList()`；`JSONArray` 解析异常 → `emptyList()`（`:143-169`）。

**iOS 对应**：`UNUserNotificationCenter.current().removeAllPendingNotificationRequests()` 后重建；或维护自己的 pending id 集合逐一 `removePendingNotificationRequests(withIdentifiers:)`。iOS 无「需要 NO_CREATE」概念。

### 3.3 重复调度处理

- 同一门课、同一触发毫秒 → 同一 `str2` → 同一 requestCode → `FLAG_CANCEL_CURRENT` 会替换旧 PendingIntent（幂等）；
- 同一门课、**不同**触发毫秒（例如提前量改了）→ 不同 requestCode → 生成**新** alarm；旧的那个在下一次 `cancelAll` 时被清掉；
- 15 天窗口内同一门课每周一次 → 每周一个独立 alarm（因为 `calendar3.getTimeInMillis()` 不同）。

### 3.4 「当天无课」/「周次不匹配」的处理

由 §1.7 + §1.3 第 6 步共同保证：周次不匹配 → 该课程不进候选集；`str == null` 或 `parseMinute == null` → 跳过；触发时刻已过去 → 跳过。**没有**「当天无课时取消已排提醒」的额外逻辑 —— 因为每次都是全量重建，天然一致。

---

## 4. 通知内容（标题/正文/渠道/点击目标/声音震动）

### 4.1 onReceive 分流：strong → Activity，weak → 通知

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/CourseReminderReceiver.java:37-83`

```java
@Override // android.content.BroadcastReceiver
public void onReceive(Context context, Intent intent) {
    Intrinsics.checkNotNullParameter(context, "context");
    Intrinsics.checkNotNullParameter(intent, "intent");
    String stringExtra = intent.getStringExtra("courseName");
    if (stringExtra == null) {
        stringExtra = "";
    }
    String stringExtra2 = intent.getStringExtra("location");
    if (stringExtra2 == null) {
        stringExtra2 = "";
    }
    String stringExtra3 = intent.getStringExtra("teacher");
    String str = stringExtra3 != null ? stringExtra3 : "";
    String stringExtra4 = intent.getStringExtra("mode");
    if (stringExtra4 == null) {
        stringExtra4 = "weak";
    }
    if (Intrinsics.areEqual(stringExtra4, "strong")) {
        Intent intent2 = new Intent(context, (Class<?>) CourseStrongAlarmActivity.class);
        intent2.addFlags(335544320);
        intent2.putExtra("courseName", stringExtra);
        intent2.putExtra("location", stringExtra2);
        intent2.putExtra("teacher", str);
        context.startActivity(intent2);
        return;
    }
    INSTANCE.ensureChannels(context);
    Object systemService = context.getSystemService("notification");
    Intrinsics.checkNotNull(systemService, "null cannot be cast to non-null type android.app.NotificationManager");
    NotificationManager notificationManager = (NotificationManager) systemService;
    PendingIntent activity = PendingIntent.getActivity(context, stringExtra.hashCode(), new Intent(context, (Class<?>) MainActivity.class), 201326592);
    List listOf = CollectionsKt.listOf((Object[]) new String[]{stringExtra2, str});
    ArrayList arrayList = new ArrayList();
    for (Object obj : listOf) {
        if (true ^ StringsKt.isBlank((String) obj)) {
            arrayList.add(obj);
        }
    }
    String joinToString$default = CollectionsKt.joinToString$default(arrayList, " · ", null, null, 0, null, null, 62, null);
    NotificationCompat.Builder contentTitle = new NotificationCompat.Builder(context, CHANNEL_WEAK).setSmallIcon(R.mipmap.ic_launcher).setContentTitle("课前提醒：" + stringExtra);
    if (StringsKt.isBlank(joinToString$default)) {
        joinToString$default = "马上上课啦";
    }
    Notification build = contentTitle.setContentText(joinToString$default).setPriority(1).setAutoCancel(true).setContentIntent(activity).build();
    Intrinsics.checkNotNullExpressionValue(build, "build(...)");
    notificationManager.notify(("weak_" + stringExtra).hashCode(), build);
}
```

逐字事实：

| 项 | 值 |
|---|---|
| 强提醒判定 | `mode == "strong"`（`Intent.getStringExtra("mode")`，`null` → `"weak"`） |
| 强提醒跳转 flags | `335544320` = `0x14000000` = `FLAG_ACTIVITY_NEW_TASK (0x10000000) | FLAG_ACTIVITY_CLEAR_TASK (0x04000000)` |
| 弱提醒 channel | `CHANNEL_WEAK` 常量（见 §4.2） |
| 小图标 | `R.mipmap.ic_launcher` |
| **标题** | `"课前提醒：" + courseName`（中文全角冒号 `：`） |
| **正文** | `location` 与 `teacher` 去空白后用 **`" · "`**（空格+U+00B7+空格）连接；两者都空 → 回退 `"马上上课啦"` |
| 优先级 | `setPriority(1)` = `NotificationCompat.PRIORITY_HIGH` |
| 自动消失 | `setAutoCancel(true)` |
| 点击目标 | `MainActivity`，`PendingIntent.getActivity(requestCode = courseName.hashCode(), flags = 201326592)` |
| **通知 id** | `("weak_" + courseName).hashCode()`（**按课程名，不是 courseId**） |

> 注意：弱提醒正文**只含地点与教师**，不含「第几节」「几点上课」「提前几分钟」。

**iOS 对应**：`UNMutableNotificationContent`：
- `title = "课前提醒：\(courseName)"`
- `body = [location, teacher].filter{ !$0.trimmed.isEmpty }.joined(separator: " · ")`，空则 `"马上上课啦"`
- `interruptionLevel = .timeSensitive`（对齐 PRIORITY_HIGH 的穿透语义）
- `userInfo` 携带 `courseId` 供点击后深链；Android 侧点击只打开 `MainActivity`（无深链参数）
- **identifier** 建议对齐 `"weak_\(courseName)"`（同 Android 的通知 id 语义）以避免同名课程重复堆叠

### 4.2 通知渠道（channel id / name / importance / 声音 / 震动）

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/CourseReminderReceiver.java:30-31` 与 `:95-114`

```java
public static final String CHANNEL_STRONG = "class_reminder_strong";
public static final String CHANNEL_WEAK = "class_reminder_weak";
...
public final void ensureChannels(Context context) {
    Intrinsics.checkNotNullParameter(context, "context");
    if (Build.VERSION.SDK_INT < 26) {
        return;
    }
    Object systemService = context.getSystemService("notification");
    Intrinsics.checkNotNull(systemService, "null cannot be cast to non-null type android.app.NotificationManager");
    NotificationManager notificationManager = (NotificationManager) systemService;
    AppPermissionHelper$$ExternalSyntheticApiModelOutline0.m6370m();
    NotificationChannel m = AppPermissionHelper$$ExternalSyntheticApiModelOutline0.m(CourseReminderReceiver.CHANNEL_WEAK, "弱提醒", 4);
    m.setDescription("课前普通通知提醒");
    AppPermissionHelper$$ExternalSyntheticApiModelOutline0.m6370m();
    NotificationChannel m2 = AppPermissionHelper$$ExternalSyntheticApiModelOutline0.m(CourseReminderReceiver.CHANNEL_STRONG, "强提醒", 4);
    m2.setDescription("课前强提醒（闹钟样式）");
    m2.enableVibration(true);
    m2.setVibrationPattern(new long[]{0, 1000, 800, 1000, 800});
    m2.setSound(RingtoneManager.getDefaultUri(4), new AudioAttributes.Builder().setUsage(4).build());
    notificationManager.createNotificationChannel(m);
    notificationManager.createNotificationChannel(m2);
}
```

（`AppPermissionHelper$$ExternalSyntheticApiModelOutline0.m(id, name, importance)` = `new NotificationChannel(id, name, importance)`；import 见 `CourseReminderReceiver.java:18`。）

| 渠道 | id | name | importance | 描述 | 声音 | 震动 |
|---|---|---|---|---|---|---|
| 弱提醒 | `class_reminder_weak` | `弱提醒` | `4` = `IMPORTANCE_HIGH` | `课前普通通知提醒` | 未设置（渠道默认） | 未设置 |
| 强提醒 | `class_reminder_strong` | `强提醒` | `4` = `IMPORTANCE_HIGH` | `课前强提醒（闹钟样式）` | `RingtoneManager.getDefaultUri(4)` = `TYPE_ALARM`，`AudioAttributes.USAGE_ALARM(4)` | `{0, 1000, 800, 1000, 800}` |

- 版本门槛：`Build.VERSION.SDK_INT < 26` 直接 return；
- **渠道创建时机**：`TimetableApplication.onCreate()`（`TimetableApplication.java:32`）+ 弱提醒每次 `onReceive`；
- ⚠️ **强提醒路径不创建渠道**：`mode == "strong"` 分支在 `ensureChannels` 之前 `return`（`:54-62`），所以强提醒渠道只在 App 启动时被创建。

**iOS 不可用/对应**：
- iOS 无 channel 概念 → 用**多个通知类别/不同 sound 文件**模拟：弱提醒 → 默认提示音；强提醒 → `UNNotificationSound.defaultCritical`（或自定义 30s 循环音频）+ `interruptionLevel = .critical`。
- **震动模式 `{0,1000,800,1000,800}` 不可自定义**：iOS 只能用 `.defaultCritical` 的系统震动，或 `AVAudioPlayer` + `AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)`（需在 App 前台/被 critical alert 唤醒时执行）。
- `IMPORTANCE_HIGH` ≈ iOS 的横幅 + 声音 + 锁屏展示；`.timeSensitive` 是可申请的最接近语义。

### 4.3 测试入口文案

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/ReminderTestHelper.java:24-42`

```java
public final void triggerTest(Context context, String mode) {
    Intrinsics.checkNotNullParameter(context, "context");
    Intrinsics.checkNotNullParameter(mode, "mode");
    if (Intrinsics.areEqual(mode, "strong")) {
        Intent intent = new Intent(context, (Class<?>) CourseStrongAlarmActivity.class);
        intent.addFlags(335544320);
        intent.putExtra("courseName", "提醒测试课程");
        intent.putExtra("location", "测试教室");
        intent.putExtra("teacher", "测试教师");
        context.startActivity(intent);
        return;
    }
    CourseReminderReceiver.INSTANCE.ensureChannels(context);
    Object systemService = context.getSystemService("notification");
    Intrinsics.checkNotNull(systemService, "null cannot be cast to non-null type android.app.NotificationManager");
    Notification build = new NotificationCompat.Builder(context, CourseReminderReceiver.CHANNEL_WEAK).setSmallIcon(R.mipmap.ic_launcher).setContentTitle("弱提醒测试").setContentText("这是一条弱提醒测试通知").setPriority(1).setAutoCancel(true).setContentIntent(PendingIntent.getActivity(context, 909090, new Intent(context, (Class<?>) MainActivity.class), 201326592)).build();
    Intrinsics.checkNotNullExpressionValue(build, "build(...)");
    ((NotificationManager) systemService).notify(909090, build);
}
```

- 强提醒测试：标题 `提醒测试课程` / 地点 `测试教室` / 教师 `测试教师`，flags `335544320`；
- 弱提醒测试：标题 `弱提醒测试`、正文 `这是一条弱提醒测试通知`、通知 id **`909090`**、PendingIntent requestCode **`909090`**；
- 调用点：`.../ui/SettingsScreenKt.java:3047` → `reminderTestHelper.triggerTest(context4, SettingsScreen$lambda$892)`（传当前选中的 mode）。

---

## 5. 强提醒（CourseStrongAlarmActivity）

### 5.1 启动条件

唯一条件：`CourseReminderReceiver.onReceive` 里 `mode == "strong"`（§4.1）。另外两条直接启动路径：
- App 内测试：`ReminderTestHelper.triggerTest(ctx, "strong")`（§4.3）；
- 无其他调用点。

**它不是通知，不经过 NotificationManager**；也不使用 `setFullScreenIntent`（全仓 grep `setFullScreenIntent` 只命中 AndroidX 库自身，未命中 app 代码）。

### 5.2 锁屏/亮屏行为：**只在清单里声明，Activity 代码里没有 setShowWhenLocked/setTurnScreenOn**

出处：`apk_work/proj_dec/AndroidManifest.xml:20`

```xml
<activity android:exported="false" android:name="kebiaocom.example.reminder.CourseStrongAlarmActivity" android:showOnLockScreen="true" android:turnScreenOn="true"/>
```

全局 grep（`setShowWhenLocked|setTurnScreenOn|showWhenLocked|turnScreenOn|setDismissKeyguard|FLAG_SHOW_WHEN_LOCKED|FLAG_TURN_SCREEN_ON|FLAG_KEEP_SCREEN_ON|requestDismissKeyguard`）在 `上课早枝道-源码-1.11.5` 下的**唯一命中**就是上面这行清单：

```
Found 1 match
上课早枝道-源码-1.11.5\app\src\main\AndroidManifest.xml
Line 20:        <activity android:exported="false" android:name="kebiaocom.example.reminder.CourseStrongAlarmActivity" android:showOnLockScreen="true" android:turnScreenOn="true"/>
```

- `android:turnScreenOn="true"` → 启动时点亮屏幕（该属性在 API 27+ 生效）；
- `android:showOnLockScreen="true"` → 锁屏上显示；
- **不申请 `USE_FULL_SCREEN_INTENT` 权限**（APK 清单 `uses-permission` 列表见 §10，无此项）。

`// 不确定：` Activity 内是否有 `onWindowFocusChanged`/主题侧的 keep-screen-on 逻辑；1.11.5 反编译 `CourseStrongAlarmActivity.java` 只有 `onCreate`/`startAlarm`/`stopAlarmAndFinish`/`onDestroy`，未出现任何 Window API。

### 5.3 界面内容（Compose）

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/CourseStrongAlarmActivity.java:150-161`

```java
TextKt.m2157Text4IGK_g("强提醒", ..., MaterialTheme.INSTANCE.getTypography(composer2, MaterialTheme.$stable).getHeadlineSmall(), composer2, 6, 0, 65534);
TextKt.m2157Text4IGK_g("课程：" + str5, ..., composer2, 48, 0, 131068);
...
if (!StringsKt.isBlank(str6)) {
    TextKt.m2157Text4IGK_g("地点：" + str6, ...);
}
...
if (!StringsKt.isBlank(str7)) {
    TextKt.m2157Text4IGK_g("教师：" + str7, ...);
}
```

- 固定标题 `强提醒`（`headlineSmall`）；
- `"课程：" + courseName`（必定显示）；
- `"地点：" + location`、`"教师：" + teacher` **仅当非空白时显示**；
- 一个全宽按钮，点击 → `stopAlarmAndFinish()`（`CourseStrongAlarmActivity.java:162-177`）。

**⚠️ 无自动关闭**：没有超时 `Handler.postDelayed`、没有 `onPause` 自动 finish。唯一退出路径是**按钮点击**（或系统杀进程）。`onDestroy` 只负责释放资源（`:255-266`）。

### 5.4 响铃 + 震动（循环）

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/CourseStrongAlarmActivity.java:203-253`

```java
private final void startAlarm() {
    VibrationEffect createWaveform;
    Ringtone ringtone = RingtoneManager.getRingtone(this, RingtoneManager.getDefaultUri(4));
    Vibrator vibrator = null;
    if (ringtone != null) {
        if (Build.VERSION.SDK_INT >= 28) {
            ringtone.setLooping(true);
        }
        ringtone.play();
    } else {
        ringtone = null;
    }
    this.ringtone = ringtone;
    if (Build.VERSION.SDK_INT >= 31) {
        VibratorManager m = AppPermissionHelper$$ExternalSyntheticApiModelOutline0.m(getSystemService(AppPermissionHelper$$ExternalSyntheticApiModelOutline0.m()));
        if (m != null) {
            vibrator = m.getDefaultVibrator();
        }
    } else {
        Object systemService = getSystemService("vibrator");
        Intrinsics.checkNotNull(systemService, "null cannot be cast to non-null type android.os.Vibrator");
        vibrator = (Vibrator) systemService;
    }
    this.vibrator = vibrator;
    if (Build.VERSION.SDK_INT >= 26) {
        Vibrator vibrator2 = this.vibrator;
        if (vibrator2 != null) {
            createWaveform = VibrationEffect.createWaveform(new long[]{0, 1000, 700}, 0);
            vibrator2.vibrate(createWaveform);
            return;
        }
        return;
    }
    Vibrator vibrator3 = this.vibrator;
    if (vibrator3 != null) {
        vibrator3.vibrate(new long[]{0, 1000, 700}, 0);
    }
}

/* JADX INFO: Access modifiers changed from: private */
public final void stopAlarmAndFinish() {
    Ringtone ringtone = this.ringtone;
    if (ringtone != null) {
        ringtone.stop();
    }
    Vibrator vibrator = this.vibrator;
    if (vibrator != null) {
        vibrator.cancel();
    }
    finish();
}

@Override // android.app.Activity
protected void onDestroy() {
    super.onDestroy();
    Ringtone ringtone = this.ringtone;
    if (ringtone != null) {
        ringtone.stop();
    }
    Vibrator vibrator = this.vibrator;
    if (vibrator != null) {
        vibrator.cancel();
    }
}
```

- 铃声：`RingtoneManager.getDefaultUri(4)` = `TYPE_ALARM`（**系统闹铃音**）；
- 循环：`SDK_INT >= 28` 时 `ringtone.setLooping(true)`（API 28 起才有 `setLooping`）；< 28 只播一次；
- 震动：API ≥ 26 用 `VibrationEffect.createWaveform(new long[]{0, 1000, 700}, 0)`（第 2 参 `0` = **重复从 index 0 开始，无限循环**）；< 26 用旧 `vibrate(long[], int)`，同样 `repeat=0`；
- 震动器获取：API ≥ 31 走 `VibratorManager.getDefaultVibrator()`；否则 `getSystemService("vibrator")`；
- 释放：按钮点击与 `onDestroy` 双保险。

**iOS 不可用/对应**：
- iOS **无法**从后台全屏接管锁屏、无法循环播放自定义铃声（`UNNotificationSound` 最长 30 秒，且 critical alert 才有绕过静音的强提醒）。
- 最接近的实现：`interruptionLevel = .critical` + `sound = .defaultCritical`；App 被用户点开后再用 `AVAudioPlayer` 循环播放 + `AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)` 轮询模拟闹钟，并且**必须提供明确的「停止」按钮**。
- `setShowWhenLocked`/`setTurnScreenOn` **无对应 API**。

---

## 6. 自动刷新（WorkManager + AlarmManager 兜底）

### 6.1 概览：**没有 PeriodicWorkRequest**

全仓 grep `PeriodicWorkRequest|PeriodicWorkRequestBuilder|setBackoffCriteria|BackoffPolicy|addTag|enqueueUniqueWork|ExistingWorkPolicy` → **No matches found**。

真实链路：

```
AlarmManager.setAlarmClock(01:00 / 13:00)
  → TimetableAutoRefreshAlarmReceiver.onReceive
    → WorkManager.enqueue(OneTimeWorkRequest(TimetableAutoRefreshWorker, input trigger_hour))
      → doWork(): 校验开关/凭据 → JwxtTimetableSync.fetchFromJwxt → 保存 → 重排提醒 → 通知 → 日志
    → TimetableAutoRefreshAlarms.rescheduleOne(hour)   // 排下一天同一时刻
```

### 6.2 AlarmManager 兜底：精确 01:00 / 13:00，`setAlarmClock`

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/sync/TimetableAutoRefreshAlarms.java:21-38` 与 `:54-80`

```java
public static final String ACTION = "kebiaocom.example.action.AUTO_REFRESH_TIMETABLE";
public static final String EXTRA_HOUR = "trigger_hour";
public static final TimetableAutoRefreshAlarms INSTANCE = new TimetableAutoRefreshAlarms();
private static final int REQ_01 = 774401;
private static final int REQ_13 = 774413;

private TimetableAutoRefreshAlarms() {
}

public final void rescheduleFromStorage(Context context) {
    Intrinsics.checkNotNullParameter(context, "context");
    if (new LocalStorage(context).getSettings().getAutoSyncTimetableFromJwxt()) {
        scheduleSlot(context, 13, REQ_13);
        scheduleSlot(context, 1, REQ_01);
    } else {
        cancelAll(context);
    }
}
...
private final void scheduleSlot(Context context, int hour, int requestCode) {
    Object systemService = context.getSystemService(NotificationCompat.CATEGORY_ALARM);
    Intrinsics.checkNotNull(systemService, "null cannot be cast to non-null type android.app.AlarmManager");
    AlarmManager alarmManager = (AlarmManager) systemService;
    Intent intent = new Intent(context, (Class<?>) TimetableAutoRefreshAlarmReceiver.class);
    intent.setAction(ACTION);
    intent.putExtra("trigger_hour", hour);
    PendingIntent broadcast = PendingIntent.getBroadcast(context, requestCode, intent, 201326592);
    long nextMillisLocal = nextMillisLocal(hour, 0);
    try {
        alarmManager.setAlarmClock(new AlarmManager.AlarmClockInfo(nextMillisLocal, broadcast), broadcast);
    } catch (Throwable unused) {
        alarmManager.setAndAllowWhileIdle(0, nextMillisLocal, broadcast);
    }
}

private final long nextMillisLocal(int hour, int minute) {
    Calendar calendar = Calendar.getInstance();
    calendar.set(13, 0);
    calendar.set(14, 0);
    calendar.set(11, hour);
    calendar.set(12, minute);
    if (calendar.getTimeInMillis() <= System.currentTimeMillis()) {
        calendar.add(6, 1);
    }
    return calendar.getTimeInMillis();
}
```

逐字事实：

| 项 | 值 |
|---|---|
| action 字符串 | `"kebiaocom.example.action.AUTO_REFRESH_TIMETABLE"` |
| extra key | `"trigger_hour"` |
| 触发小时 | **13**（`REQ_13 = 774413`）与 **1**（`REQ_01 = 774401`），分钟固定 **0**，秒/毫秒清零 |
| 排程顺序 | 先 13 点，后 1 点（顺序无功能影响） |
| 调度 API | `setAlarmClock(new AlarmClockInfo(t, pi), pi)` → catch 回退 `setAndAllowWhileIdle(0, t, pi)` |
| 是否周期 | **非周期**：只排「下一个」该时刻；到点后由 receiver 再排下一次（§6.3） |
| PendingIntent flags | `201326592` = `0x0C000000` = `FLAG_CANCEL_CURRENT \| FLAG_IMMUTABLE` |
| 取消 flags | `603979776` = `0x24000000` = `FLAG_NO_CREATE \| FLAG_IMMUTABLE` |

出处：`TimetableAutoRefreshAlarms.java:82-98`

```java
private final void cancelAll(Context context) {
    Object systemService = context.getSystemService(NotificationCompat.CATEGORY_ALARM);
    Intrinsics.checkNotNull(systemService, "null cannot be cast to non-null type android.app.AlarmManager");
    AlarmManager alarmManager = (AlarmManager) systemService;
    for (Pair pair : CollectionsKt.listOf((Object[]) new Pair[]{TuplesKt.to(13, Integer.valueOf(REQ_13)), TuplesKt.to(1, Integer.valueOf(REQ_01))})) {
        int intValue = ((Number) pair.component1()).intValue();
        int intValue2 = ((Number) pair.component2()).intValue();
        Intent intent = new Intent(context, (Class<?>) TimetableAutoRefreshAlarmReceiver.class);
        intent.setAction(ACTION);
        intent.putExtra("trigger_hour", intValue);
        PendingIntent broadcast = PendingIntent.getBroadcast(context, intValue2, intent, 603979776);
        if (broadcast != null) {
            alarmManager.cancel(broadcast);
            broadcast.cancel();
        }
    }
}
```

> `setAlarmClock` 的特殊性：它会在系统 UI 上显示闹钟图标（Android 12+ 起可能需要 `SCHEDULE_EXACT_ALARM`）；APK 清单**只申请了 `SCHEDULE_EXACT_ALARM`**，未申请 `USE_EXACT_ALARM`（见 §10）。

### 6.3 到点后的行为与重排

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/sync/TimetableAutoRefreshAlarmReceiver.java:18-33`

```java
@Override // android.content.BroadcastReceiver
public void onReceive(Context context, Intent intent) {
    Intrinsics.checkNotNullParameter(context, "context");
    if (Intrinsics.areEqual(intent != null ? intent.getAction() : null, TimetableAutoRefreshAlarms.ACTION)) {
        int intExtra = intent.getIntExtra("trigger_hour", -1);
        if (intExtra == 13 || intExtra == 1) {
            Data build = new Data.Builder().putInt("trigger_hour", intExtra).build();
            Intrinsics.checkNotNullExpressionValue(build, "build(...)");
            WorkManager.getInstance(context.getApplicationContext()).enqueue(new OneTimeWorkRequest.Builder(TimetableAutoRefreshWorker.class).setInputData(build).build());
            TimetableAutoRefreshAlarms timetableAutoRefreshAlarms = TimetableAutoRefreshAlarms.INSTANCE;
            Context applicationContext = context.getApplicationContext();
            Intrinsics.checkNotNullExpressionValue(applicationContext, "getApplicationContext(...)");
            timetableAutoRefreshAlarms.rescheduleOne(applicationContext, intExtra);
        }
    }
}
```

- **只接受 `trigger_hour ∈ {1, 13}`**；
- WorkManager 用 **一次性** `OneTimeWorkRequest`，**无约束（无网络/电量条件）、无唯一名、无 tag、无 backoff**：
  - 无 `setConstraints(Constraints)` → 不做网络/充电检查；
  - 无 `enqueueUniqueWork` → 直接 `enqueue`（若同刻重复触发可入队两条）；
  - 无 `setBackoffCriteria` → 用 WorkManager 默认 `EXPONENTIAL` backoff，但**代码从不返回 `Result.retry()`**（见 §6.5）→ backoff 实际永不生效。
- `rescheduleOne` 在**同一次 onReceive 内**立刻排下一天（等价于每日重复）：

出处：`TimetableAutoRefreshAlarms.java:40-52`

```java
public final void rescheduleOne(Context context, int hour) {
    Intrinsics.checkNotNullParameter(context, "context");
    if (new LocalStorage(context).getSettings().getAutoSyncTimetableFromJwxt()) {
        if (hour == 1) {
            scheduleSlot(context, 1, REQ_01);
        } else {
            if (hour != 13) {
                return;
            }
            scheduleSlot(context, 13, REQ_13);
        }
    }
}
```

> 注意 `rescheduleOne` 的 `else` 分支依赖外层已保证 `hour ∈ {1,13}`；若开关被关掉，本方法**静默不重排**（但也不取消已有 alarm —— 取消只在 `rescheduleFromStorage` 里做）。

### 6.4 Worker：开关/凭据校验 + 输入

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/sync/TimetableAutoRefreshWorker.java:27` 与 `:70-85`

```java
public static final String KEY_TRIGGER_HOUR = "trigger_hour";
...
companion = LogManager.INSTANCE.getInstance(applicationContext);
LocalStorage localStorage2 = new LocalStorage(applicationContext);
AppSettings settings = localStorage2.getSettings();
if (!settings.getAutoSyncTimetableFromJwxt()) {
    ListenableWorker.Result success = ListenableWorker.Result.success();
    Intrinsics.checkNotNullExpressionValue(success, "success(...)");
    return success;
}
int i4 = getInputData().getInt("trigger_hour", -1);
UserCredentials credentials = localStorage2.getCredentials();
if (StringsKt.isBlank(credentials.getUsername()) || StringsKt.isBlank(credentials.getPassword())) {
    TimetableAutoRefreshNotifier.INSTANCE.show(applicationContext, false, 0, "未配置教务账号，无法自动同步。", i4);
    ListenableWorker.Result success2 = ListenableWorker.Result.success();
    Intrinsics.checkNotNullExpressionValue(success2, "success(...)");
    return success2;
}
```

- 输入 key 字面量：`"trigger_hour"`（常量 `KEY_TRIGGER_HOUR`），默认 `-1`；
- 开关关闭 → 直接 `Result.success()`，**不发通知、不写日志**；
- 凭据缺失（`username` 或 `password` 为空白）→ 发通知 `未配置教务账号，无法自动同步。` 并返回 `success`。

### 6.5 执行结果分支（成功/失败/空结果）

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/sync/TimetableAutoRefreshWorker.java:86-158`

```java
try {
    LogManager.i$default(companion, "TimetableAutoRefresh", "开始自动同步课表 triggerHour=" + i4, null, 4, null);
    JwxtTimetableSync jwxtTimetableSync = JwxtTimetableSync.INSTANCE;
    ...
    Object fetchFromJwxt = jwxtTimetableSync.fetchFromJwxt(credentials, companion, timetableAutoRefreshWorker$doWork$1);
    ...
} catch (Exception e) {
    e = e;
    logManager = companion;
    i2 = i4;
    logManager.e("TimetableAutoRefresh", "自动同步失败", e);
    TimetableAutoRefreshNotifier timetableAutoRefreshNotifier = TimetableAutoRefreshNotifier.INSTANCE;
    message = e.getMessage();
    if (message == null) {
        message = "未知错误";
    }
    timetableAutoRefreshNotifier.show(applicationContext, false, 0, message, i2);
    ListenableWorker.Result success3 = ListenableWorker.Result.success();
    Intrinsics.checkNotNull(success3);
    return success3;
}
...
list = (List) obj;
if (!list.isEmpty()) {
    TimetableAutoRefreshNotifier.INSTANCE.show(context, false, 0, "教务返回课表为空，本地未修改。", i3);
} else {
    localStorage.saveCourses(list);
    CourseReminderScheduler.INSTANCE.rescheduleAll(context, list, appSettings, localStorage.getTimetableProfiles());
    TimetableWidgetRefresh.INSTANCE.sendBroadcast(context);
    TimetableAutoRefreshNotifier.INSTANCE.show(context, true, list.size(), "", i3);
}
LogManager.i$default(companion, "TimetableAutoRefresh", "自动同步结束", null, 4, null);
ListenableWorker.Result success4 = ListenableWorker.Result.success();
Intrinsics.checkNotNull(success4);
return success4;
```

⚠️ **jadx 的反编译在这里把 `if (!list.isEmpty())` 的两个分支对调了**（成功分支里访问 `list.size()` 却位于 `isEmpty()` 为真的一侧）。逐字恢复后的真实语义（依据：`saveCourses(list)` + `timetableAutoRefreshNotifier.show(context, true, list.size(), "", i3)` + `NotificationCompat` 的成功文案）：

- **列表非空** → `saveCourses(list)` → `rescheduleAll(...)`（**自动同步成功后立刻重排全部上课提醒**）→ `TimetableWidgetRefresh.sendBroadcast(context)` → `show(success = true, courseCount = list.size(), detail = "")`；
- **列表为空** → `show(success = false, courseCount = 0, detail = "教务返回课表为空，本地未修改。")`，**本地数据不变、提醒不重排**；
- 异常 → `e("TimetableAutoRefresh", "自动同步失败", e)` + `show(false, 0, e.message ?: "未知错误")`。

**所有路径都返回 `ListenableWorker.Result.success()`；代码里从不出现 `Result.retry()` 或 `Result.failure()`** → 无重试策略。

**iOS 对应**：
- `BGAppRefreshTask` 回调里：读开关 → 读凭据 → `await sync` → 成功则落库 + 重排通知（`removeAllPendingNotificationRequests()` + 重建）→ 发一条本地通知；失败发 `detail`；
- 必须调用 `task.setTaskCompleted(success: true)`（对应 Android 恒 `success`）；
- iOS 的「重试」由系统调度，无 backoff 参数（`earliestBeginDate` 才是你的控制点）。

### 6.6 触发时刻的兜底 & 其它 AlarmManager 使用

- `nextMillisLocal(hour, 0)`：秒、毫秒清零后设为 `hour:00`；若 `<= now` 则 `add(DAY_OF_MONTH, 1)` —— **严格按本地时区**（`Calendar.getInstance()` 无 TimeZone 参数）；
- `// 不确定：` 「额外兜底的时间间隔」在自动刷新路径**不存在**固定间隔兜底；唯一兜底是 `setAlarmClock` 失败时退化为 `setAndAllowWhileIdle`（非精确）。若任务书中所指是 widget 的边界刷新，则见 §11。

---

## 7. 开机与时间变化（BOOT_COMPLETED / TIME_SET / DATE_CHANGED / MY_PACKAGE_REPLACED）

### 7.1 BootReceiver 只处理 BOOT_COMPLETED

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/sync/TimetableAutoRefreshBootReceiver.java:15-24`

```java
@Override // android.content.BroadcastReceiver
public void onReceive(Context context, Intent intent) {
    Intrinsics.checkNotNullParameter(context, "context");
    if (Intrinsics.areEqual(intent != null ? intent.getAction() : null, "android.intent.action.BOOT_COMPLETED")) {
        TimetableAutoRefreshAlarms timetableAutoRefreshAlarms = TimetableAutoRefreshAlarms.INSTANCE;
        Context applicationContext = context.getApplicationContext();
        Intrinsics.checkNotNullExpressionValue(applicationContext, "getApplicationContext(...)");
        timetableAutoRefreshAlarms.rescheduleFromStorage(applicationContext);
    }
}
```

清单注册（`apk_work/proj_dec/AndroidManifest.xml:23-27`）：

```xml
<receiver android:exported="true" android:name="kebiaocom.example.sync.TimetableAutoRefreshBootReceiver">
    <intent-filter>
        <action android:name="android.intent.action.BOOT_COMPLETED"/>
    </intent-filter>
</receiver>
```

### 7.2 应用启动也重建一次（比 BOOT 更重要的兜底）

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/TimetableApplication.java:31-39`

```java
try {
    CourseReminderReceiver.INSTANCE.ensureChannels(this);
    TimetableAutoRefreshAlarms timetableAutoRefreshAlarms = TimetableAutoRefreshAlarms.INSTANCE;
    Context applicationContext = getApplicationContext();
    Intrinsics.checkNotNullExpressionValue(applicationContext, "getApplicationContext(...)");
    timetableAutoRefreshAlarms.rescheduleFromStorage(applicationContext);
} catch (Throwable unused) {
    Log.w("TimetableApplication", "post-start alarm scheduling failed");
}
```

→ **每次 App 进程启动**都会 `ensureChannels` + `rescheduleFromStorage`（内部按开关排 13:00/1:00 或取消）。这是「开机自启/时间变化」在 Android 上的实际兜底。

`TimetableViewModel$loadSavedData$1.java:84,89` 也在加载数据时同步做：

```java
CourseReminderScheduler.INSTANCE.rescheduleAll(this.this$0.getApplication(), courses, settings, timetableProfiles);
...
TimetableAutoRefreshAlarms.INSTANCE.rescheduleFromStorage(this.this$0.getApplication());
```

`TimetableViewModel$updateSettings$1.java:60-67` 在设置变更时同步做：

```java
TimetableAutoRefreshAlarms.INSTANCE.rescheduleFromStorage(this.this$0.getApplication());
CourseReminderScheduler courseReminderScheduler = CourseReminderScheduler.INSTANCE;
...
courseReminderScheduler.rescheduleAll(application, list, appSettings, (List) mutableStateFlow3.getValue());
```

### 7.3 `TIME_SET` / `DATE_CHANGED` / `MY_PACKAGE_REPLACED`：**自动刷新不使用它们**

清单里唯一声明这三个 action 的接收器是 **widget** 的 `DshWidgetRefreshReceiver`，且它只刷 widget、**不重建课表同步闹钟、不重排上课提醒**：

出处：`apk_work/proj_dec/AndroidManifest.xml:69-78`

```xml
<receiver android:exported="true" android:name="kebiaocom.example.widget.DshWidgetRefreshReceiver">
    <intent-filter>
        <action android:name="kebiaocom.example.action.REFRESH_TIMETABLE_WIDGETS"/>
        <action android:name="android.intent.action.BOOT_COMPLETED"/>
        <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
        <action android:name="android.intent.action.TIME_SET"/>
        <action android:name="android.intent.action.DATE_CHANGED"/>
        <action android:name="kebiaocom.example.action.DSH_WIDGET_TICK"/>
    </intent-filter>
</receiver>
```

其 `onReceive` 无条件只做一件事：

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/widget/DshWidgetRefreshReceiver.java:13-20`

```java
@Override // android.content.BroadcastReceiver
public void onReceive(Context context, Intent intent) {
    Intrinsics.checkNotNullParameter(context, "context");
    try {
        DshWidgetRenderer.INSTANCE.refreshAll(context);
    } catch (Throwable th) {
    }
}
```

**结论（回答任务书第 7 条）**：

| action | 谁处理 | 做了什么 |
|---|---|---|
| `BOOT_COMPLETED` | `TimetableAutoRefreshBootReceiver` + `DshWidgetRefreshReceiver` + `WidgetBootReceiver` | 前者 `rescheduleFromStorage()`（重建 01:00/13:00 闹钟）；后两者刷 widget |
| `TIME_SET` | **仅** `DshWidgetRefreshReceiver` | 只刷 widget；**不**重排课表同步闹钟、**不**重排上课提醒 |
| `DATE_CHANGED` | **仅** `DshWidgetRefreshReceiver` | 同上 |
| `MY_PACKAGE_REPLACED` | **仅** `DshWidgetRefreshReceiver` | 同上 |

> 因此 Android 侧对「时区/时间被改」的容错**很弱**：上课提醒不会因 `TIME_SET` 重排，只能靠 App 下次启动或 15 天滚动窗口自然覆盖。改为 iOS 时应主动修复这一点：在 `NSSystemTimeZoneDidChange`、`UIApplication.significantTimeChangeNotification`、以及每次前后台切换时重排。

**iOS 不可用点**：无 `BOOT_COMPLETED`、无 `MY_PACKAGE_REPLACED`。替代：
- 注册 `BGTaskScheduler` 的 `BGAppRefreshTask`（需在 App 启动时注册）；
- `UIApplication.didBecomeActiveNotification` / `willEnterForeground` 时重算全部待发通知；
- `NSSystemTimeZoneDidChange` + `significantTimeChangeNotification` 时重算（补上 Android 的缺口）。

---

## 8. 设置开关与默认值

### 8.1 与提醒/刷新相关的 `AppSettings` 字段（共 4 个）

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/data/AppSettings.java:14,17,18,19`

```java
private final boolean autoSyncTimetableFromJwxt;
...
private final boolean classReminderEnabled;
private final int classReminderMinutes;
private final String classReminderMode;
```

| Kotlin 字段 | 类型 | 默认值 | 出处（默认参数位掩码） |
|---|---|---|---|
| `autoSyncTimetableFromJwxt` | `Boolean` | **`false`** | `AppSettings.java:264` `(i12 & 16384) != 0 ? false : z7` |
| `classReminderEnabled` | `Boolean` | **`false`** | `AppSettings.java:264` `(i12 & 65536) != 0 ? false : z8` |
| `classReminderMode` | `String` | **`"weak"`** | `AppSettings.java:264` `(i12 & 131072) != 0 ? "weak" : str5` |
| `classReminderMinutes` | `Int` | **`10`** | `AppSettings.java:264` `(i12 & 262144) != 0 ? 10 : i6` |

`classReminderMode` 取值域：**`"weak"` / `"strong"`**（切换逻辑见 `.../ui/SettingsScreenKt.java:2960`）：

```java
mutableState133.setValue(Intrinsics.areEqual(SettingsScreen$lambda$892, "strong") ? "weak" : "strong");
```

UI 展示（`.../ui/SettingsScreenKt.java:2938`）：

```java
String str = Intrinsics.areEqual(SettingsScreen$lambda$89, "strong") ? "强提醒（闹钟）" : "弱提醒（通知）";
```

相关但**不**直接属于提醒的上下文设置（被提醒逻辑读取）：
- `firstWeekStartDate`（默认 `null`，`AppSettings.java:264` `(i12 & 64) == 0 ? str3 : null`）→ §1.6；
- `selectedTimetableProfileId`（默认 `"default"`，`(i12 & 32768) != 0 ? "default" : str4`）→ §1.2；
- `periodsPerDay` = 12、`periodDurationMinutes` = 45、`breakDurationMinutes` = 10、`firstPeriodStartTime` = `"08:00"`、`semesterWeeks` = 20（同上，供 §1 之外的 UI 用）。

### 8.2 SharedPreferences key 字面量（`"timetable_prefs"`）

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/data/LocalStorage.java:31`

```java
SharedPreferences sharedPreferences = context.getSharedPreferences("timetable_prefs", 0);
```

写入（`LocalStorage.java:64`，节选相关键）：

```java
... .putBoolean("autoSyncTimetableFromJwxt", settings.getAutoSyncTimetableFromJwxt()).putString("selectedTimetableProfileId", settings.getSelectedTimetableProfileId()).putBoolean("classReminderEnabled", settings.getClassReminderEnabled()).putString("classReminderMode", settings.getClassReminderMode()).putInt("classReminderMinutes", settings.getClassReminderMinutes()) ...
```

读取（`LocalStorage.java:84-89`）：

```java
boolean z7 = this.prefs.getBoolean("autoSyncTimetableFromJwxt", false);
String string4 = this.prefs.getString("selectedTimetableProfileId", "default");
...
boolean z8 = this.prefs.getBoolean("classReminderEnabled", false);
String string5 = this.prefs.getString("classReminderMode", "weak");
return new AppSettings(0, string, i, i2, i3, str, string3, i4, z, z2, z3, z4, z5, z6, z7, str2, z8, string5 == null ? "weak" : string5, this.prefs.getInt("classReminderMinutes", 10), ...);
```

| Pref key | 类型 | 默认值（读取兜底） |
|---|---|---|
| `classReminderEnabled` | Boolean | `false` |
| `classReminderMode` | String | `"weak"`（且显式处理 `getString` 返回 `null` → `"weak"`） |
| `classReminderMinutes` | Int | `10` |
| `autoSyncTimetableFromJwxt` | Boolean | `false` |
| `selectedTimetableProfileId` | String | `"default"` |
| `firstWeekStartDate` | String | `null` |
| `courses_json` | String(JSON) | `""`（`LocalStorage.java:111,118`） |
| `timetable_profiles_json` | String(JSON) | `""`（`LocalStorage.java:187,193`） |
| `username` / `password` / `jwxtUrl` | String | `""`（`LocalStorage.java:41,46,50,52`） |

**提醒专用 prefs（另一组，同文件不同 key）**：

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/reminder/CourseReminderScheduler.java:35-36,140,145`

```java
private static final String KEY_ALARM_IDS = "reminder_alarm_ids";
private static final String PREFS = "timetable_prefs";
...
context.getSharedPreferences(PREFS, 0).edit().putString(KEY_ALARM_IDS, jSONArray.toString()).apply();
...
String string = context.getSharedPreferences(PREFS, 0).getString(KEY_ALARM_IDS, "");
```

| Pref key | 值 |
|---|---|
| `reminder_alarm_ids` | JSON 数组字符串，元素 `"<courseId>_<triggerEpochMillis>"`；默认 `""` |

**iOS 对应**：`UserDefaults` key 建议**沿用 Android 的字面量**（`classReminderEnabled` / `classReminderMode` / `classReminderMinutes` / `autoSyncTimetableFromJwxt`），便于将来跨平台迁移与调试对照；`reminder_alarm_ids` 无必要（iOS 用 `pendingNotificationRequests` 自省）。

### 8.3 UI 文案（与逻辑相关的确切字符串）

| 文案 | 出处 |
|---|---|
| `Section: 课前提醒` | `.../ui/SettingsScreenKt.java:2885` |
| `SwitchRow: 开启课前提醒` | `.../ui/SettingsScreenKt.java:2934` |
| `SettingValueRow: 提醒模式` / 值 `强提醒（闹钟）`/`弱提醒（通知）` | `.../ui/SettingsScreenKt.java:2966,2938` |
| `SettingValueRow: 课前提醒时间` / 值 `"<n> 分钟"`（空白回退 `"10"`） | `.../ui/SettingsScreenKt.java:3025,2970-2973` |
| `SwitchRow: 定时同步教务课表` | `.../ui/SettingsScreenKt.java:1455` |
| 自动同步说明：`开启后每天中午 1 点与凌晨 1 点自动从教务系统拉取课表并覆盖本地；完成后在通知栏显示一条常驻消息（需通知权限）。` | `.../ui/SettingsScreenKt.java:1456` |
| `课前提醒分钟数`（弹窗标题） | `.../ui/SettingsScreenKt.java:2996` |
| `已允许` / `需在系统中允许`（精确闹钟权限态） | `.../ui/SettingsScreenKt.java:2726` |
| `已忽略优化` / `未忽略（建议开启）`（电池优化态） | `.../ui/SettingsScreenKt.java:2728` |
| 权限向导完成 Toast：`权限引导已完成` + （若通知未开）`（通知未开时弱提醒可能无法显示）` + `。无自启选项的机型请在本机「应用信息」或厂商管家中允许后台与自启动。` | `.../ui/SettingsScreenKt.java:4334-4338` |

### 8.4 权限引导顺序（对 iOS 很有参考价值）

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/ui/SettingsScreenKt.java:4357-4368`

```java
public static final void SettingsScreen$advancePermissionWizard(Context context, ManagedActivityResultLauncher<String, Boolean> managedActivityResultLauncher, ComponentActivity componentActivity, MutableState<Boolean> mutableState, MutableState<Boolean> mutableState2, MutableState<Boolean> mutableState3) {
    if (SettingsScreen$lambda$4(mutableState)) {
        if (AppPermissionHelper.INSTANCE.postNotificationsRuntimeNeeded() && !AppPermissionHelper.INSTANCE.postNotificationsGranted(context)) {
            managedActivityResultLauncher.launch("android.permission.POST_NOTIFICATIONS");
        } else if (AppPermissionHelper.INSTANCE.exactAlarmNeedsSettings(context)) {
            SettingsScreen$lambda$8(mutableState2, true);
            AppPermissionHelper.INSTANCE.openExactAlarmSettings(componentActivity);
        } else {
            SettingsScreen$startBatteryOrFinishWizard(context, componentActivity, mutableState, mutableState3);
        }
    }
}
```

顺序：**通知权限（SDK≥33）→ 精确闹钟设置页（SDK≥31 且未授权）→ 电池优化白名单**。

`AppPermissionHelper` 全文相关方法（`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/permission/AppPermissionHelper.java`）：

| 方法 | 行 | 行为 |
|---|---|---|
| `postNotificationsRuntimeNeeded()` | `:25-27` | `Build.VERSION.SDK_INT >= 33` |
| `postNotificationsGranted(ctx)` | `:29-32` | `!needed \|\| checkSelfPermission("android.permission.POST_NOTIFICATIONS") == 0` |
| `exactAlarmNeedsSettings(ctx)` | `:34-44` | `< 31` → `false`；否则 `!canScheduleExactAlarms()` |
| `openExactAlarmSettings(act)` | `:46-54` | `< 31` 直接 return；否则 `Intent("android.settings.REQUEST_SCHEDULE_EXACT_ALARM")` + `Uri.parse("package:" + pkg)` |
| `batteryOptimizationIgnored(ctx)` | `:56-61` | `PowerManager.isIgnoringBatteryOptimizations(pkg)` |
| `openRequestIgnoreBatteryOptimizations(act)` | `:63-72` | `Intent("android.settings.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS")`；异常回退 `"android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS"` |
| `openApplicationDetails(act)` | `:74-79` | `"android.settings.APPLICATION_DETAILS_SETTINGS"` |

**iOS 对应**：`UNUserNotificationCenter.requestAuthorization([.alert,.sound,.badge])`；无「精确闹钟」设置页 → 改为引导「设置 → 通用 → 后台 App 刷新」与「专注模式/时效性通知」；无电池优化白名单 → 改为说明低电量模式与后台刷新限制。

---

## 9. 刷新结果与日志

### 9.1 通知器（`TimetableAutoRefreshNotifier`）

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/sync/TimetableAutoRefreshNotifier.java:24-91`

```java
private static final String CHANNEL_ID = "timetable_auto_sync";
public static final TimetableAutoRefreshNotifier INSTANCE = new TimetableAutoRefreshNotifier();
public static final int NOTIFICATION_ID = 881001;

private TimetableAutoRefreshNotifier() {
}

private final void ensureChannel(Context context) {
    if (Build.VERSION.SDK_INT < 26) {
        return;
    }
    Object systemService = context.getSystemService("notification");
    Intrinsics.checkNotNull(systemService, "null cannot be cast to non-null type android.app.NotificationManager");
    AppPermissionHelper$$ExternalSyntheticApiModelOutline0.m6370m();
    NotificationChannel m = AppPermissionHelper$$ExternalSyntheticApiModelOutline0.m(CHANNEL_ID, "课表自动同步", 4);
    m.setDescription("定时从教务系统同步课表（系统通知栏常驻，需手动清除）");
    m.setShowBadge(true);
    ((NotificationManager) systemService).createNotificationChannel(m);
}

public final boolean canNotify(Context context) {
    Intrinsics.checkNotNullParameter(context, "context");
    return Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(context, "android.permission.POST_NOTIFICATIONS") == 0;
}

public final boolean showTestNotification(Context context) {
    Intrinsics.checkNotNullParameter(context, "context");
    if (!canNotify(context)) {
        return false;
    }
    show(context, true, 8, "", 13);
    return true;
}

public final void show(Context context, boolean success, int courseCount, String detail, int triggerHour) {
    String str;
    String str2;
    Intrinsics.checkNotNullParameter(context, "context");
    Intrinsics.checkNotNullParameter(detail, "detail");
    if (canNotify(context)) {
        ensureChannel(context);
        Object systemService = context.getSystemService("notification");
        Intrinsics.checkNotNull(systemService, "null cannot be cast to non-null type android.app.NotificationManager");
        NotificationManager notificationManager = (NotificationManager) systemService;
        Intent intent = new Intent(context, (Class<?>) MainActivity.class);
        intent.setFlags(335544320);
        Unit unit = Unit.INSTANCE;
        PendingIntent activity = PendingIntent.getActivity(context, 0, intent, 201326592);
        if (triggerHour == 1) {
            str = "凌晨 1 点";
        } else if (triggerHour == 13) {
            str = "中午 1 点";
        } else {
            str = "定时";
        }
        String str3 = success ? "课表已自动更新" : "课表自动同步未完成";
        if (success) {
            str2 = "[" + str + "] 已从教务系统覆盖本地课表，共 " + courseCount + " 门课程。";
        } else {
            str2 = "[" + str + "] " + detail;
        }
        String str4 = str2;
        Notification build = new NotificationCompat.Builder(context, CHANNEL_ID).setSmallIcon(R.mipmap.ic_launcher).setContentTitle(str3).setContentText(str4).setStyle(new NotificationCompat.BigTextStyle().bigText(str4)).setContentIntent(activity).setPriority(1).setCategory(NotificationCompat.CATEGORY_STATUS).setVisibility(1).setAutoCancel(false).setOngoing(false).setOnlyAlertOnce(true).build();
        Intrinsics.checkNotNullExpressionValue(build, "build(...)");
        notificationManager.notify(NOTIFICATION_ID, build);
    }
}
```

| 项 | 值 |
|---|---|
| channel id | `timetable_auto_sync` |
| channel name | `课表自动同步` |
| channel importance | `4` = `IMPORTANCE_HIGH` |
| channel description | `定时从教务系统同步课表（系统通知栏常驻，需手动清除）` |
| `setShowBadge` | `true` |
| 通知 id | **`881001`**（常量 `NOTIFICATION_ID`，固定不叠加） |
| 权限门 | `SDK < 33` 恒可；`>= 33` 需 `POST_NOTIFICATIONS` 已授权 |
| 点击目标 | `MainActivity`，`intent.setFlags(335544320)`（NEW_TASK\|CLEAR_TASK），`PendingIntent.getActivity(requestCode = 0, flags = 201326592)` |
| 时间前缀 | `triggerHour == 1` → `凌晨 1 点`；`== 13` → `中午 1 点`；其它 → `定时` |
| **标题（成功）** | `课表已自动更新` |
| **标题（失败/其它）** | `课表自动同步未完成` |
| **正文（成功）** | `"[" + 前缀 + "] 已从教务系统覆盖本地课表，共 " + courseCount + " 门课程。"` |
| **正文（失败）** | `"[" + 前缀 + "] " + detail` |
| 样式 | `BigTextStyle(bigText = 正文)` |
| priority / category / visibility | `1`（HIGH） / `CATEGORY_STATUS`（`"status"`） / `1`（`VISIBILITY_PUBLIC`） |
| autoCancel / ongoing / onlyAlertOnce | `false` / `false` / `true` |
| 测试通知 | `showTestNotification` → `show(ctx, true, 8, "", 13)`（即「8 门课程」） |

**iOS 对应**：`UNMutableNotificationContent`（`title` / `body` 逐字照抄），`identifier = "timetable_auto_sync"`（或 `"\(NOTIFICATION_ID)"` = `"881001"`）以保证「同一 id 覆盖」语义；`interruptionLevel = .active`；iOS 无「常驻不可清除」通知（`setAutoCancel(false)` + `setOngoing(false)` 在 Android 上其实仍可被用户划掉），若需常驻只能靠重新 `add`。

### 9.2 LogManager 调用点与日志文案

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/sync/TimetableAutoRefreshWorker.java`

| 行 | 级别 | tag | 文案 |
|---|---|---|---|
| `:87` | `i` | `TimetableAutoRefresh` | `"开始自动同步课表 triggerHour=" + i4` |
| `:108` | `e` | `TimetableAutoRefresh` | `"自动同步失败"` + throwable `e` |
| `:135` | `e` | `TimetableAutoRefresh` | `"自动同步失败"` + throwable `e`（协程恢复分支同一处理） |
| `:155` | `i` | `TimetableAutoRefresh` | `"自动同步结束"` |
| `:164` | `i` | `TimetableAutoRefresh` | `"自动同步结束"`（重复分支） |
| `:173` | `e` | `TimetableAutoRefresh` | `"自动同步失败"` + throwable `e`（外层 catch） |

原样片段（`TimetableAutoRefreshWorker.java:87`）：

```java
LogManager.i$default(companion, "TimetableAutoRefresh", "开始自动同步课表 triggerHour=" + i4, null, 4, null);
```

（`i$default` 的第 4 参 `null` = 无异常对象，第 5 参 `4` = 默认参数位掩码跳过 `throwable`；`LogManager.getInstance(appContext)` 在 `:70`。）

**提醒路径的日志**：`CourseReminderScheduler` / `CourseReminderReceiver` / `CourseStrongAlarmActivity` **完全没有 LogManager 调用**（grep 无命中）。唯一相关日志在应用启动失败兜底：

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/TimetableApplication.java:38`

```java
Log.w("TimetableApplication", "post-start alarm scheduling failed");
```

崩溃日志（`TimetableApplication.java:60`）：

```java
companion.getInstance(applicationContext).log(LogLevel.ERROR, "CRASH", "应用崩溃: " + thread.getName(), th);
```

**iOS 对应**：用 `os.Logger(subsystem: "kebiaocom.example", category: "TimetableAutoRefresh")` 复刻 tag；文案逐字保留（`开始自动同步课表 triggerHour=`、`自动同步结束`、`自动同步失败`）便于跨平台日志比对。

### 9.3 数据落库与副作用（成功分支）

同 §6.5：`localStorage.saveCourses(list)` → `CourseReminderScheduler.rescheduleAll(context, list, appSettings, localStorage.getTimetableProfiles())` → `TimetableWidgetRefresh.INSTANCE.sendBroadcast(context)`。

`TimetableWidgetRefresh.sendBroadcast` 的 action 常量（`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/widget/TimetableWidgetRefresh.java:15`）：

```java
public static final String ACTION_REFRESH = "kebiaocom.example.action.REFRESH_TIMETABLE_WIDGETS";
```

**iOS 对应**：`WidgetCenter.shared.reloadAllTimelines()`（替代 widget 广播）。

---

## 10. iOS 不可用点清单（逐条）

| # | Android 独有能力 | 出处 | iOS 替代 / 限制 |
|---|---|---|---|
| A1 | 精确闹钟 `setExactAndAllowWhileIdle` / `setAlarmClock` | `CourseReminderScheduler.java:103,105`；`TimetableAutoRefreshAlarms.java:64,66` | **无对应**。`UNCalendarNotificationTrigger` 由系统尽力送达；BGTask 完全不保证时刻。若需要「闹钟级」，只能申请 Critical Alerts entitlement。 |
| A2 | `AlarmManager.canScheduleExactAlarms()` 权限引导页 | `AppPermissionHelper.java:34-54` | **无对应**。改为引导「后台 App 刷新」+ 通知授权 + 专注模式。 |
| A3 | 电池优化白名单 `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | `AppPermissionHelper.java:56-72`；清单 `android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | **无对应**。iOS 无白名单申请 API；只能提示用户关闭低电量模式。 |
| A4 | `BOOT_COMPLETED` 开机重建调度 | `TimetableAutoRefreshBootReceiver.java:18-22`；清单 `RECEIVE_BOOT_COMPLETED` | **无对应**。iOS 用 `BGTaskScheduler.register` + 前后台切换重算。 |
| A5 | `TIME_SET` / `DATE_CHANGED` / `MY_PACKAGE_REPLACED` 广播 | 清单 `AndroidManifest.xml:69-78` | 近似：`NSSystemTimeZoneDidChange`、`UIApplication.significantTimeChangeNotification`、`didBecomeActive`。 |
| A6 | 全屏/锁屏 Activity（`showOnLockScreen` + `turnScreenOn`） | 清单 `AndroidManifest.xml:20` | **无对应**。iOS 无法从后台全屏接管锁屏；只能用 `.critical` / `.timeSensitive` 通知 + 用户点击进入 App。 |
| A7 | 声音与震动的循环自定义（`ringtone.setLooping(true)`；`VibrationEffect.createWaveform({0,1000,700}, 0)`） | `CourseStrongAlarmActivity.java:203-240` | **无对应**。`UNNotificationSound` 最长 30s；震动模式不可自定义；只能在 App 内用 `AVAudioPlayer` + `AudioServicesPlaySystemSound` 模拟。 |
| A8 | 通知渠道（channel id/name/importance） | `CourseReminderReceiver.java:95-114`；`TimetableAutoRefreshNotifier.java:31-42` | 近似：不同 `identifier` + 不同 sound + `interruptionLevel`。 |
| A9 | 通知「常驻不可清除」（`setAutoCancel(false)` / `setOngoing(false)`） | `TimetableAutoRefreshNotifier.java:86` | iOS 通知始终可被用户划掉；无 ongoing 概念（除 Live Activity）。 |
| A10 | `POST_NOTIFICATIONS` 运行时权限（SDK≥33） | `AppPermissionHelper.java:25-32`；清单 | `UNUserNotificationCenter.requestAuthorization`（语义等价）。 |
| A11 | 15 天 × 全部课程的全量 alarm 排布 | `CourseReminderScheduler.java:62` | iOS 待发本地通知上限 **64** 条 → 必须滚动窗口 + 重算。 |
| A12 | requestCode = `abs(id串.hashCode())` 的去重/替换语义 | `CourseReminderScheduler.java:90-100` | iOS 用 `identifier` 字符串；`add(request)` 对相同 identifier 自动替换（语义等价）。 |
| A13 | `PendingIntent.FLAG_CANCEL_CURRENT` 替换 + `FLAG_NO_CREATE` 探测 | `:100`（0x0C000000）、`:125`（0x24000000） | 无对应，用 `getPendingNotificationRequests` 自省。 |
| A14 | WorkManager 后台执行保证（`OneTimeWorkRequest`） | `TimetableAutoRefreshAlarmReceiver.java:24-26` | `BGAppRefreshTask`（执行时机不保证，App 被用户强杀后不再运行）。 |
| A15 | 后台直接 `startActivity`（从 Receiver 拉起强提醒页） | `CourseReminderReceiver.java:55-60`（flags `335544320`） | **无对应**。iOS 后台不能主动打开 App。 |
| A16 | `WAKE_LOCK` / `FOREGROUND_SERVICE` 权限 | 清单 `:9-10` | 无对应（iOS 无该权限模型）。 |

清单完整权限列表（`apk_work/proj_dec/AndroidManifest.xml:2-10`）：

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.VIBRATE"/>
<uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"/>
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
<uses-permission android:name="android.permission.WAKE_LOCK"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
```

> 注意：**没有** `USE_EXACT_ALARM`、**没有** `USE_FULL_SCREEN_INTENT`。`SCHEDULE_EXACT_ALARM` 是 Android 12/13 上可被用户撤销的权限，这正是 `exactAlarmNeedsSettings()` 引导的依据。

**清单版本差异（必须注意）**：`上课早枝道-源码-1.11.5/app/src/main/AndroidManifest.xml:20` 与 APK 内清单 `apk_work/proj_dec/AndroidManifest.xml:20` 文本一致：

```xml
<activity android:exported="false" android:name="kebiaocom.example.reminder.CourseStrongAlarmActivity" android:showOnLockScreen="true" android:turnScreenOn="true"/>
```

`// 不确定：` 该 grep 只回显了源码树那一行；两文件其余 `<activity>`/`<receiver>` 声明未逐行比对，若 iOS 侧要严格对齐，建议以 `apk_work/proj_dec/AndroidManifest.xml` 为唯一权威（任务书要求）。

---

## 11. 附：与 widget 的边界刷新（非本任务主线，但同用 AlarmManager，易被误认为「兜底间隔」）

出处：`上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/widget/DshWidgetRenderer.java:107-140`

```java
private final void scheduleNextBoundary(Context context) {
    Long nextBoundaryMillis;
    PendingIntent pending;
    boolean exact;
    try {
        if (!hasPlacedWidget(context) || (nextBoundaryMillis = nextBoundaryMillis(context)) == null) {
            return;
        }
        long trigger = nextBoundaryMillis.longValue();
        Object systemService = context.getSystemService(NotificationCompat.CATEGORY_ALARM);
        AlarmManager manager = systemService instanceof AlarmManager ? (AlarmManager) systemService : null;
        if (manager == null || (pending = tickPendingIntent(context)) == null) {
            return;
        }
        try {
            if (Build.VERSION.SDK_INT >= 31 && !manager.canScheduleExactAlarms()) {
                exact = false;
                if (!exact) {
                    manager.setExactAndAllowWhileIdle(0, trigger, pending);
                    return;
                } else {
                    manager.setAndAllowWhileIdle(0, trigger, pending);
                    return;
                }
            }
            exact = true;
            if (!exact) {
            }
        } catch (Throwable th) {
            manager.set(0, trigger, pending);
        }
    } catch (Throwable th2) {
    }
}
```

- 触发时刻由 `nextBoundaryMillis(context)` 计算（**具体算法未展开**，`// 不确定：nextBoundaryMillis 的边界定义（疑似下一节次/下一节课开始或午夜），未追进其实现`）；
- 失败兜底三层：`setExactAndAllowWhileIdle` → `setAndAllowWhileIdle` → `set(0, trigger, pending)`（最末层无精度保证）；
- `canScheduleExactAlarms()` 在这里**有**显式 SDK≥31 判断（与提醒路径的 try/catch 风格不同）；
- 取消：`manager.cancel(pending); pending.cancel();`（`:142-154`）；
- action 常量：`kebiaocom.example.action.DSH_WIDGET_TICK`（清单 `:76`）。

**iOS 对应**：`WidgetCenter.reloadTimelines` + `.atEnd` 策略；iOS widget 的刷新预算由系统控制，无法精确到「下一节课开始」。

---

## 12. 实现对照速查（iOS 落地清单）

1. **数据**：`Profile.periodTimes`（含 `index/start/end`）、`Course{id,name,teacher,location,dayOfWeek,startPeriod,endPeriod,startWeek,endWeek,isOdd}`、`Settings{classReminderEnabled,classReminderMode,classReminderMinutes,autoSyncTimetableFromJwxt,selectedTimetableProfileId,firstWeekStartDate}` —— 字面量沿用 Android。
2. **排程算法**：逐字移植 §1.4 → §1.3 → §1.6 → §1.7（顺序：15 天循环 → 星期映射 → 教学周 → 课程筛选 → 时刻计算 → 过去时间过滤）。
3. **通知内容**：
   - 弱提醒：`课前提醒：<courseName>` / `<location> · <teacher>`（空 → `马上上课啦`）/ identifier `weak_<courseName>` / `.timeSensitive`；
   - 强提醒：无全屏，退化为 `.critical`（或 `.timeSensitive`）通知；
   - 自动同步：`课表已自动更新` / `课表自动同步未完成` + `[凌晨 1 点|中午 1 点|定时] …` / identifier `timetable_auto_sync` 或 `881001` / `.active`。
4. **全量重排**：任何课程/作息/设置变更后 → `removeAllPendingNotificationRequests()` + 重建（对齐 §3.1 的 12 个调用点）。
5. **自动刷新**：`BGAppRefreshTask`（id 建议沿用 `timetable_auto_sync` / `trigger_hour` 语义）→ 校验开关+凭据 → 同步 → 落库 → 重排提醒 → `WidgetCenter.reloadAllTimelines()` → 发通知 → `setTaskCompleted(success: true)`（对齐「恒 success」）。
6. **时间变化**：`significantTimeChangeNotification` / `NSSystemTimeZoneDidChange` / `didBecomeActive` 全部重排（**补上 Android 在 §7.3 的缺口**）。
7. **日志**：`os.Logger(category: "TimetableAutoRefresh")`，逐字保留 `开始自动同步课表 triggerHour=`、`自动同步结束`、`自动同步失败`。

**不确定项汇总（3 条）**：
1. `// 不确定：` `CourseStrongAlarmActivity` 是否存在主题侧的 keep-screen-on / onWindowFocusChanged 逻辑（1.11.5 反编译类中仅见 `onCreate`/`startAlarm`/`stopAlarmAndFinish`/`onDestroy`，无任何 Window API）。
2. `// 不确定：` `TimetableAutoRefreshWorker.doWork` 中 `if (!list.isEmpty())` 两分支被 jadx 反编译对调；本文按「非空 = 保存+重排+成功通知 / 空 = 提示未修改」恢复（依据 `saveCourses` + `show(true, list.size(), ...)` 的语义），但未从 smali 逐指令验证。
3. `// 不确定：` widget 的 `nextBoundaryMillis(context)` 边界定义（疑似下一节次边界/午夜）；已确认它与课表自动刷新**无关**，仅用于 widget tick 的 `DSH_WIDGET_TICK` 闹钟。

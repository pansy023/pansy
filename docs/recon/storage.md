# 上课早枝道 1.11.5 — Android 本地持久化格式提取

> 逆向分析对象：`上课早枝道` Android 1.11.5（`apk_work\proj_dec`、`apk_work\src1115`）。
> 权威数据源优先级：jadx 反编译 Java > smali（`apk_work\proj_dec\smali_classes3\kebiaocom\example\data\LocalStorage.smali`）> 已重建 Kotlin。
> 本文所有字面量均逐字抄写（区分大小写与下划线）。凡反编译读不出的一律进「不确定项」，不做推测。

## 0. 结论速览

| 项 | 结论 |
| --- | --- |
| 持久化技术 | **只有 Android SharedPreferences（XML）+ org.json 手工序列化**；无 Room / SQLite / Gson / kotlinx.serialization / 文件 IO |
| SharedPreferences 文件数 | **2 个**：`timetable_prefs`（业务数据）、`log_prefs`（仅日志开关） |
| 业务 key 总数 | **40 个**（`timetable_prefs`） |
| 日志 key 总数 | **2 个**（`log_prefs`） |
| **key 总计** | **42 个** |
| 课程列表存储 | 单个 key `courses_json`，内为 **JSON 数组**（每个元素一个对象），用 `org.json.JSONObject` 逐字段写入 |
| 密码是否明文 | **是，完全明文**，无 Base64 / AES / Keystore / 任何编码（见 §4 证据） |
| 日志是否落盘 | **否**。`LogManager` 日志条目只存在内存 `MutableStateFlow`，进程退出即丢失；`log_prefs` 只存一个开关 |
| 无法确定的项 | **5 项**（见 §9） |

---

## 1. SharedPreferences 文件名与调用方

### 1.1 `timetable_prefs`

| 项 | 值 |
| --- | --- |
| 文件名 | `timetable_prefs`（逐字） |
| mode | `0`（Java 侧）/ `Context.MODE_PRIVATE`（Kotlin 侧，二者数值均为 0） |
| 用途 | 全部业务数据：设置、课程、课表档案、提醒 alarm id、凭据、UI 开关、弹窗「不再提示」 |
| 落盘路径 | `<dataDir>/shared_prefs/timetable_prefs.xml`（`dataDir` = `/data/data/kebiaocom.example/shared_prefs/`；包名见 §9 不确定项 U1） |

**直接调用方（全量，`getSharedPreferences(...)` 的 6 处）**

| 调用方 | 位置 | 访问的 key |
| --- | --- | --- |
| `LocalStorage` 构造函数 | `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\LocalStorage.java:31` | 除 `ui_dark_mode`/`ui_optimize_mode` 外全部 |
| `ThemeMode.init` | `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\theme\ThemeMode.java:35` | `ui_dark_mode` |
| `OptimizeMode.init` | `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\theme\OptimizeMode.java:35` | `ui_optimize_mode` |
| `CourseReminderScheduler`（常量 `PREFS`） | `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\reminder\CourseReminderScheduler.java:36`、使用点 `:140`、`:145` | `reminder_alarm_ids`（只读写这一个 key） |
| `DshWidgetRenderer.isDark` | `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\widget\DshWidgetRenderer.java:531` | `ui_dark_mode`（只读，缺失时回退系统深色） |
| `DshWidgetRenderer.isOptimized` | `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\widget\DshWidgetRenderer.java:540` | `ui_optimize_mode`（只读） |

Kotlin 侧同一份实现（重建稿，键名与 Java 一致）：`上课早枝道-源码-1.11.5\app\src\main\kotlin\kebiaocom\example\widget\DshWidget.kt:481`、`:489`。

`CourseReminderScheduler` 的常量定义（逐字）：

```java
// CourseReminderScheduler.java:35-36
private static final String KEY_ALARM_IDS = "reminder_alarm_ids";
private static final String PREFS = "timetable_prefs";
```

### 1.2 `log_prefs`

| 项 | 值 |
| --- | --- |
| 文件名 | `log_prefs`（逐字） |
| mode | `0` |
| 用途 | 只存日志子系统开关 `log_enabled`，**不存日志内容** |
| 落盘路径 | `<dataDir>/shared_prefs/log_prefs.xml` |

**直接调用方**

| 调用方 | 位置 |
| --- | --- |
| `LogManager.loadLogsFromPrefs` | `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\LogManager.java:277` |
| `LogManager.saveEnabledState` | `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\LogManager.java:282` |

Kotlin 同等实现：`上课早枝道-源码-1.11.5\app\src\main\kotlin\kebiaocom\example\data\LogManager.kt:131`、`:136`。

### 1.3 不存在的第三个文件

`AppSettings` 无独立文件；widget 无独立文件；无 `Room`/`SQLite`/`openFileOutput`/`FileOutputStream`/`writeText`/`Gson`/`kotlinx.serialization` 引用（全仓 grep 无命中）。`clearAll()` 会清空 **`timetable_prefs` 的全部 key**，但**不影响** `log_prefs`：

```java
// LocalStorage.java:164-166
public final void clearAll() {
    this.prefs.edit().clear().apply();
}
```

---

## 2. 全部 key 清单（key / 类型 / 默认值 / 用途 / 调用方）

### 2.1 `timetable_prefs` — 凭据（3 个）

| key（逐字） | 类型 | 默认值 | 用途 | 证据 |
| --- | --- | --- | --- | --- |
| `username` | String | `""` | 教务系统账号 | `LocalStorage.java:41`（写）、`:46`（读） |
| `password` | String | `""` | 教务系统密码（**明文**） | `LocalStorage.java:41`、`:50` |
| `jwxtUrl` | String | `https://jwgl.xihang.com.cn` | 教务系统根 URL | `LocalStorage.java:41`、`:54`、`UserCredentials.java:13` |

> 反编译里这三处显示为 `HintConstants.AUTOFILL_HINT_USERNAME` / `_PASSWORD`，jadx 把字符串常量还原成了 androidx 常量名。常量真值已核实为 `"username"` / `"password"`：`apk_work\jadx_out\sources\androidx\autofill\HintConstants.java:48`、`:24`。

### 2.2 `timetable_prefs` — AppSettings 的 26 个持久化字段（1 个字段不持久化）

`AppSettings` 共 **27 个主构造字段**（`上课早枝道-源码-1.11.5\app\src\main\kotlin\kebiaocom\example\data\AppSettings.kt:14-47`）。其中 `id` **不写入也不读取**（`saveSettings` 全链无 `id`），其余 26 个逐一对应：

| # | 字段名（AppSettings） | key 字面量 | 类型 | 默认值 | 证据（写 / 读） |
| --- | --- | --- | --- | --- | --- |
| 1 | `id` | —（不持久化） | — | Kotlin 默认 `1`；反序列化后实际恒为 `0`（见 §9 U2） | `LocalStorage.java:64` 无 id；`:89` 首参传 `0` |
| 2 | `backgroundImageUri` | `backgroundImageUri` | String? | `null` | `:64` / `:68` |
| 3 | `periodsPerDay` | `periodsPerDay` | Int | `12` | `:64` / `:69` |
| 4 | `periodDurationMinutes` | `periodDurationMinutes` | Int | `45` | `:64` / `:70` |
| 5 | `breakDurationMinutes` | `breakDurationMinutes` | Int | `10` | `:64` / `:71` |
| 6 | `firstPeriodStartTime` | `firstPeriodStartTime` | String（非空） | `"08:00"` | `:64` / `:72-73` |
| 7 | `firstWeekStartDate` | `firstWeekStartDate` | String? | `null` | `:64` / `:74` |
| 8 | `semesterWeeks` | `semesterWeeks` | Int | `20` | `:64` / `:75` |
| 9 | `showSaturday` | `showSaturday` | Boolean | `false`（回退读旧 key `showWeekend`） | `:64` / `:77` |
| 10 | `showSunday` | `showSunday` | Boolean | `false`（回退读旧 key `showWeekend`） | `:64` / `:79` |
| 11 | `showNonCurrentWeekCourses` | `showNonCurrentWeekCourses` | Boolean | `false` | `:64` / `:80` |
| 12 | `showWeekSlider` | `showWeekSlider` | Boolean | `false` | `:64` / `:81` |
| 13 | `reverseMainText` | `reverseMainText` | Boolean | `false`（1.11.5 功能已停用，恒 `false`） | `:64` / `:82` |
| 14 | `autoCheckUpdate` | `autoCheckUpdate` | Boolean | 读取默认 `false`；Kotlin data class 默认 `true`（冲突，见 §9 U3） | `:64` / `:83` |
| 15 | `autoSyncTimetableFromJwxt` | `autoSyncTimetableFromJwxt` | Boolean | `false` | `:64` / `:84` |
| 16 | `selectedTimetableProfileId` | `selectedTimetableProfileId` | String（非空） | `"default"` | `:64` / `:85-86` |
| 17 | `classReminderEnabled` | `classReminderEnabled` | Boolean | `false` | `:64` / `:87` |
| 18 | `classReminderMode` | `classReminderMode` | String（非空） | `"weak"` | `:64` / `:88-89` |
| 19 | `classReminderMinutes` | `classReminderMinutes` | Int | `10` | `:64` / `:89` |
| 20 | `nonCurrentWeekCourseAlphaPercent` | `nonCurrentWeekCourseAlphaPercent` | Int | `45` | `:64` / `:89` |
| 21 | `courseCardAlphaPercent` | `courseCardAlphaPercent` | Int | `100` | `:64` / `:89` |
| 22 | `courseFrostedIntensityPercent` | `courseFrostedIntensityPercent` | Int | `100` | `:64` / `:89` |
| 23 | `courseCellHeightDp` | `courseCellHeightDp` | Int | `69` | `:64` / `:89` |
| 24 | `courseTextSizeSp` | `courseTextSizeSp` | Int | `10` | `:64` / `:89` |
| 25 | `showCourseTime` | `showCourseTime` | Boolean | `true` | `:64` / `:89` |
| 26 | `showCourseLocation` | `showCourseLocation` | Boolean | `true` | `:64` / `:89` |
| 27 | `showCourseTeacher` | `showCourseTeacher` | Boolean | `true` | `:64` / `:89` |

行号均指 `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\LocalStorage.java`（`saveSettings` 为 `:62-65`，`getSettings` 为 `:67-90`）。

**旧版本遗留 key（1 个）**

| key | 类型 | 默认值 | 用途 | 证据 |
| --- | --- | --- | --- | --- |
| `showWeekend` | Boolean | `false` | **只读的兼容回退**：`showSaturday` / `showSunday` 不存在时用它的值。1.11.5 **不再写入**它 | `LocalStorage.java:77`、`:79` |

写法逐字：

```java
// LocalStorage.java:77 / :79
boolean z  = sharedPreferences.getBoolean("showSaturday", sharedPreferences.getBoolean("showWeekend", false));
boolean z2 = sharedPreferences2.getBoolean("showSunday",  sharedPreferences2.getBoolean("showWeekend", false));
```

### 2.3 `timetable_prefs` — 业务 JSON 容器（2 个）

| key | 类型 | 默认值 | 用途 | 证据 |
| --- | --- | --- | --- | --- |
| `courses_json` | String（内含 JSON 数组） | `""`（空串 → 视为空列表 `emptyList()`） | 全部课程 | 写 `LocalStorage.java:111`，读 `:118-124` |
| `timetable_profiles_json` | String（内含 JSON 数组） | `""`（空串 → 返回默认档案） | 全部课表档案（含每节次时间） | 写 `LocalStorage.java:187`，读 `:193-197` |

### 2.4 `timetable_prefs` — 提醒（1 个）

| key | 类型 | 默认值 | 用途 | 证据 |
| --- | --- | --- | --- | --- |
| `reminder_alarm_ids` | String（内含 JSON **字符串数组**） | `""`（空串 → `emptyList()`） | 已排程的提醒 alarm 标识集合，用于全量取消 | 写 `CourseReminderScheduler.java:140`，读 `:145-149` |

alarm id 的构造规则（逐字）：`先拼 courseId + "_" + 触发毫秒`，再取 `Math.abs(str.hashCode())` 作为 `PendingIntent` 的 requestCode：

```java
// CourseReminderScheduler.java:90-91
String str2 = course2.getId() + "_" + calendar3.getTimeInMillis();
int abs = Math.abs(str2.hashCode());
```

`loadAlarmIds` 用 `JSONArray` + `optString(i)` 解析，异常时回退 `emptyList()`（`:143-169`）。`cancelAll` 会先把该 key 覆写为空数组（`:131`）。

### 2.5 `timetable_prefs` — 弹窗「不再提示」与 UI 开关（4 个）

| key | 类型 | 默认值 | 用途 | 证据 |
| --- | --- | --- | --- | --- |
| `disclaimer_dont_show` | Boolean | `false` | 免责声明永久不再提示 | 读 `LocalStorage.java:282`，写 `:286` |
| `usage_guide_dont_show` | Boolean | `false` | 使用引导永久不再提示 | 读 `LocalStorage.java:290`，写 `:294` |
| `ui_dark_mode` | Boolean | `false`（widget 侧缺 key 时回退系统深色） | 深色模式 | 读 `ThemeMode.java:28`，写 `:51`；widget 只读 `DshWidgetRenderer.java:532-533` |
| `ui_optimize_mode` | Boolean | `false` | 优化模式（单色） | 读 `OptimizeMode.java:28`，写 `:62`；widget 只读 `DshWidgetRenderer.java:541` |

### 2.6 `log_prefs`（2 个）

| key | 类型 | 默认值 | 用途 | 证据 |
| --- | --- | --- | --- | --- |
| `log_enabled` | Boolean | `true` | 日志总开关 | 读 `LogManager.java:277`，写 `:282` |
| （文件名本身） | — | — | `log_prefs` | `LogManager.java:277`、`:282` |

### 2.7 每个 SharedPreferences 类型的使用汇总

| 值类型 | 使用到的 key |
| --- | --- |
| String | `username`、`password`、`jwxtUrl`、`backgroundImageUri`、`firstPeriodStartTime`、`firstWeekStartDate`、`selectedTimetableProfileId`、`classReminderMode`、`courses_json`、`timetable_profiles_json`、`reminder_alarm_ids` |
| Int | `periodsPerDay`、`periodDurationMinutes`、`breakDurationMinutes`、`semesterWeeks`、`classReminderMinutes`、`nonCurrentWeekCourseAlphaPercent`、`courseCardAlphaPercent`、`courseFrostedIntensityPercent`、`courseCellHeightDp`、`courseTextSizeSp` |
| Boolean | `showSaturday`、`showSunday`、`showWeekend`、`showNonCurrentWeekCourses`、`showWeekSlider`、`reverseMainText`、`autoCheckUpdate`、`autoSyncTimetableFromJwxt`、`classReminderEnabled`、`showCourseTime`、`showCourseLocation`、`showCourseTeacher`、`disclaimer_dont_show`、`usage_guide_dont_show`、`ui_dark_mode`、`ui_optimize_mode`、`log_enabled` |
| Long | **无**（全仓无 `putLong`/`getLong`） |
| StringSet | **无**（全仓无 `putStringSet`/`getStringSet`；集合一律走 JSON 字符串） |

### 2.8 提交方式差异（对一致性有影响）

| 方法 | 提交方式 | 证据 |
| --- | --- | --- |
| `saveCredentials` | **`commit()`（同步）** | `LocalStorage.java:41` |
| `saveSettings` | `apply()` | `LocalStorage.java:64` |
| `saveCourses` | `apply()` | `LocalStorage.java:111` |
| `saveTimetableProfiles` | `apply()` | `LocalStorage.java:187` |
| `setDisclaimerDismissedPermanently` / `setUsageGuideDismissedPermanently` | `apply()` | `LocalStorage.java:286`、`:294` |
| `clearAll` | `apply()` | `LocalStorage.java:165` |

---

## 3. 课程列表（`courses_json`）的存储格式

### 3.1 结论

- **不是逐字段存**，是**整表序列化为一条 JSON 字符串**存在单个 key `courses_json` 里。
- 顶层是 **JSON 数组**（不是对象包装），每个元素是一个课程对象。
- 序列化器：**`org.json`**（`android` 内置实现）。import 证据：`LocalStorage.java:17-18`（`import org.json.JSONArray; import org.json.JSONObject;`）。**没有** Gson / kotlinx.serialization 依赖。
- 写入用 `jSONObject.put(key, value)`（强类型），读取用 `optInt` / `optString`（带兜底默认值）。
- `Course` 共 **12 个字段**，**全部非空**（`name`/`teacher`/`location`/`weekRange` 由构造函数 `checkNotNullParameter` 保证，见 `Course.java:114-117`），JSON 里**没有 null，也没有可空字段处理分支**。
- 键名 = Kotlin 属性名，逐字一致，**写入顺序即上表顺序**（`id`→`isOdd`）。

### 3.2 JSON 结构

```json
[
  {
    "id": 0,
    "name": "",
    "teacher": "",
    "location": "",
    "dayOfWeek": 1,
    "startPeriod": 1,
    "endPeriod": 1,
    "color": -11751600,
    "weekRange": "1-20",
    "startWeek": 1,
    "endWeek": 20,
    "isOdd": 0
  }
]
```

上例中的数值是**读取时的兜底默认值**（`getCourses` 的 `opt*` 第二参），不是写入值的必然取值。

### 3.3 12 字段键名映射与类型

| # | `Course` 字段 | JSON 键名 | JSON 类型 | 读取兜底默认值 | 写入证据 | 读取证据 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `id` | `id` | number(int) | `0` | `LocalStorage.java:97` | `:137` |
| 2 | `name` | `name` | string | `""` | `:98` | `:138` |
| 3 | `teacher` | `teacher` | string | `""` | `:99` | `:140` |
| 4 | `location` | `location` | string | `""` | `:100` | `:142` |
| 5 | `dayOfWeek` | `dayOfWeek` | number(int) | `1` | `:101` | `:144` |
| 6 | `startPeriod` | `startPeriod` | number(int) | `1` | `:102` | `:145` |
| 7 | `endPeriod` | `endPeriod` | number(int) | `1` | `:103` | `:146` |
| 8 | `color` | `color` | number(int, 带符号 ARGB) | `-11751600`（= `0xFF4C8DF0`） | `:104` | `:147` |
| 9 | `weekRange` | `weekRange` | string | `"1-20"` | `:105` | `:148` |
| 10 | `startWeek` | `startWeek` | number(int) | `1` | `:106` | `:151` |
| 11 | `endWeek` | `endWeek` | number(int) | `20` | `:107` | `:151` |
| 12 | `isOdd` | `isOdd` | number(int) | `0` | `:108` | `:151` |

`Course` 的 Kotlin 声明（已确证模型，12 字段）：`上课早枝道-源码-1.11.5\app\src\main\kotlin\kebiaocom\example\data\Course.kt:3-16`。Java 侧字段与构造函数：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\Course.java:113-130`。注意 `isOdd` 是 **Int**（`0`=全周、`1`=单周、`2`=双周），`getIsOdd()` 返回 `int`（`Course.java:42-44`），**不是 Boolean**。

写循环逐字（`LocalStorage.java:94-111`）：

```java
JSONArray jSONArray = new JSONArray();
for (Course course : courses) {
    JSONObject jSONObject = new JSONObject();
    jSONObject.put("id", course.getId());
    jSONObject.put(HintConstants.AUTOFILL_HINT_NAME, course.getName());   // == "name"
    jSONObject.put("teacher", course.getTeacher());
    jSONObject.put("location", course.getLocation());
    jSONObject.put("dayOfWeek", course.getDayOfWeek());
    jSONObject.put("startPeriod", course.getStartPeriod());
    jSONObject.put("endPeriod", course.getEndPeriod());
    jSONObject.put("color", course.getColor());
    jSONObject.put("weekRange", course.getWeekRange());
    jSONObject.put("startWeek", course.getStartWeek());
    jSONObject.put("endWeek", course.getEndWeek());
    jSONObject.put("isOdd", course.isOdd());
    jSONArray.put(jSONObject);
}
this.prefs.edit().putString("courses_json", jSONArray.toString()).apply();
```

`:98` 处的 `HintConstants.AUTOFILL_HINT_NAME` 真值为 `"name"`：`apk_work\jadx_out\sources\androidx\autofill\HintConstants.java:21`。

### 3.4 解析容错

| 场景 | 行为 | 证据 |
| --- | --- | --- |
| key 不存在 | 取到 `""` | `LocalStorage.java:118-121` |
| 字符串 `isBlank()` | 直接返回 `CollectionsKt.emptyList()` | `:122-124` |
| 某元素不是 JSON 对象 | `optJSONObject` 返回 null → **跳过该元素** | `:132-135` |
| 字段缺失 | 用 `opt*` 的兜底默认值（见 §3.3） | `:137-151` |
| 整体 JSON 非法 | `catch (Exception)` → 记 `e(TAG, "getCourses parse error", e)` → 返回 `emptyList()` | `:158-161` |

`isOdd` 在 `optInt("isOdd", 0)` 中缺省为 `0`，即「全周」。

---

## 4. UserCredentials 的存储

### 4.1 字段 → key → 默认值

| `UserCredentials` 字段 | key 字面量 | 类型 | 读取默认值 | 写入证据 | 读取证据 |
| --- | --- | --- | --- | --- | --- |
| `id` | —（**不持久化**） | — | 硬编码 `1` | 无 | `LocalStorage.java:59`（`new UserCredentials(1, ...)`） |
| `username` | `username` | String | `""` | `:41` | `:46-49` |
| `password` | `password` | String | `""` | `:41` | `:50-51` |
| `jwxtUrl` | `jwxtUrl` | String | `"https://jwgl.xihang.com.cn"`（常量 `UserCredentials.DEFAULT_JWXT_URL`） | `:41` | `:53-57` |

模型定义：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\UserCredentials.java:13`（`public static final String DEFAULT_JWXT_URL = "https://jwgl.xihang.com.cn";`）、`:81-89`（构造函数，三个 String 参数均 `checkNotNullParameter`）。

### 4.2 密码是否明文 —— **是，明文**

证据链（全部逐字）：

1. **写入侧无任何变换**：`LocalStorage.java:41` 直接把 `credentials.getPassword()` 交给 `putString`。

```java
// LocalStorage.java:41
boolean commit = this.prefs.edit()
    .putString(HintConstants.AUTOFILL_HINT_USERNAME, credentials.getUsername())
    .putString(HintConstants.AUTOFILL_HINT_PASSWORD, credentials.getPassword())
    .putString("jwxtUrl", credentials.getJwxtUrl())
    .commit();
```

2. **读取侧无任何逆变换**：`LocalStorage.java:50-51` 是 `getString("password", "")`，赋值给局部变量后直接进 `UserCredentials`。

```java
// LocalStorage.java:50-51
String string2 = this.prefs.getString(HintConstants.AUTOFILL_HINT_PASSWORD, "");
String str = string2 != null ? string2 : "";
```

3. **无编码/加密/Keystore 的任何痕迹**：文件 import 仅 `android.content.Context`、`android.content.SharedPreferences`、`androidx.autofill.HintConstants`、`java.util.*`、`kotlin.*`、`org.json.*`（`LocalStorage.java:4-18`），**没有** `android.util.Base64`、`javax.crypto`、`android.security.keystore`、`MessageDigest`、`Cipher`。
4. **全仓 grep**：`Base64`、`Keystore`、`Cipher`、`MessageDigest`、`encrypt` 在持久化相关类中零命中；唯一名为 `encryptCode` 的方法在 `QiangzhiJwxtParser.java:127`，它是**教务系统登录表单的字符交织混淆算法**（把 `username + "%%%" + password` 按 `scode`/`sxh` 交织），只作用于 HTTP 请求体，**与本地存储无关**。
5. **smali 交叉验证**：`apk_work\proj_dec\smali_classes3\kebiaocom\example\data\LocalStorage.smali:1739`（`const-string v1, "username"`）、`:1750`（`const-string v1, "password"`）、`:1761`（`const-string v1, "jwxtUrl"`）——三个 key 后紧跟 `SharedPreferences$Editor;->putString`，无中间加密调用。
6. **间接泄漏点**：`saveCredentials` 会把用户名与 URL 写进日志（`:40`、`:42`）、`getCredentials` 也会（`:58`），但**日志本身不落盘**（§6），所以不构成额外持久化泄漏。注意 `saveCredentials` 的日志**不含密码**。

> 结论：`password` 以 UTF-8 明文存放在 `timetable_prefs.xml` 的 `<string name="password">…</string>` 中。任何能读到该 XML 或 root 的进程都能直接获取密码。

### 4.3 `saveCredentials` 的同步提交

`saveCredentials` 是唯一使用 `commit()` 的写路径（`:41`），返回值被记入日志（`:42`）。其余写路径用 `apply()`。

---

## 5. TimetableProfile 列表

### 5.1 存储 key 与顶层结构

| 项 | 值 |
| --- | --- |
| key | `timetable_profiles_json`（逐字） |
| 类型 | String（内含 JSON **数组**） |
| 默认值 / 空值行为 | `""`（空串或 `isBlank()`）→ 返回 `defaultTimetableProfiles()`；解析出空数组也返回默认档案 |
| 序列化器 | `org.json`（`LocalStorage.java:17-18`） |
| 写入证据 | `LocalStorage.java:187` |
| 读取证据 | `LocalStorage.java:193-197`（空串分支）、`:252-256`（空数组分支）、`:257-260`（异常分支） |

**JSON 结构**（档案对象 + 内嵌 `periodTimes` 数组 + 每项 `{index,start,end}`）：

```json
[
  {
    "id": "default",
    "name": "默认",
    "periodsPerDay": 10,
    "periodTimes": [
      { "index": 1, "start": "08:10", "end": "08:55" }
    ]
  }
]
```

### 5.2 字段 / 键名 / 默认值

| 层级 | 字段 | JSON 键名 | 类型 | 读取兜底默认值 | 证据 |
| --- | --- | --- | --- | --- | --- |
| 档案 | `TimetableProfile.id` | `id` | string | `"profile_" + i`（i 为数组下标，从 0 起） | 写 `:181` / 读 `:243` |
| 档案 | `TimetableProfile.name` | `name` | string | `"课表" + (i + 1)` | 写 `:182` / 读 `:245` |
| 档案 | `TimetableProfile.periodsPerDay` | `periodsPerDay` | number(int) | `coerceAtLeast(periodTimes.size, 1)` | 写 `:183` / 读 `:247` |
| 档案 | `TimetableProfile.periodTimes` | `periodTimes` | array | `new JSONArray()`（空数组） | 写 `:184` / 读 `:209-214` |
| 节次 | `PeriodTime.index` | `index` | number(int) | `j + 1`（j 为该数组下标） | 写 `:175` / 读 `:224` |
| 节次 | `PeriodTime.start` | `start` | string | `"08:00"` | 写 `:176` / 读 `:225` |
| 节次 | `PeriodTime.end` | `end` | string | `"08:45"` | 写 `:177` / 读 `:228` |

模型定义：`TimetableProfile.java:11-16`（`id`、`name`、`periodTimes`、`periodsPerDay`，均非空）、`PeriodTime.java:9-13`（`end`、`index`、`start`，均非空）。

写循环逐字（`LocalStorage.java:170-187`）：

```java
JSONArray jSONArray = new JSONArray();
for (TimetableProfile timetableProfile : profiles) {
    JSONArray jSONArray2 = new JSONArray();
    for (PeriodTime periodTime : timetableProfile.getPeriodTimes()) {
        JSONObject jSONObject = new JSONObject();
        jSONObject.put("index", periodTime.getIndex());
        jSONObject.put("start", periodTime.getStart());
        jSONObject.put("end", periodTime.getEnd());
        jSONArray2.put(jSONObject);
    }
    JSONObject jSONObject2 = new JSONObject();
    jSONObject2.put("id", timetableProfile.getId());
    jSONObject2.put(HintConstants.AUTOFILL_HINT_NAME, timetableProfile.getName());   // == "name"
    jSONObject2.put("periodsPerDay", timetableProfile.getPeriodsPerDay());
    jSONObject2.put("periodTimes", jSONArray2);
    jSONArray.put(jSONObject2);
}
this.prefs.edit().putString("timetable_profiles_json", jSONArray.toString()).apply();
```

读取时 `periodTimes` **会按 `index` 升序排序**（`:236-242`，比较器为 `ComparisonsKt.compareValues(index)`），因此 JSON 里的顺序不被信任。

### 5.3 默认档案 `id = "default"` 的产生

只在 `defaultTimetableProfiles()` 里产生，**从不写回 SharedPreferences**（即：默认档案是「每次读取时现算」，只有用户真正编辑并 `saveTimetableProfiles` 后才会落盘）：

```java
// LocalStorage.java:263-279
private final List<TimetableProfile> defaultTimetableProfiles() {
    int i = 0;
    List listOf = CollectionsKt.listOf((Object[]) new Pair[]{
        TuplesKt.to("08:10", "08:55"), TuplesKt.to("09:05", "09:50"),
        TuplesKt.to("10:20", "11:05"), TuplesKt.to("11:15", "12:00"),
        TuplesKt.to("14:10", "14:55"), TuplesKt.to("15:05", "15:50"),
        TuplesKt.to("16:20", "17:05"), TuplesKt.to("17:15", "18:00"),
        TuplesKt.to("19:30", "20:15"), TuplesKt.to("20:25", "21:10")});
    ...
    return CollectionsKt.listOf(new TimetableProfile("default", "默认", size, arrayList));
}
```

| 默认档案属性 | 值 |
| --- | --- |
| `id` | `"default"` |
| `name` | `"默认"` |
| `periodsPerDay` | `10`（= 时间对数量 `size`） |
| `periodTimes` | 10 条：`index` 从 `1` 递增；`(start, end)` = `("08:10","08:55")`、`("09:05","09:50")`、`("10:20","11:05")`、`("11:15","12:00")`、`("14:10","14:55")`、`("15:05","15:50")`、`("16:20","17:05")`、`("17:15","18:00")`、`("19:30","20:15")`、`("20:25","21:10")` |

smali 交叉验证（时间对逐字一致）：`apk_work\proj_dec\smali_classes3\kebiaocom\example\data\LocalStorage.smali:136-219`；`"default"` 在 `:350`，`"\u9ed8\u8ba4"`（= `默认`）在 `:352`。

### 5.4 `selectedTimetableProfileId` 与档案的对应关系

| 项 | 结论 | 证据 |
| --- | --- | --- |
| 存储位置 | 与档案列表**分开**：`selectedTimetableProfileId` 是 `timetable_prefs` 里的**独立 String key**，不属于 `AppSettings` 的 JSON 之外的任何结构 | `LocalStorage.java:64`（写）、`:85-86`（读） |
| 默认值 | `"default"` | `:85-86` |
| 语义 | 它是**弱引用/悬挂引用**——按 `TimetableProfile.id` 匹配当前生效档案 | 二者共用同一字符串域，`id` 生成见 §5.2（缺省 `"profile_" + i`） |
| 一致性保证 | **无任何校验**。读取处不检查该 id 是否存在于 `timetable_profiles_json` 里；如果用户删除了被选中的档案，`selectedTimetableProfileId` 仍保留旧 id，直到上层 UI 改写它 | `LocalStorage` 全文件无对 `selectedTimetableProfileId` 的存在性检查（`:67-90` 仅 `getString`） |

> iOS 移植注意：`selectedTimetableProfileId` 必须与档案 `id` 用同一命名空间；`defaultTimetableProfiles()` 的 `id` 恰好是 `"default"`，与 `selectedTimetableProfileId` 的默认值一致，这是二者默认能对上的唯一原因。

---

## 6. 日志（LogManager）

### 6.1 存储位置 —— 不落盘

| 问题 | 结论 | 证据 |
| --- | --- | --- |
| 用哪个 key/文件？ | **只用一个 key**：`log_prefs` 文件里的 `log_enabled`（Boolean，默认 `true`）。**没有任何 key 存日志条目** | `LogManager.java:277`、`:282` |
| 日志条目存哪？ | 内存 `MutableStateFlow<List<LogEntry>>`，构造函数里初始化为 `emptyList()`，`loadLogsFromPrefs` **只读开关、不读日志** | `LogManager.java:68-76`；`:276-278` |
| 是否有日志文件？ | **无**。全仓无 `openFileOutput` / `FileOutputStream` / 日志文件写入 | 全仓 grep 零命中 |
| 进程重启后 | 日志**全部丢失**，回到空列表 | `LogManager.java:68`、`:76` |

```java
// LogManager.java:276-284
private final void loadLogsFromPrefs(Context context) {
    this._isEnabled.setValue(Boolean.valueOf(context.getSharedPreferences("log_prefs", 0).getBoolean("log_enabled", true)));
}

public final void saveEnabledState(Context context, boolean enabled) {
    Intrinsics.checkNotNullParameter(context, "enabled");   // 反编译显示的参数校验
    context.getSharedPreferences("log_prefs", 0).edit().putBoolean("log_enabled", enabled).apply();
    this._isEnabled.setValue(Boolean.valueOf(enabled));
}
```

`LogManager` 是单例（`LogManager.java:24`、`:97-113`），所以全进程共享同一份内存日志。

### 6.2 日志条目结构（内存模型）

`LogEntry` 是 data class，6 个字段（`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\LogEntry.java:13-20`）：

| 字段 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `id` | Long | 无（必填，自增起点 `1`） | 由 `LogManager.nextId` 自增签发，初值 `1`（`LogManager.java:75`、`:132-133`） |
| `timestamp` | Long | `System.currentTimeMillis()` | 毫秒时间戳 |
| `level` | LogLevel | 无 | 枚举 `DEBUG` / `INFO` / `WARNING` / `ERROR`（`LogManager.java:44-57`） |
| `tag` | String | 无 | 调用方传入 |
| `message` | String | 无 | 调用方传入 |
| `throwable` | Throwable? | `null` | 可空 |

构造默认值证据：`LogEntry.java:96-98`（`(i & 2) != 0 ? System.currentTimeMillis() : j2` 与 `(i & 32) != 0 ? null : th`）。

### 6.3 时间戳格式（两种，均为 `SimpleDateFormat` + `Locale.getDefault()`）

| 方法 | 格式串（逐字） | 证据 |
| --- | --- | --- |
| `getFormattedTime()` | `HH:mm:ss.SSS` | `LogEntry.java:121` |
| `getFormattedDate()` | `yyyy-MM-dd HH:mm:ss` | `LogEntry.java:127` |

### 6.4 导出格式（`exportLogsToString`）

条目之间以**两个换行** `"\n\n"` 连接；每条格式为：

```
[yyyy-MM-dd HH:mm:ss] [级别显示名] [tag]
<message><"\n" + 完整堆栈 或 "">
```

证据：`LogManager.java:249-273`。关键行逐字：

```java
// LogManager.java:250 — 分隔符 "\n\n"
CollectionsKt.joinToString$default(this._logs.getValue(), "\n\n", null, null, 0, null, new Function1<...>() { ... }, 30, null);

// LogManager.java:267-271
if (throwable != null) { str = "\n" + ExceptionsKt.stackTraceToString(throwable); }
str = "";
return "[" + formattedDate + "] [" + displayName + "] [" + tag + "]\n" + message + str;
```

> 反编译缺陷提示：`:270` 的 `str = "";` 是 jadx 控制流还原错误（`if` 分支后无条件重写 `str`），**原意显然是保留堆栈**。以 smali/`LogManager.kt:131` 为准时需人工校正；本文按「throwable 存在则追加堆栈」记录，原样抄写该行以便比对。

### 6.5 上限条数

| 项 | 值 | 证据 |
| --- | --- | --- |
| `maxLogs` | **`500`** | `LogManager.java:74`（`this.maxLogs = 500;`） |
| 淘汰策略 | **头部插入 + 尾部淘汰**：`mutableList.add(0, logEntry)`，若 `size > 500` 则 `remove(size - 1)` | `LogManager.java:136-139` |
| 上限检查时机 | 每次 `log(...)` 调用时 | `LogManager.java:137` |

```java
// LogManager.java:135-140
List<LogEntry> mutableList = CollectionsKt.toMutableList((Collection) this._logs.getValue());
mutableList.add(0, logEntry);
if (mutableList.size() > this.maxLogs) {
    mutableList.remove(mutableList.size() - 1);
}
this._logs.setValue(mutableList);
```

### 6.6 过滤与清空

| 方法 | 行为 | 证据 |
| --- | --- | --- |
| `filterLogs(level, tag)` | `level != null` 时按级别精确匹配；`tag` 非空时按 tag **忽略大小写包含**匹配（`StringsKt.contains(..., true)`） | `LogManager.java:225-247`（`:242` 是 `contains(..., ignoreCase=true)`） |
| `clearLogs()` | 仅清内存（`_logs = emptyList()`），**不写盘** | `LogManager.java:211-213` |
| `log(level, tag, message, throwable)` | 先判 `_isEnabled`；关闭时**完全不记录也不打 Logcat** | `LogManager.java:131-156` |
| Logcat 转发 | 同时按级别转发到 `android.util.Log.d/i/w/e` | `LogManager.java:141-155` |

---

## 7. 其它 key（提醒 / widget / 弹窗 / 未持久化项）

### 7.1 提醒相关

| key | 类型 | 默认值 | 用途 | 证据 |
| --- | --- | --- | --- | --- |
| `reminder_alarm_ids` | String(JSON 数组) | `""` | 已排程 alarm 的 `courseId_触发毫秒` 去重列表，用于下次 `rescheduleAll` 前全量取消 | `CourseReminderScheduler.java:35`、`:140`、`:145` |

调度窗口：**未来 15 天**（`while (i2 < 15)`，`CourseReminderScheduler.java:62`）。`PendingIntent` flag 用字面量 `201326592`（= `FLAG_UPDATE_CURRENT|FLAG_IMMUTABLE`）与 `603979776`（取消侧）。提醒提前量取自 `classReminderMinutes`（`:88`，`coerceAtLeast(..., 1)`）。

### 7.2 widget 相关

widget **不写任何 key**，只**读**两个 UI 开关；无自己命名的 preference 文件。

| 调用方 | 读的 key | 行为 | 证据 |
| --- | --- | --- | --- |
| `DshWidgetRenderer.isDark` | `ui_dark_mode` | `contains` 为真则取该值；**缺 key 时回退系统深色**（`uiMode & 48 == 32`） | `DshWidgetRenderer.java:530-537` |
| `DshWidgetRenderer.isOptimized` | `ui_optimize_mode` | `contains` 为真且为真才开启；缺 key 视为关闭 | `DshWidgetRenderer.java:539-542` |
| `DshWidget`（Kotlin 重建稿） | 同上两个 | 同上语义（`Configuration.UI_MODE_NIGHT_YES`） | `DshWidget.kt:480-491` |

> 注意语义差异：`isDark` 缺 key 时回退**系统**；而 `ThemeMode.init` 缺 key 时回退 **`false`**（`ThemeMode.java:28`）。即「未设置过」时 widget 与主界面的深色判断可能不一致。

### 7.3 弹窗「不再提示」

| key | 类型 | 默认值 | 对应 API | 证据 |
| --- | --- | --- | --- | --- |
| `disclaimer_dont_show` | Boolean | `false` | `isDisclaimerDismissedPermanently()` / `setDisclaimerDismissedPermanently(boolean dontShow)` | `LocalStorage.java:281-287` |
| `usage_guide_dont_show` | Boolean | `false` | `isUsageGuideDismissedPermanently()` / `setUsageGuideDismissedPermanently(boolean z)` | `LocalStorage.java:289-295` |

### 7.4 `currentWeekOffset` —— **不持久化**

| 项 | 结论 | 证据 |
| --- | --- | --- |
| 存储 | **纯内存** `MutableStateFlow<Integer>`，初值 `0` | `TimetableViewModel.java:74-76` |
| 写入 | `setCurrentWeekOffset(int offset)` 只 `setValue`，**无 prefs 写入** | `TimetableViewModel.java:117-119` |
| SharedPreferences 中对应 key | **不存在**（全仓无 `weekOffset` / `currentWeekOffset` 的 prefs 调用） | grep 零命中 |
| 重启后 | 复位为 `0` | `TimetableViewModel.java:74` |

### 7.5 其它「看起来像持久化但实际没有」的项

| 项 | 实际存储 | 证据 |
| --- | --- | --- |
| `AppSettings.id` | 不持久化；反序列化恒得 `0` | `LocalStorage.java:64`（无 id）、`:89`（首参 `0`） |
| `UserCredentials.id` | 不持久化；读取硬编码 `1` | `LocalStorage.java:59` |
| `LogEntry` 全部字段 | 不持久化 | §6.1 |
| `TimetableViewModel._isRefreshing` / `_refreshError` | 不持久化（内存 StateFlow） | `TimetableViewModel.java:68-73` |
| widget 的尺寸/主题配置 | 走 `AppWidgetManager` 的 `RemoteViews` 组件名后缀（`"dk"`/`"lt"`），非 SharedPreferences | `DshWidgetRenderer.java:521-523` |
| WorkManager 输入数据 `trigger_hour` | 存于 WorkManager 自己的数据库，**不是** `timetable_prefs` | `TimetableAutoRefreshWorker.java:78`、`TimetableAutoRefreshAlarmReceiver.java:24` |

---

## 8. QiangzhiJwxtParser 概览（事实，不含设计）

> 该类**不持久化任何数据**（无 SharedPreferences 引用）。Cookie 只存在内存 `private Map<String, String> cookies`（`QiangzhiJwxtParser.java:49`），进程重启即失效。

### 8.1 URL 与 HTTP 方法

| 步骤 | URL（相对 `baseUrl`，逐字） | 方法 | 证据 |
| --- | --- | --- | --- |
| 1. 取初始 Cookie | `"/"` | GET | `QiangzhiJwxtParser$login$2.java:139`、`:145` |
| 2. 取加密参数 | `"/Logon.do?method=logon&flag=sess"` | **POST** | `QiangzhiJwxtParser$login$2.java:152`、`:158` |
| 3. 正式登录 | `"/Logon.do?method=logon"` | **POST** (`application/x-www-form-urlencoded`) | `QiangzhiJwxtParser$login$2.java:193`、`:199` |
| 4. 登录后首页（校验） | `"/jsxsd/framework/xsMainV.htmlx"` | GET | `QiangzhiJwxtParser$login$2.java:232`、`:247`、`:285`、`:321` |
| 5. 选课入口网关页 | `"/jsxsd/framework/xsrkxz.htmlx"`（Referer）、`"/jsxsd/framework/xsMainV.jsp"`（GET） | GET | `QiangzhiJwxtParser.java:118-120` |
| 6. 课表 | `"/jsxsd/xskb/xskb_list.do"` | **GET** | `QiangzhiJwxtParser$fetchTimetable$2.java:79`、`:96-98` |

- `baseUrl` 由外部传入；`secureBaseUrl` 会把开头的 `"http://"` 替换为 `"https://"`（`QiangzhiJwxtParser.java:77-82`）。
- 请求头固定：`User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36`，`Referer` 按上述取值（`QiangzhiJwxtParser.java:120`，`$login$2.java:199`、`:254`）。
- 全部请求 `.ignoreHttpErrors(true)`（自行判状态码）。

### 8.2 请求参数名

登录 POST 的三个表单字段（逐字）：

| 参数名 | 值 | 证据 |
| --- | --- | --- |
| `userAccount` | 用户名 | `QiangzhiJwxtParser$login$2.java:199` |
| `userPassword` | **空字符串 `""`** | `QiangzhiJwxtParser$login$2.java:199` |
| `encoded` | `encryptCode(username + "%%%" + password, scode, sxh)` | `QiangzhiJwxtParser$login$2.java:186`、`:199` |

`encoded` 的算法（`encryptCode`，`QiangzhiJwxtParser.java:127-162`）：把明文分成**前 20 个字符**与其余部分；前 20 字符逐位取 `sxh` 对应位数字 `n`，输出「原字符 + `scodeOrig` 的前 `n` 个字符」，并从 `scodeOrig` 前部截掉这 `n` 个字符；第 21 位起原样拼接。
`sxh` / `scode` 来自步骤 2 的响应体，按 `"#"` 分割（`$login$2.java:172-175`）：`split[0]` 记为 `scode`，`split[1]` 记为 `sxh`；响应为 `"no"` 或无 `"#"` 时走失败分支。

### 8.3 Cookie 名称

**无法确定 —— 反编译里读不出具体 Cookie 名。**

- 代码全程使用 `Map<String, String> cookies` 整体透传（`.cookies(map)`）与 `execute().cookies()` 整体合并，**从未出现任何硬编码的 Cookie 名（如 `JSESSIONID`）**：`QiangzhiJwxtParser.java:120-122`、`$login$2.java:145`、`:205-209`、`:254`、`:257`；`$fetchTimetable$2.java:97-98`。
- 因此 Cookie 名由**服务器 `Set-Cookie` 决定**，静态无法枚举。
- 唯一可确定的事实：代码日志里打印 Cookie **数量**（`"当前Cookie数量: " + map.size()`，`$fetchTimetable$2.java:94`）而非名称。

### 8.4 是否有验证码

**结论：反编译中不存在验证码（CAPTCHA）识别或输入的任何代码路径。**

| 检查项 | 结果 | 证据 |
| --- | --- | --- |
| 是否存在 `checkcode` / `yzm` / `captcha` / `验证码` 字面量 | **零命中**（`QiangzhiJwxtParser*.java` 全量 grep） | 无 |
| 登录 POST 是否带验证码字段 | **否**，仅 `userAccount` / `userPassword` / `encoded` 三个参数 | `$login$2.java:199` |
| 是否识别验证码图片 | **否**，无图片下载/识别调用 | 无 |
| 失败分支判据 | 仅按响应文本包含 `"欢迎"`/`"主页"` 判定成功；`"用户名或密码错误"`/`"密码错误"` 判定失败；页面 `<title>` 为 `"登录"` 或包含 `"Login"` 判定未登录 | `$login$2.java:227-242` |
| 选课入口拦截 | 通过 URL/正文含 `"xsrkxz"`、`"入口选择"`、`"进入选课"`+`"进入首页"` 判定，并模拟「进入首页」 | `QiangzhiJwxtParser.java:108-113` |

> 严格表述：**反编译产物中不存在验证码处理代码**。若该教务系统服务端要求验证码，此处即为无法登录（或该校不启用验证码）。

### 8.5 HTML 选择器（jsoup `select(...)` 字符串，逐字）

| 选择器字符串 | 用途 | 证据 |
| --- | --- | --- |
| `table#timetable` | DO 风格课表入口（`selectFirst`） | `QiangzhiJwxtParser.java:171` |
| `tr` | 遍历行（在 `table#timetable` 内） | `QiangzhiJwxtParser.java:175` |
| `th` | 取每行首格文本，判是否含 `第` + `大节`（`selectFirst`） | `QiangzhiJwxtParser.java:183`、`:189` |
| `> td` | 行内直接子单元格（列 = 星期，1..7 有效） | `QiangzhiJwxtParser.java:191`、`:200` |
| `div.kbcontent` | 单元格内容候选 1 | `QiangzhiJwxtParser.java:232` |
| `div.kbcontent1` | 单元格内容候选 2（回退） | `QiangzhiJwxtParser.java:270` |
| `font` | 通用字体节点提取 | `QiangzhiJwxtParser.java:1019` |
| `font[title='教师'], font[title="教师"]` | 教师名 | `QiangzhiJwxtParser.java:1070` |
| `font[title='教室'], font[title="教室"]` | 教室名 | `QiangzhiJwxtParser.java:1125` |
| `font[name=jxlmc], font[title='教学楼'], font[title="教学楼"]` | 教学楼名（属性 `jxlmc`） | `QiangzhiJwxtParser.java:1159` |
| `[title]` | 兜底：任意带 `title` 属性的节点 | `QiangzhiJwxtParser.java:1176`、`:1201` |
| `title` | 登录校验用页面标题（`.parse().select("title").text()`） | `QiangzhiJwxtParser$login$2.java:232` |

另有非 jsoup 的字符串解析路径（WakeUp 风格）：以 `"Table1"` 定位表格，再按 `"<tr>"` / `"</tr>"` / `"left=100,top=50')\">"` / `"<br>"` / `"</td>"` 切分，并用正则 `^(周)[一二三四五六日]` 取星期（`QiangzhiJwxtParser.java:324-343`、`:361`、`:371`、`:379`）。

解析优先级：**先 DO 风格（`parseDoStyle`），为空再试 WakeUp 风格（`parseWakeUpStyle`）**；都为空则返回空列表并记 warning `"未命中可用课表解析规则，返回空课表"`（`QiangzhiJwxtParser$fetchTimetable$2.java:115-125`）。

### 8.6 返回结构如何映射到 Course 字段

**DO 风格**（`parseDoStyle` + `parseKbContent`，参数为 `(content, 大节序号 i, 星期列号 i3)`）：

| `Course` 字段 | 来源 | 证据 |
| --- | --- | --- |
| `id` | 固定 `0` | `QiangzhiJwxtParser.java:460`、`:475`、`:480` |
| `name` | 内容第 1 段（`split[0]`，`trim`） | `:460`、`:475`、`:480` |
| `teacher` | 内容第 3 段（`split[2]`，或 `split[2]` 取 `/` 后半的 `(` 前部分） | `:460`、`:473`、`:475` |
| `location` | 内容第 4 段（`split[3]`，或 `split[2]` 取 `(` 内部分） | `:460`、`:472`、`:475` |
| `dayOfWeek` | `i3`，即 `td` 列号（1..7，`1 <= i3 < 8`） | `:200`、`:204`、`:460` |
| `startPeriod` | `i`，即第几个「第N大节」行 | `:190`、`:204`、`:460` |
| `endPeriod` | `(第N大节 + 连堂节数) - 1` | `:459`、`:475`、`:480` |
| `color` | `getStableColor(name)`（按课程名稳定取色，调色板 10 色） | `:460`、`:63` |
| `weekRange` | `startWeek + "-" + endWeek` | `:460`、`:475`、`:480` |
| `startWeek` | `extractWakeUpStartWeek(节次串)`，缺省 `1` | `:453`、`:512-514` |
| `endWeek` | `extractWakeUpEndWeek(节次串)`，缺省 `20` | `:455`、`:515-517` |
| `isOdd` | 含 `"单周"` → `1`；含 `"双周"` → `2`；否则 `0` | `:438-442` |

**WakeUp 风格**（`parseWakeUpStyle` / `parseWakeUpLater`）：同一套字段语义，但星期取自正则 `^(周)[一二三四五六日]` 的匹配值（`周一`→1 … `周日`→7，`QiangzhiJwxtParser.java:379-431`），`dayOfWeek` 传入 `i`；`Course` 构造位置见 `:672`、`:686`。

**后处理**：`mergeDuplicateCourses(...)` 去重 → `collapseAdjacentCourses(...)` 合并连排（`QiangzhiJwxtParser$fetchTimetable$2.java:127-128`），日志输出「原始 N 门 / 去重后 M 门 / 合并连排后 K 门」（`:134`）。

**调色板**（`getStableColor` 取值域，10 个 int 逐字）：`-11751600, -14575885, -26624, -6543440, -16728876, -43230, -8825528, -10453621, -12627531, -1499549`（`QiangzhiJwxtParser.java:63`）。其中 `-11751600` 与 `getCourses` 里 `color` 的兜底默认值一致。

**课表页会话过期判据**：HTTP `302` 且 `location` 含 `"Login"` → 记 warning `"Session已过期，需要重新登录"` 并返回空列表（`QiangzhiJwxtParser$fetchTimetable$2.java:104-111`）。

---

## 9. 不确定项（不做推测）

| 编号 | 不确定项 | 现状与证据 | 影响 |
| --- | --- | --- | --- |
| U1 | **包名/`dataDir` 未确证** | 反编译树里只筛出 `R.java`（`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\R.java`），未能定位 `AndroidManifest.xml`。代码里可见的命名空间是 `kebiaocom.example`，但**未从 manifest 的 `package=` 属性确认** | 仅影响「XML 落盘绝对路径」的措辞，不影响任何 key/类型/默认值 |
| U2 | **`AppSettings.id` 反序列化后的真实值** | `AppSettings.kt:15` 声明默认 `1`；但 `LocalStorage.java:89` 用默认值掩码（尾参 `1, null`）构造，`AppSettings.java` 里 `getId()` 在被 jadx 处理时被改动过。**无法从反编译确定 `getSettings()` 返回对象的 `id` 是 `1` 还是 `0`** | 低。`id` 既不写入也不参与任何持久化键，仅影响内存对象相等性 |
| U3 | **`autoCheckUpdate` 默认值冲突** | 读取侧 `LocalStorage.java:83` 明确是 `getBoolean("autoCheckUpdate", false)`；而 `AppSettings.kt:34` 声明 Kotlin 默认 `true`。两者矛盾，**无法确定原稿哪个是「对的」** | 中。iOS 侧「首次启动未写入时」应取 **`false`**（以反编译的读取字面量为准），否则行为与 Android 不一致 |
| U4 | **`setUsageGuideDismissedPermanently` 的参数名** | `@Metadata` 的 `d2` 名字表里**没有**这对方法的条目（疑似后期新增），参数名无法从字节码恢复。`LocalStorage.kt:278-279` 已标注 FIXME | 无。仅参数名，行为（写 `usage_guide_dont_show`）已由 `LocalStorage.java:294` 确证 |
| U5 | **`SharedPreferences` XML 的内部细节** | XML 元素形态（`<string>`/`<int>`/`<boolean>`）、文件编码（UTF-8）、**同层 key 的写出顺序**（`org.json.JSONObject.toString()` 的键序同理）属于 Android 框架/库实现，**本次无法从反编译产物确定**（网络不可用，无法核对 AOSP 源码） | 低-中。若 iOS 侧要「替换文件后 Android 仍能读」或反之，需真机导出 XML 逐字节比对；**不能假定键序稳定** |

### 其它需注意但已确定的事实（非不确定项，列此以免遗漏）

1. `showWeekend` 是**只读**的遗留 key，1.11.5 不再写入；新装的 App 中它不存在。
2. `courses_json` / `timetable_profiles_json` / `reminder_alarm_ids` 三个 key 的「不存在」与「空串」语义相同（都走 fallback 分支）。
3. `isOdd` 是 `Int`（`0`/`1`/`2`），不是 Boolean —— JSON 里也是 number。iOS 若用 `Bool` 会在 `2`（双周）上丢信息。
4. `clearAll()` 只清 `timetable_prefs`，`log_prefs` 的 `log_enabled` 会存活。
5. `saveCredentials` 用 `commit()`（同步阻塞），其余写路径用 `apply()`。
6. `selectedTimetableProfileId` 与档案 `id` 之间**没有任何存在性校验**（可为悬挂引用）。
7. `TimetableProfile` 读取时按 `PeriodTime.index` 升序重排，JSON 内顺序不被信任。
8. 日志（`LogEntry`）**不落盘**，`maxLogs = 500`，超出时从尾部淘汰，新的插入到索引 0。

---

## 10. 证据文件索引

| 文件 | 作用 |
| --- | --- |
| `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\LocalStorage.java` | 主证据：prefs 文件名、全部业务 key、JSON 结构、默认档案（296 行） |
| `apk_work\proj_dec\smali_classes3\kebiaocom\example\data\LocalStorage.smali` | smali 交叉验证：全部 key 字面量逐字一致（含 `:93` `timetable_prefs`、`:403` `courses_json`、`:1116` `timetable_profiles_json`、`:1444` `disclaimer_dont_show`、`:1461` `usage_guide_dont_show`） |
| `上课早枝道-源码-1.11.5\app\src\main\kotlin\kebiaocom\example\data\LocalStorage.kt` | 已重建 Kotlin（283 行）；`Context.MODE_PRIVATE` 与键名一致，含 1 处 FIXME（U4） |
| `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\AppSettings.java` / `...\kotlin\...\AppSettings.kt` | 27 个字段与默认值（`AppSettings.kt:14-47`） |
| `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\Course.java` / `...\kotlin\...\Course.kt` | 12 个字段、`isOdd` 为 Int |
| `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\UserCredentials.java` / `...\kotlin\...\UserCredentials.kt` | `DEFAULT_JWXT_URL = "https://jwgl.xihang.com.cn"` |
| `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\TimetableProfile.java`、`PeriodTime.java` | 档案与节次模型 |
| `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\LogManager.java`、`LogEntry.java` | 日志不落盘、`maxLogs = 500`、两种时间格式、导出格式 |
| `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\reminder\CourseReminderScheduler.java` | `PREFS = "timetable_prefs"`、`KEY_ALARM_IDS = "reminder_alarm_ids"`、alarm id 规则 |
| `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\theme\ThemeMode.java`、`OptimizeMode.java` | `ui_dark_mode` / `ui_optimize_mode` |
| `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\widget\DshWidgetRenderer.java`（`:521-542`）、`...\kotlin\...\widget\DshWidget.kt`（`:477-491`） | widget 只读两个 UI 开关 |
| `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\ui\TimetableViewModel.java`（`:33`、`:74-76`、`:117-119`） | `currentWeekOffset` 不持久化 |
| `apk_work\jadx_out\sources\androidx\autofill\HintConstants.java`（`:21`、`:24`、`:48`） | `AUTOFILL_HINT_NAME = "name"`、`_PASSWORD = "password"`、`_USERNAME = "username"` |
| `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\data\QiangzhiJwxtParser.java`、`QiangzhiJwxtParser$login$2.java`、`QiangzhiJwxtParser$fetchTimetable$2.java` | 教务系统登录/抓取事实（§8） |

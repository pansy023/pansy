# 04 · 桌面小组件（App Widget）——反编译源码逐字提取

> **来源优先级**：真实 Kotlin 源码（`app/src/main/kotlin/**`，若存在）> jadx 反编译 Java（`上课早枝道-源码-1.11.5/app/src/main/**`）> 1.11.5 实机 smali（`apk_work/proj_dec/**`）。
> jadx 有代码丢失的地方一律以 **Kotlin 原文 + smali** 交叉确证，并在文中标出 `// ⚠️ jadx 丢失`。
> 本文所有代码块均为**原文照抄**；所有数值均带 `File.java:line` 出处。凡无法确定的一律进 §8「不确定项/无法验证」，**不做推测填充**。
>
> 本文件只描述 **Android 侧事实**；§7 的对照表只回答「WidgetKit 有没有对应能力」，不含 iOS 设计提案。

## 0. 材料清单与可信度

| 代号 | 路径 | 说明 |
|---|---|---|
| **J-R** | `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\widget\DshWidgetRenderer.java` | 827 行，jadx 产物（`/* compiled from: DshWidget.kt */`，`/* loaded from: classes4.dex */`）。**渲染全部逻辑**。 |
| **K-R** | `上课早枝道-源码-1.11.5\app\src\main\kotlin\kebiaocom\example\widget\DshWidget.kt` | 651 行，**权威原文**（仓库内附的 Kotlin 还原版）。头注释 `:22-43` 明确「随 APK 打包进 class4.dex」。 |
| **J-P** | `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\widget\DshWidget{2x2,2x4,2x4b,2x4c,4x4}Provider.java` | 5 个 provider，各 32 行，只做转发。 |
| **J-F** | `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\widget\DshWidgetRefreshReceiver.java` | 21 行，唯一的刷新广播接收者。 |
| **J-T** | `上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\widget\WidgetTimetableHelperKt.java` | 402 行，**数据层**（`loadWidgetContext` / 当日课程筛选 / 文案拼接）。 |
| **M** | `上课早枝道-源码-1.11.5\app\src\main\AndroidManifest.xml` | 150 行，与实机 `apk_work\proj_dec\AndroidManifest.xml` 的小组件段一致（见 §1.1 注）。 |
| **X** | `上课早枝道-源码-1.11.5\app\src\main\res\xml\dsh_widget_provider_*.xml` | 5 个 `appwidget-provider` 描述。 |
| **L** | `上课早枝道-源码-1.11.5\app\src\main\res\layout\dsh_widget_*.xml` | 5 个 RemoteViews 布局。 |
| **DR** | `上课早枝道-源码-1.11.5\app\src\main\res\drawable\`、`res\drawable-night\` | `dsh_panel*` / `dsh_div*` / `dsh_bar_N` / `dsh_block_N` / `dsh_cbar_*` / `dsh_cblock_*`（`.xml` 形状资源）。 |
| **V** | `上课早枝道-源码-1.11.5\app\src\main\res\values\dsh_{colors,strings,ids}.xml`、`res\values-night\dsh_colors.xml` | 颜色/文案/id 表。 |
| **S** | `apk_work\proj_dec\smali_classes4\kebiaocom\example\widget\DshWidgetRenderer.smali` | 实机 smali，用于确认 jadx 丢失的 `layoutName` 默认分支。 |

**关键结论速览（TL;DR）**

| 项 | Android 实现（确切值） |
|---|---|
| 小组件数量 | **5 个**，全部是 `AppWidgetProvider`（= `BroadcastReceiver`），无 `RemoteViewsService` |
| 入口 | 每个 provider 只实现 `onUpdate` / `onEnabled` / `onDisabled`（J-P `:14,:22,:28`） |
| 渲染 | 单一渲染器 `DshWidgetRenderer.INSTANCE.update(context, manager, ids, kind)` → `RemoteViews`（J-R `:56-73`） |
| 尺寸 | 由 **provider 类**决定（`kind` 字符串常量），**不读** `AppWidgetManager.getAppWidgetOptions` |
| 主题 | 读 App 自己的 `timetable_prefs`：`ui_dark_mode` / `ui_optimize_mode`，**不跟系统深色模式**（除非 app 未写过该 key） |
| 配色 | 12 色 Morandi 调色板，**索引 = `abs(name.hashCode()) % 12`**（按课程名取色） |
| 刷新 | 系统 `updatePeriodMillis=1800000`（30 分钟）+ 自建 `AlarmManager` 边界闹钟 + 6 个广播 action |
| 点击 | 整块面板一个 `PendingIntent.getActivity`，**不带任何 extra / deep link** |
| 内容 | 今天（今天无课则顺延到未来 7 天内第一个有课的日子），不是整周 |

---

## 1. 清单注册（AndroidManifest.xml）

### 1.1 与小组件相关的全部声明

```xml
<!-- 上课早枝道-源码-1.11.5/app/src/main/AndroidManifest.xml:38 -->
        <!-- DSH-WIDGET-SET -->
```

`apk_work/proj_dec/AndroidManifest.xml:38` 有同样字面量的注释，证明这套 widget 确实进了实机包。

**5 个小组件 provider**（`M:39-68`，每块形如）：

```xml
        <receiver android:exported="true" android:label="@string/dsh_widget_2x2_label" android:name="kebiaocom.example.widget.DshWidget2x2Provider">
            <intent-filter>
                <action android:name="android.appwidget.action.APPWIDGET_UPDATE"/>
            </intent-filter>
            <meta-data android:name="android.appwidget.provider" android:resource="@xml/dsh_widget_provider_2x2"/>
        </receiver>
```

| # | 类名（`M:` 行） | `android:label` | `meta-data` 资源 |
|---|---|---|---|
| 1 | `kebiaocom.example.widget.DshWidget2x2Provider`（`:39-44`） | `@string/dsh_widget_2x2_label` | `@xml/dsh_widget_provider_2x2` |
| 2 | `kebiaocom.example.widget.DshWidget2x4Provider`（`:45-50`） | `@string/dsh_widget_24_label` | `@xml/dsh_widget_provider_2x4` |
| 3 | `kebiaocom.example.widget.DshWidget2x4bProvider`（`:51-56`） | `@string/dsh_widget_24b_label` | `@xml/dsh_widget_provider_2x4b` |
| 4 | `kebiaocom.example.widget.DshWidget2x4cProvider`（`:57-62`） | `@string/dsh_widget_24c_label` | `@xml/dsh_widget_provider_2x4c` |
| 5 | `kebiaocom.example.widget.DshWidget4x4Provider`（`:63-68`） | `@string/dsh_widget_44_label` | `@xml/dsh_widget_provider_4x4` |

**唯一的刷新接收者**（`M:69-78`）：

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

> ⚠️ 与「历史遗留 widget」相关的两个声明也在清单里，但不属于 DSH 这套：
> `M:28-32` receiver `kebiaocom.example.widget.TimetableWidgetRefreshReceiver`（`exported="false"`，同样过滤 `REFRESH_TIMETABLE_WIDGETS`）；
> `M:33-37` receiver `kebiaocom.example.widget.WidgetBootReceiver`（`exported="true"`，过滤 `BOOT_COMPLETED`）；
> `M:79-80` service `TodayWidgetRemoteViewsService` / `RecentWidgetRemoteViewsService`（`exported="false"` + `android:permission="android.permission.BIND_REMOTEVIEWS"`）。
> **这 4 个历史 provider 类（`TodayCoursesWidgetProvider`、`TodayCourses4x2WidgetProvider`、`RecentCoursesWidgetProvider`、`DayStripWidgetProvider`）在 `AndroidManifest.xml` 中没有任何声明**——它们的 `res/xml/widget_provider_*.xml` 仍在磁盘上，但没有任何 `<meta-data>` 引用。它们是被 `TimetableWidgetRefresh.updateAll`（`J-T` 同目录 `TimetableWidgetRefresh.java:28-36`）点名刷新的「死代码」，`getAppWidgetIds` 恒为空数组。

**结论**：小组件全部是 `BroadcastReceiver`（`AppWidgetProvider extends BroadcastReceiver`），**没有任何 widget service**；实机可见的就是 5 个 DSH 小组件。

### 1.2 `appwidget-provider` 属性（X，逐文件）

5 个文件都是 `<appwidget-provider>` 根元素，公共属性：

| 属性 | 值 | 出处 |
|---|---|---|
| `android:resizeMode` | `"horizontal\|vertical"` | `X:dsh_widget_provider_2x2.xml:4`（5 个文件同值） |
| `android:widgetCategory` | `"home_screen"` | `dsh_widget_provider_2x2.xml:12` |
| `android:updatePeriodMillis` | **`1800000`** | `dsh_widget_provider_2x2.xml:5` |
| `android:initialLayout` | 与 `android:previewLayout` **同值** | `dsh_widget_provider_2x2.xml:6,11` |
| `android:description` | `@string/dsh_widget_*_label` | `dsh_widget_provider_2x2.xml:13` |
| `android:previewImage` | **不存在**（5 个文件都没有该属性） | — |

逐文件尺寸表：

| 文件 | minWidth | minHeight | targetCellWidth | targetCellHeight | minResizeWidth | minResizeHeight | initialLayout = previewLayout |
|---|---|---|---|---|---|---|---|
| `dsh_widget_provider_2x2.xml` | 110dp | 110dp | 2 | 2 | 110dp | 110dp | `@layout/dsh_widget_2x2` |
| `dsh_widget_provider_2x4.xml` | 110dp | 180dp | 2 | 4 | 110dp | 180dp | `@layout/dsh_widget_2x4` |
| `dsh_widget_provider_2x4b.xml` | 180dp | 110dp | 4 | 2 | 180dp | 110dp | `@layout/dsh_widget_2x4b` |
| `dsh_widget_provider_2x4c.xml` | 180dp | 110dp | 4 | 2 | 180dp | 110dp | `@layout/dsh_widget_2x4c` |
| `dsh_widget_provider_4x4.xml` | 250dp | 250dp | 4 | 4 | 250dp | 250dp | `@layout/dsh_widget_4x4` |

出处：`res/xml/dsh_widget_provider_2x2.xml:2-14`、`dsh_widget_provider_2x4.xml`、`dsh_widget_provider_2x4b.xml`、`dsh_widget_provider_2x4c.xml`、`dsh_widget_provider_4x4.xml` 各自全文。

两点必须记录的证据性细节：

1. **文件名与实际格子数不一致**：`2x4b` / `2x4c` 的 `targetCellWidth=4, targetCellHeight=2`（即 4 宽 × 2 高），而 kind 字符串/文件名读作 `2x4b`/`2x4c`；`2x4` 是 2 宽 × 4 高。**命名与摆放格子数不同向**。
2. **`minResizeWidth/minResizeHeight` 恒等于 `minWidth/minHeight`**，即 XML 把「最小尺寸」钉死在设计尺寸上（用户可以拉伸，但下限就是初始值）。
3. `targetCellWidth/targetCellHeight` 是 API 31+ 属性，且只是**给启动器排版的建议值**，不参与渲染。

---

## 2. 渲染器 DshWidgetRenderer

### 2.1 入口点（实际存在的只有 3 个，且都不在渲染器里）

每个 provider 完整实现（以 `J-P:DshWidget2x2Provider.java` 为例，其余 4 个逐字相同，仅 `KIND_*` 常量不同）：

```java
public final class DshWidget2x2Provider extends AppWidgetProvider {           // :12
    @Override // android.appwidget.AppWidgetProvider
    public void onUpdate(Context context, AppWidgetManager manager, int[] ids) {  // :14
        Intrinsics.checkNotNullParameter(context, "context");
        Intrinsics.checkNotNullParameter(manager, "manager");
        Intrinsics.checkNotNullParameter(ids, "ids");
        DshWidgetRenderer.INSTANCE.update(context, manager, ids, DshWidgetRenderer.KIND_2X2); // :18
    }

    @Override // android.appwidget.AppWidgetProvider
    public void onEnabled(Context context) {                                   // :22
        DshWidgetRenderer.INSTANCE.arm(context);                               // :24
    }

    @Override // android.appwidget.AppWidgetProvider
    public void onDisabled(Context context) {                                  // :28
        DshWidgetRenderer.INSTANCE.disarm(context);                            // :30
    }
}
```

对照实机 smali（`apk_work/proj_dec/smali_classes4/kebiaocom/example/widget/DshWidget2x2Provider.smali`）：`onDisabled :49`、`onEnabled :65`、`onUpdate :81`；`disarm` 调用在 `:60`、`arm` 在 `:76`、`update` 在 `:104`。

渲染器一侧的公开入口（`J-R:56-100`）：

```java
    public final void update(Context context, AppWidgetManager manager, int[] ids, String kind) {  // :56
        Intrinsics.checkNotNullParameter(context, "context");
        Intrinsics.checkNotNullParameter(manager, "manager");
        Intrinsics.checkNotNullParameter(ids, "ids");
        Intrinsics.checkNotNullParameter(kind, "kind");
        render(context, manager, ids, kind);        // :61
        scheduleNextBoundary(context);              // :62  ← 每次渲染顺带重排下一个边界闹钟
    }

    private final void render(Context context, AppWidgetManager manager, int[] ids, String kind) { // :65
        RemoteViews views = build(context, kind);   // :66
        if (views == null) {
            return;
        }
        for (int id : ids) {                        // :70
            manager.updateAppWidget(id, views);     // :71  ← 未用 partiallyUpdateAppWidget
        }
    }

    public final void refreshAll(Context context) { // :75
        AppWidgetManager manager = AppWidgetManager.getInstance(context);
        if (manager == null) {
            return;
        }
        for (kotlin.Pair entry : PROVIDERS) {       // :81
            int[] ids = manager.getAppWidgetIds(new ComponentName(context, entry.getFirst())); // :82
            if (ids != null) {
                if (!(ids.length == 0)) {
                    render(context, manager, ids, entry.getSecond());  // :85
                }
            }
        }
        scheduleNextBoundary(context);              // :89
    }

    public final void arm(Context context) { ... scheduleNextBoundary(context); }      // :92-95
    public final void disarm(Context context) { ... cancelBoundary(context); }         // :97-100
```

**没有 `onReceive` 覆写、没有 `onAppWidgetOptionsChanged` 覆写、没有 `onDeleted`/`onRestored`**：
- `grep onAppWidgetOptionsChanged apk_work/proj_dec` → **0 命中**（整个 APK 都没有）。
- 全包 provider 的 `.method` 清单只有 `onDisabled` / `onEnabled` / `onUpdate`（5 个文件各 3 个）。
- 因此：**尺寸变化不会触发任何重绘**；widget 不能「同一实例随尺寸变成另一种排版」。

### 2.2 尺寸/主题的判定

**尺寸由 provider 类写死**，通过 `kind` 常量字符串传入（`J-R:43-47`）：

```java
    public static final String KIND_2X2 = "2x2";     // :43
    public static final String KIND_2X4 = "2x4";     // :44
    public static final String KIND_2X4B = "2x4b";   // :45
    public static final String KIND_2X4C = "2x4c";   // :46
    public static final String KIND_4X4 = "4x4";     // :47
```

provider 与 kind 的对照表（`J-R:48`）：

```java
    private static final kotlin.Pair<Class<? extends AppWidgetProvider>, String>[] PROVIDERS = {TuplesKt.to(DshWidget2x2Provider.class, KIND_2X2), ...};
```

`kind → 布局资源名`（`J-R:565-585`）：

```java
    private final String layoutName(String kind) {          // :565
        switch (kind.hashCode()) {
            case 51820:                                      // "2x2"
                return !kind.equals(KIND_2X2) ? "dsh_widget_4x4" : "dsh_widget_2x2";  // :568
            case 51822:
                if (kind.equals(KIND_2X4)) { return "dsh_widget_2x4"; }   // :571
                break;
            case 1606580:
                if (kind.equals(KIND_2X4B)) { return "dsh_widget_2x4b"; } // :576
                break;
            case 1606581:
                if (kind.equals(KIND_2X4C)) { return "dsh_widget_2x4c"; } // :581
                break;
        }
    }                                                        // :585  ← jadx 把默认分支丢了
```

> ⚠️ **jadx 丢失**：`J-R:551-564` 有 `Failed to restore switch over string` 警告，`:565-585` 的 `switch` **没有 `default`**，`KIND_4X4` 也没有 case，于是 `layoutName("4x4")` 在 jadx 代码里会落到方法末尾返回 `null`。
> **以 Kotlin 原文为准**（`K-R:500-506`）：`else -> "dsh_widget_4x4"`。
> **实机 smali 三证**（`apk_work/proj_dec/smali_classes4/kebiaocom/example/widget/DshWidgetRenderer.smali:2682-2702`）：`2x2`→`"dsh_widget_2x2"`（`:2696`）、`2x4`→`"dsh_widget_2x4"`（`:2678`）、`2x4b`→`"dsh_widget_2x4b"`（`:2660`）、`2x4c`→`"dsh_widget_2x4c"`（`:2642`）；**默认跳转 `:goto_38 :2701` → `const-string v0, "dsh_widget_4x4"`（`:2702`）**。

**主题**（`J-R:530-542`）：

```java
    private final boolean isDark(Context context) {          // :530
        SharedPreferences prefs = context.getSharedPreferences("timetable_prefs", 0);  // :531
        if (prefs.contains("ui_dark_mode")) {                // :532
            return prefs.getBoolean("ui_dark_mode", false);  // :533
        }
        int night = context.getResources().getConfiguration().uiMode & 48;  // :535
        return night == 32;                                  // :536
    }

    private final boolean isOptimized(Context context) {     // :539
        SharedPreferences prefs = context.getSharedPreferences("timetable_prefs", 0);
        return prefs.contains("ui_optimize_mode") && prefs.getBoolean("ui_optimize_mode", false); // :541
    }
```

即：`ui_dark_mode` key 存在 → **以 App 自己的深色开关为准**；key 不存在时才回退到系统 `uiMode & 48 == 32`（`MODIFY_MODE_NIGHT` 位）。`ui_optimize_mode`（「优化模式」）单独控制**单色**配色。`K-R:22-43` 的模块头注释原话可交叉印证：*"The widget follows the APP's own 深色模式/优化模式 settings, not the system's"*。

配色三元组（`J-R:544-549`）：

```java
    private final Colors colorsFor(boolean dark, boolean mono) {                             // :544
        if (mono && dark) {
            return new Colors(-15066598, -1726342630, -15066598);                            // :546
        }
        return mono ? new Colors(-1, -1275068417, -1) : dark ? new Colors(-1250068, -6381922, -2067094) : new Colors(-15066598, -9539986, -2467768); // :548
    }
```

`Colors(text, sub, accent)` 构造器在 `J-R:664-668`（参数顺序 **text, sub, accent**）。十进制反解为 ARGB：

| 分支 | text | sub | accent | 触发条件 |
|---|---|---|---|---|
| `mono && dark` | `#FF1A1A1A`（-15066598） | `#991A1A1A`（-1726342630） | `#FF1A1A1A` | 优化模式 + 深色 |
| `mono`（浅） | `#FFFFFFFF`（-1） | `#B3FFFFFF`（-1275068417） | `#FFFFFFFF` | 优化模式 |
| `dark`（非 mono） | `#FFECECEC`（-1250068） | `#FF9E9E9E`（-6381922） | `#FFE0756A`（-2067094） | 深色 |
| 默认（浅） | `#FF1A1A1A` | `#FF6E6E6E` | `#FFDA5848`（-2467768） | 其它 |

> 注意「优化模式」的默认值语义：`isOptimized` 用的是 `contains && getBoolean`（`J-R:541`），所以 key 缺失时是 `false`；而 `isDark` 是 `contains ? getBoolean : 系统`，两者回退策略**不同**。

### 2.3 数据来源：只走 WidgetTimetableHelperKt → LocalStorage

`J-R:285-288`：

```java
        Triple data = WidgetTimetableHelperKt.loadWidgetContext(context);  // :285
        AppSettings settings = data.getFirst();
        List<Course> courses = data.getSecond();
        List<TimetableProfile> profiles = data.getThird();
```

`WidgetTimetableHelperKt.loadWidgetContext`（`J-F` 同文件 `:205-209`）= `new LocalStorage(context)` + `getSettings()/getCourses()/getTimetableProfiles()`，**共享 `timetable_prefs`**（与 App 同一份存储；详见 `storage.md`）。**渲染器自身不直接读任何业务 key**（它只读 `ui_dark_mode` / `ui_optimize_mode` 两个 UI key，`J-R:531,540`）。

### 2.4 显示哪一天：今天 → 今天无课则顺延

`J-R:289-299`：

```java
        Day shown2 = dayFor(settings, courses, profiles, 0);        // :289
        if (shown2.getCells().isEmpty()) {                          // :290
            for (int offset = 1; offset <= 7; offset++) {           // :291
                Day candidate = dayFor(settings, courses, profiles, offset);
                if (!candidate.getCells().isEmpty()) {
                    shown = candidate;                              // :294
                    break;                                          // :295
                }
            }
        }
        shown = shown2;                                             // :299  ← 见下
```

> ⚠️ `:299` 是 jadx 的变量合并产物（Kotlin 原文只有一个 `val day`），**语义上不是「把候选日丢掉」**：`:294` 赋的是同一个局部槽位，`:299` 再赋 `shown2` 会让 `:290-298` 的顺延失效。Kotlin 原文（`K-R` 同段）是单变量 `val` 赋值，即 `shown = candidate` 生效。此处以 Kotlin 为准，并**在 §8 记为实机行为待核**。

`dayFor`（`J-R:442-458`）：

```java
    private final Day dayFor(AppSettings settings, List<Course> courses, List<TimetableProfile> profiles, int offset) {  // :442
        Calendar cal = Calendar.getInstance();
        cal.add(6, offset);                                                     // :445  (6 = Calendar.DAY_OF_MONTH)
        if (offset == 0) {
            raw = WidgetTimetableHelperKt.coursesForToday(settings, courses, profiles);              // :447
        } else {
            raw = WidgetTimetableHelperKt.coursesForCalendarDay(settings, courses, profiles, cal);   // :450
        }
        ...
        return new Day(offset, cal, cells);
    }
```

**结论**：widget 显示的是**某一天**（不是整周），优先今天；今天没有课就显示未来 7 天内第一个有课的日子，表头日期/星期随之切换。

「今天」的筛选逻辑在数据层（`WidgetTimetableHelperKt.java:284-320`）：`course.getDayOfWeek() == calendarToAppDayOfWeek(dayCal) && courseOccursInWeek(course, teachingWeekForDate)`，再按 `startPeriod` 升序；星期映射 `calendarToAppDayOfWeek` `:163-182`（周一=1 … 周日=7），教学周 `getTeachingWeekForDate` `:54-73`，单双周 `courseOccursInWeek` `:84-161`。

### 2.5 课程如何变成 Cell（时间段/节次/地点/老师的拆解）

数据层先拼出 `detail`（`WidgetTimetableHelperKt.java:308-317`）：

```java
            String buildCourseTimeLabel = buildCourseTimeLabel(course2, effectiveTimeSlotsForWidget);   // :308
            String str = course2.getStartPeriod() + "-" + course2.getEndPeriod() + "节";                // :309
            List listOf = CollectionsKt.listOf((Object[]) new String[]{str, buildCourseTimeLabel, course2.getLocation(), course2.getTeacher()}); // :310
            ... // 过滤 isBlank（:312-315）
            arrayList2.add(new TodayCourseLine(course2.getName(), str, CollectionsKt.joinToString$default(arrayList3, " · ", ...)));  // :317
```

即 `detail` = 非空项以 **`" · "`（空格 + U+00B7 + 空格）** 连接，形如 `3-4节 · 08:00-09:40 · 教一101 · 张三`；`periodLabel` 字段是 `"<startPeriod>-<endPeriod>节"`。

渲染器再把 `detail` 拆开（`J-R:465-489`）：

```java
    private final Cell toCell(TodayCourseLine line) {                     // :465
        String period = StringsKt.trim((CharSequence) line.getPeriodLabel()).toString();
        ... Iterator it = ... split(line.getDetail(), new String[]{" · "}, ...)   // :469
            if (TIME_RE.matches(text)) { time = text; }                   // :477-478
            else if (PERIOD_RE.matches(text)) { period = text; }          // :479-480
            else { rest.add(text); }                                      // :482
        ...
        return new Cell(trim(line.getName()), CollectionsKt.joinToString$default(rest, " ", ...), period, start, end);  // :488
    }
```

两个正则（`J-R:50-51`）：

```java
    private static final Regex TIME_RE = new Regex("^\\d{1,2}:\\d{2}\\s*-\\s*\\d{1,2}:\\d{2}$");  // :50
    private static final Regex PERIOD_RE = new Regex("^\\d+\\s*-\\d+节$");                         // :51
```

- `rest`（时间与节次之外的部分：地点、老师）以**单个空格**连接 → `Cell.where`。
- `start` / `end` = `time` 里 `"-"` 前/后片段（`J-R:486-487`）。

`Cell` 的展示派生属性（`J-R:725-740`）：

```java
        public final String getTimeText() {          // :725
            if (this.start.length() > 0) {
                if (this.end.length() > 0) {
                    return this.start + " - " + this.end;   // :728  ← 注意两侧各一个半角空格
                }
            }
            return this.period;                      // :731
        }

        public final String getStartText() {
            return this.start.length() > 0 ? this.start : this.period;   // :735
        }

        public final String getEndText() {
            return this.end;                         // :739
        }
```

`startMin`/`endMin` 由 `minutes(text)`（`J-R:750-770`）解析，**不含 `:` 或解析失败 → 0**。

### 2.6 哪种尺寸渲染哪些行（dispatch）

`J-R:317-350`（原文照抄，含 jadx 的 `hashCode()` switch）：

```java
        switch (kind.hashCode()) {                                   // :317
            case 51820:
                if (!kind.equals(KIND_2X2)) { return views; }
                renderColumns(views, res, settings, courses, profiles, shown, "cur", "next", dark, mono, colors);  // :322
                return views;
            case 51822:
                if (!kind.equals(KIND_2X4)) { return views; }
                renderRows(context, views, res, settings, courses, profiles, shown, 2, dark, mono, colors);        // :328
                return views;
            case 53744:
                if (!kind.equals(KIND_4X4)) { return views; }
                renderRows(context, views, res, settings, courses, profiles, shown, 5, dark, mono, colors);        // :334
                return views;
            case 1606580:
                if (!kind.equals(KIND_2X4B)) { return views; }
                renderRows(context, views, res, settings, courses, profiles, shown, 2, dark, mono, colors);        // :340
                return views;
            case 1606581:
                if (!kind.equals(KIND_2X4C)) { return views; }
                renderColumns(views, res, settings, courses, profiles, shown, "c0", "c1", dark, mono, colors);     // :346
                return views;
            default:
                return views;
        }
```

| kind | 资源名 | 渲染函数 | 行/栏数 | id 前缀 |
|---|---|---|---|---|
| `2x2` | `dsh_widget_2x2` | `renderColumns` | 2 栏（`dsh_grp_0/1`） | `cur_*` / `next_*` |
| `2x4` | `dsh_widget_2x4` | `renderRows` | 2 行 | `r0_*` / `r1_*` |
| `2x4b` | `dsh_widget_2x4b` | `renderRows` | 2 行 | `r0_*` / `r1_*` |
| `2x4c` | `dsh_widget_2x4c` | `renderColumns` | 2 栏（`dsh_grp_0/1`，中间隔一条竖线） | `c0_*` / `c1_*` |
| `4x4` | `dsh_widget_4x4` | `renderRows` | 5 行（`rowCount >= 5` 即「全天视图」） | `r0_*` … `r4_*` |

（实机 smali 交叉印证：`DshWidgetRenderer.smali:1593` 与 `:1882` 两次 `renderColumns` 调用、`:1665/:1737/:1809` 三次 `renderRows` 调用。）

`renderRows`（`J-R:370-409`）的关键分支：

```java
        boolean isDayView = rowCount >= 5;                       // :374
        if (!isDayView) {
            Pair pair = firstAndSecond(settings, courses, profiles, shown);      // :376
            listOf = pair.getSecond() == null ? CollectionsKt.listOf(pair.getFirst())
                     : CollectionsKt.listOf((Object[]) new Cell[]{pair.getFirst(), pair.getSecond()});  // :377
        } else {
            listOf = shown.getCells();                           // :379  ← 4x4 直接铺当天所有课
        }
```

`4x4` 的「还有 N 节课」页脚（`J-R:397-408`）：

```java
        if (isDayView) {                                          // :397
            int extra = shown.getCells().size() - 5;              // :398
            if (extra > 0) {
                int moreId = res.string("dsh_widget_more");       // :400
                String text = moreId != 0 ? context.getString(moreId, Integer.valueOf(extra)) : "还有 " + extra + " 节课";  // :401
                setText(views, res, "dsh_more", text, colors.getSub());   // :403
                visible(views, res, "dsh_more", true);            // :404
                return;
            }
            visible(views, res, "dsh_more", false);               // :407
        }
```

`renderColumns`（`J-R:353-368`）：

```java
        Pair pair = firstAndSecond(settings, courses, profiles, shown);       // :354
        applySection(views, res, firstPrefix, pair.getFirst(), dark, mono, colors);  // :355
        visible(views, res, "dsh_grp_0", true);                              // :356
        Cell second = pair.getSecond();
        if (second == null) {
            visible(views, res, "dsh_grp_1", false);                         // :359
            return;
        }
        applySection(views, res, secondPrefix, second, dark, mono, colors);  // :362
        visible(views, res, "dsh_grp_1", true);                              // :363
        String head = pair.getSecondHead();
        if (head != null) {
            setText(views, res, secondPrefix + "_head", head, colors.getSub());   // :366
        }
```

### 2.7 「当前 / 接下来」怎么选

`J-R:411-440`：

```java
    private final Pair firstAndSecond(AppSettings settings, List<Course> courses, List<TimetableProfile> profiles, Day shown) {  // :411
        List list = shown.getCells();
        int index = 0;
        if (shown.getOffset() == 0) {                        // :414
            int nowMin = nowMinutes();                       // :415
            int found = -1;
            int size = list.size();
            for (int i = 0; i < size; i++) {
                if (list.get(i).getEndMin() == 0 || list.get(i).getEndMin() >= nowMin) {   // :419
                    found = i;
                    break;
                }
            }
            index = found >= 0 ? found : CollectionsKt.getLastIndex(list);   // :424
        }
        Cell first = list.get(index);                        // :426
        if (index + 1 <= CollectionsKt.getLastIndex(list)) {
            return new Pair(first, list.get(index + 1), null);   // :428  ← 下一节仍显示在同一表头下
        }
        int offset = shown.getOffset() + 1;                  // :430  ← 今天最后一节 → 找下一个有课的日子
        while (offset <= shown.getOffset() + 7) {
            Day next = dayFor(settings, courses, profiles, offset);
            if (!next.getCells().isEmpty()) {
                String head = offset == 1 ? "明天" : WidgetTimetableHelperKt.dayOfWeekLabel(WidgetTimetableHelperKt.calendarToAppDayOfWeek(next.getCal()));  // :434
                return new Pair(first, next.getCells().get(0), head);   // :435
            }
            offset++;
        }
        return new Pair(first, null, null);                  // :439
    }
```

- `nowMinutes()`（`J-R:460-463`）= `hour*60 + minute`。
- 「当前」判定：**第一个 `endMin >= 现在` 的课**；`endMin == 0`（时间解析失败）视为「未结束」。
- 今天全部上完 → 当前课 = 当天最后一节，第二栏/第二行改为「下一个有课日的第 1 节」，表头 `head` 写 `"明天"`（offset==1）或 `dayOfWeekLabel`（`"周三"` 之类）。
- 第二栏的静态表头文案来自字符串资源：`dsh_widget_cur_head` = `当前`、`dsh_widget_next_head` = `接下来`（`V:res/values/dsh_strings.xml`）。

### 2.8 视觉常量：取色、取图、逐字段写入

**取色是「按课程名算哈希」**（`J-R:507-528`）：

```java
    private final String barDrawable(String name, boolean dark, boolean mono) {      // :507
        if (mono) {
            return "dsh_cbar_mono_" + themeSuffix(dark);                             // :509
        }
        return "dsh_cbar_" + themeSuffix(dark) + "_" + paletteIndex(name);           // :511
    }

    private final String blockDrawable(String name, boolean dark, boolean mono) {    // :514
        if (mono) {
            return "dsh_cblock_mono_" + themeSuffix(dark);                           // :516
        }
        return "dsh_cblock_" + themeSuffix(dark) + "_" + paletteIndex(name);         // :518
    }

    private final String themeSuffix(boolean dark) {                                 // :521
        return dark ? "dk" : "lt";                                                   // :522  ← "dk"/"lt" 的真正含义
    }

    private final int paletteIndex(String name) {                                    // :525
        int hash = name.hashCode() & Integer.MAX_VALUE;                              // :526
        return hash % MORANDI.length;                                                // :527
    }
```

> **对 `storage.md:605` 的更正**：`"dk"` / `"lt"` **不是 `RemoteViews` 组件名后缀**，而是 **drawable 资源名的主题后缀**（`themeSuffix`，`J-R:521-523`），出现在 `dsh_cbar_lt_N` / `dsh_cbar_dk_N` / `dsh_cblock_lt_N` / `dsh_cblock_dk_N` / `dsh_cbar_mono_lt|dk` 这类 **drawable 名字**里。与 SharedPreferences 无关（widget 主题只读 `ui_dark_mode`/`ui_optimize_mode`，见 §2.2）。`storage.md:605` 引用的 `DshWidgetRenderer.java:521-523` 行号正确，但「RemoteViews 组件名后缀」的措辞应改为「drawable 名后缀」。

**12 色 Morandi 调色板**（`J-R:49`，与主线课表页 `TimetableGridV2Kt.MorandiPalette` 对齐，`K-R` 头注释写明「必须与课表页一致」）：

```java
    private static final int[] MORANDI = {-5723968, -5462075, -5794395, -12238000, -8815513, -3560836, -2446154, -3023910, -4277586, -7501406, -4734798, -3623768};  // :49
```

| idx | ARGB | idx | ARGB | idx | ARGB |
|---|---|---|---|---|---|
| 0 | `#FFA8A8C0` | 4 | `#FF797C67` | 8 | `#FFBEBAAE` |
| 1 | `#FFACA7C5` | 5 | `#FFC9AA7C` | 9 | `#FF8D89A2` |
| 2 | `#FFA795A5` | 6 | `#FFDAACB6` | 10 | `#FFB7C0B2` |
| 3 | `#FF454350` | 7 | `#FFD1DBDA` | 11 | `#FFC8B4A8` |

**逐字段写入**（`J-R:491-505`）：

```java
    private final void applySection(RemoteViews views, Res res, String prefix, Cell cell, boolean dark, boolean mono, Colors colors) {  // :491
        setImage(views, res, prefix + "_bar", barDrawable(cell.getName(), dark, mono));   // :492
        setText(views, res, prefix + "_name", cell.getName(), colors.getText());          // :493
        setText(views, res, prefix + "_detail", cell.getWhere(), colors.getSub());        // :494
        setText(views, res, prefix + "_time", cell.getTimeText(), colors.getSub());       // :495
    }

    private final void applyRow(RemoteViews views, Res res, int index, Cell cell, boolean dark, boolean mono, Colors colors) {   // :498
        setImage(views, res, "r" + index + "_bar", barDrawable(cell.getName(), dark, mono));      // :499
        setImage(views, res, "r" + index + "_block", blockDrawable(cell.getName(), dark, mono));  // :500
        setText(views, res, "r" + index + "_name", cell.getName(), colors.getText());             // :501
        setText(views, res, "r" + index + "_detail", cell.getWhere(), colors.getSub());           // :502
        setText(views, res, "r" + index + "_t1", cell.getStartText(), colors.getText());          // :503
        setText(views, res, "r" + index + "_t2", cell.getEndText(), colors.getSub());             // :504
    }
```

**只用 5 个 RemoteViews setter**（`J-R:596-620` + 实机 smali 逐条印证）：

```java
    private final void setText(RemoteViews views, Res res, String idName, String text, int color) {  // :596
        int id = res.id(idName);
        if (id == 0) { return; }                                       // :598-600
        views.setTextViewText(id, text);                               // :601
        views.setTextColor(id, color);                                 // :602
    }

    private final void setImage(RemoteViews views, Res res, String idName, String drawableName) {   // :605
        int id = res.id(idName);
        int drawable = res.drawable(drawableName);
        if (id == 0 || drawable == 0) { return; }                      // :608-610
        views.setImageViewResource(id, drawable);                      // :611
    }

    private final void visible(RemoteViews views, Res res, String idName, boolean shown) {          // :614
        int id = res.id(idName);
        if (id == 0) { return; }
        views.setViewVisibility(id, shown ? 0 : 8);                    // :619  (0=VISIBLE, 8=GONE)
    }
```

实机 smali（`DshWidgetRenderer.smali`）：`setOnClickPendingIntent :1168`、`setImageViewResource :3904`、`setTextViewText :3940`、`setTextColor :3943`、`setViewVisibility :4367`；`AppWidgetManager.updateAppWidget :3146`。**没有** `setInt` / `setImageViewBitmap` / `setChronometer` / `addView` / `removeAllViews` / `setProgressBar`（`K-R:22-43` 明确说"never setInt()"）。连 `Res` 也是**按名字查资源**（`J-R:624-655`：`resources.getIdentifier(name, "id"/"drawable"/"string"/"layout", packageName)`），**查不到就静默跳过**——这就是为什么 `J-R:280` 给只有 `2x4c` 才有的 `dsh_24b_divider` 设图也不会崩。

**面板背景/分隔线**（`J-R:279-284`）：

```java
        setImage(views, res, "dsh_panelbg", dark ? "dsh_panel_dk" : "dsh_panel_lt");   // :279
        setImage(views, res, "dsh_24b_divider", dark ? "dsh_div_dk" : "dsh_div_lt");   // :280
        int panelId = res.id("dsh_panel");                                            // :281
        if (panelId != 0 && (pending = launchPendingIntent(context)) != null) {
            views.setOnClickPendingIntent(panelId, pending);                          // :283
        }
```

整个 `buildInner` 被 `build` 包在 try/catch 里（`J-R:259-265`）：**任何 `Throwable` → 返回 null → 不更新**（绝不把异常抛给启动器）。

---

## 3. 尺寸与主题矩阵

### 3.1 kind × 布局资源 × 行/栏 × id 前缀

| kind | provider 类 | `@xml/…` | `@layout/…` | 渲染 | 可见课程数 | id 前缀 |
|---|---|---|---|---|---|---|
| `2x2` | `DshWidget2x2Provider` | `dsh_widget_provider_2x2` | `dsh_widget_2x2` | `renderColumns`（**上下两栏**，非左右） | 2 | `cur_*` / `next_*`（另有 `*_head`） |
| `2x4` | `DshWidget2x4Provider` | `dsh_widget_provider_2x4` | `dsh_widget_2x4` | `renderRows(2)` | 2 | `r0_*` / `r1_*` |
| `2x4b` | `DshWidget2x4bProvider` | `dsh_widget_provider_2x4b` | `dsh_widget_2x4b` | `renderRows(2)` | 2 | `r0_*` / `r1_*` |
| `2x4c` | `DshWidget2x4cProvider` | `dsh_widget_provider_2x4c` | `dsh_widget_2x4c` | `renderColumns`（**左右双栏**） | 2 | `c0_*` / `c1_*`（另有 `*_head`） |
| `4x4` | `DshWidget4x4Provider` | `dsh_widget_provider_4x4` | `dsh_widget_4x4` | `renderRows(5)` | **5** + 「还有 N 节课」 | `r0_*` … `r4_*` |

### 3.2 布局文件清单（`res/layout/`）

| 文件 | 行数 | 结构要点 |
|---|---|---|
| `dsh_widget_2x2.xml` | 54 | `FrameLayout@dsh_panel` → `ImageView@dsh_panelbg`（`@drawable/dsh_panel`，fitXY）；`LinearLayout` `padding=11dp`：表头（`dsh_date` 14sp bold / `dsh_day` 14sp bold accent，`marginStart=5dp`）、`dsh_empty` 12sp sub（gone）、两行 `dsh_grp_0/1`（各 `weight=1`、`marginTop=7dp`），每行 = `3dp` 竖条 `*_bar`（marginEnd 7dp）+ 竖排 `*_head` 10sp sub / `*_name` 13sp bold / `*_detail` 10sp sub / `*_time` 10sp sub |
| `dsh_widget_2x4.xml` | 66 | 表头同 2x2；两行 `dsh_grp_0/1`（`weight=1`、`marginTop=6dp`），**内部无 block 背景**：横排 `paddingStart=7dp paddingEnd=9dp` + `rN_bar` 3dp（marginEnd 7dp）+ 竖排 `rN_name` 13sp bold / `rN_detail` 10sp sub（marginStart 6dp）+ 右对齐竖排 `rN_t1` 12sp bold / `rN_t2` 12sp sub |
| `dsh_widget_2x4b.xml` | 72 | 与 2x4 同构，但每行是 `FrameLayout`，**底层多一张 `rN_block`**（`@drawable/dsh_block_0`，matchParent，fitXY）作圆角卡片底 |
| `dsh_widget_2x4c.xml` | 69 | 表头 + `dsh_empty`；一条水平 `LinearLayout`（`marginTop=9dp`）：`dsh_grp_0`（`weight=1`，竖排：`c0_head` 11sp sub，默认文案 `@string/dsh_widget_cur_head`，其下 `marginTop=6dp` 的横排 `c0_bar` 3dp + `c0_name` 13sp bold / `c0_detail` 10sp sub / `c0_time` 11sp sub）→ `ImageView@dsh_24b_divider`（宽 **1dp**，`marginStart/End=9dp`，`@drawable/dsh_div`）→ `dsh_grp_1`（`c1_*`，默认 `@string/dsh_widget_next_head`） |
| `dsh_widget_4x4.xml` | 147 | 表头 + `dsh_empty`；5 个 `FrameLayout` `dsh_grp_0..4`（各 `weight=1`、`marginTop=6dp`），每个 = `rN_block`（`@drawable/dsh_block_0`）作底 + 横排（`paddingStart=7dp paddingEnd=9dp`）：`rN_bar` 3dp（marginEnd 7dp）、竖排 `rN_name` 13sp bold / `rN_detail` 10sp sub（marginStart 6dp）、右对齐 `rN_t1` 12sp bold / `rN_t2` 12sp sub；末尾 `dsh_more`（11sp sub，`marginTop=5dp`，gone） |

（2x2 的 `dsh_panelbg` 用 `@drawable/dsh_panel`，但**运行时会被替换**成 `dsh_panel_lt`/`dsh_panel_dk`，见 `J-R:279`；同理 `dsh_24b_divider` 在布局里初始是 `@drawable/dsh_div`，运行时换 `dsh_div_lt`/`dsh_div_dk`。）

### 3.3 颜色/形状资源的确切值

`res/values/dsh_colors.xml`（浅色）：

| name | 值 | name | 值 |
|---|---|---|---|
| `dsh_accent` | `#FFDA5848` | `dsh_text` | `#FF1A1A1A` |
| `dsh_text_sub` | `#FF6E6E6E` | `dsh_panel` | `#FFFFFFFF` |
| `dsh_divider` | `#1F000000` | `dsh_bar_0..11` | §2.8 的 12 色 |
| `dsh_tint_0..11` | 同 12 色 + alpha `0x26` | | |

`res/values-night/dsh_colors.xml`（深色，共 32 行）：

| name | 值 | name | 值 |
|---|---|---|---|
| `dsh_accent` | `#FFDA5848`（**与浅色相同**） | `dsh_text` | `#FFF2F2F2` |
| `dsh_text_sub` | `#FFB0B0B0` | `dsh_panel` | `#FF0D0D0D` |
| `dsh_divider` | `#33FFFFFF` | `dsh_tint_0..11` | 同 12 色 + alpha `0x3D` |
| `dsh_bar_0..11` | 见下（深色下**整体提亮**） | | |

深色 12 条色条：`#FFC2C2D2`、`#FFC4C1D6`、`#FFC1B4C0`、`#FF7C7B84`、`#FFA1A394`、`#FFD9C3A3`、`#FFE5C4CB`、`#FFDEE5E5`、`#FFD1CEC6`、`#FFAFACBD`、`#FFCCD2C9`、`#FFD8CAC2`。

drawable（`res/drawable/`，全部是 `<shape android:shape="rectangle">` + `<solid>`，无渐变/无水波纹）：

| 文件 | 内容 |
|---|---|
| `dsh_panel_lt.xml` | `#FFFFFFFF` + `corners radius=18dp` |
| `dsh_panel_dk.xml` | `#FF0D0D0D` + `corners radius=18dp` |
| `dsh_panel.xml`（day） | `#FFFFFFFF` + `r18dp` |
| `drawable-night/dsh_panel.xml` | `#FF0D0D0D` + `r18dp` |
| `dsh_div_lt.xml` / `dsh_div_dk.xml` | `#1F000000` / `#33FFFFFF`，**无圆角** |
| `dsh_div.xml`（day / night） | `#1F000000` / `#33FFFFFF`，`corners radius=18dp` |
| `dsh_bar_0..11.xml` | 纯色 = 对应 `dsh_bar_N`，**无圆角** |
| `dsh_block_0..11.xml` | `#26A8A8C0` 之类（tint 0x26）+ `corners 10dp` |
| `dsh_cbar_lt_0..11.xml` / `dsh_cbar_dk_0..11.xml` | 与 `dsh_bar_N` 同色（`dsh_cbar_dk_0` 仍是 `#FFA8A8C0`，**`dk` 变体与 `lt` 变体同值**，真正不同的是 mono 变体） |
| `dsh_cblock_lt_N` / `dsh_cblock_dk_N` | `#26<色>` / `#3D<色>`，`r10dp` |
| `dsh_cbar_mono_lt.xml` / `dsh_cbar_mono_dk.xml` | `#FF1A1A1A` / `#FFFFFFFF`（无圆角） |
| `dsh_cblock_mono_lt.xml` / `dsh_cblock_mono_dk.xml` | `#FF1A1A1A` / `#FFFFFFFF`，`r10dp` |

文案资源（`res/values/dsh_strings.xml`，12 行）：

| key | 值 |
|---|---|
| `dsh_widget_2x2_label` | 当前课程 · 2×2 |
| `dsh_widget_24_label` | 当前课程 · 2×4 |
| `dsh_widget_24b_label` | 当前与接下来 · 4×2 |
| `dsh_widget_24c_label` | 当前与接下来（双栏）· 4×2 |
| `dsh_widget_44_label` | 全天课程 · 4×4 |
| `dsh_widget_cur_head` | 当前 |
| `dsh_widget_next_head` | 接下来 |
| `dsh_widget_empty` | 今日无课 |
| `dsh_widget_more` | 还有 %1$d 节课 |

id 表（`res/values/dsh_ids.xml`，60 个 id）：`dsh_panel, dsh_panelbg, dsh_date, dsh_day, dsh_empty, dsh_more, dsh_24b_divider, dsh_grp_0..dsh_grp_4`、`r0..r4_{block,bar,name,detail,t1,t2}`、`cur_{head,bar,name,detail,time}`、`next_{head,bar,name,detail,time}`、`c0_{head,bar,name,detail,time}`、`c1_{head,bar,name,detail,time}`。

---

## 4. 刷新机制（三条独立路径）

### 4.1 路径 A：系统 `updatePeriodMillis`（兜底）

`android:updatePeriodMillis="1800000"`（30 分钟，`X:dsh_widget_provider_2x2.xml:5`，5 个文件同值）→ 系统定期发 `APPWIDGET_UPDATE` → 各 provider `onUpdate` → `DshWidgetRenderer.update`。

> Android 官方对 `updatePeriodMillis` 的保证是**「不早于」该周期且不得低于 30 分钟**，实际唤醒时间由系统批量调度决定。

### 4.2 路径 B：自建「边界闹钟」（刷新时刻的精确解）

每次 `update` / `refreshAll` / `arm` 都会调 `scheduleNextBoundary`（`J-R:61,89,94`）：

```java
    private final void scheduleNextBoundary(Context context) {                 // :107
        ...
            if (!hasPlacedWidget(context) || (nextBoundaryMillis = nextBoundaryMillis(context)) == null) {  // :112
                return;
            }
            long trigger = nextBoundaryMillis.longValue();                      // :115
            Object systemService = context.getSystemService(NotificationCompat.CATEGORY_ALARM);  // :116
            AlarmManager manager = systemService instanceof AlarmManager ? (AlarmManager) systemService : null;
            if (manager == null || (pending = tickPendingIntent(context)) == null) { return; }
            try {
                if (Build.VERSION.SDK_INT >= 31 && !manager.canScheduleExactAlarms()) {   // :122
                    exact = false;
                    if (!exact) { manager.setExactAndAllowWhileIdle(0, trigger, pending); return; }  // :125
                    else { manager.setAndAllowWhileIdle(0, trigger, pending); return; }              // :128
                }
                exact = true;
                if (!exact) { }
            } catch (Throwable th) {
                manager.set(0, trigger, pending);                               // :136
            }
        ...
    }
```

> ⚠️ jadx 把这个 if/else 反成了「`exact=false` 却走 `setExactAndAllowWhileIdle`」的颠倒分支（`J-R:104-106` 有 `Code decompiled incorrectly` 警告）。**Kotlin 原文（`K-R:117-134`）为准**：`SDK_INT < 31 || canScheduleExactAlarms()` → `setExactAndAllowWhileIdle(RTC_WAKEUP, …)`，否则 `setAndAllowWhileIdle(RTC_WAKEUP, …)`，异常再退 `set(RTC_WAKEUP, …)`。`0` = `AlarmManager.RTC_WAKEUP`。`03-reminder-and-refresh.md:1506` 曾把这段的触发时刻列为不确定项，本节即为其展开。

闹钟常量与 PendingIntent（`J-R:39,156-164`）：

```java
    private static final int ALARM_REQUEST = 1146308609;                        // :39  (0x44534801)
    private final PendingIntent tickPendingIntent(Context context) {            // :156
            Intent intent = new Intent(ACTION_TICK).setPackage(context.getPackageName());   // :158
            return PendingIntent.getBroadcast(context, ALARM_REQUEST, intent, 201326592);   // :160  (FLAG_UPDATE_CURRENT|FLAG_IMMUTABLE)
    }
```

```java
    public static final String ACTION_TICK = "kebiaocom.example.action.DSH_WIDGET_TICK";   // :38
```

**「下一个边界」的定义**（`J-R:183-257`）：

```java
    private final Long nextBoundaryMillis(Context context) {                    // :183
        Triple data = WidgetTimetableHelperKt.loadWidgetContext(context);       // :184
        ...
        long nowMs = cal.getTimeInMillis();                                     // :189
        Ref.ObjectRef best = new Ref.ObjectRef();
        Calendar midnight = Calendar.getInstance();
        midnight.set(11, 0); midnight.set(12, 0); midnight.set(13, 0); midnight.set(14, 0);  // :192-195
        midnight.add(6, 1);                                                     // :196  ← 明天 00:00
        nextBoundaryMillis$consider(nowMs, best, midnight.getTimeInMillis());  // :197
        Day today = dayFor(settings, courses, profiles, 0);                      // :198
        for (Cell cell : today.getCells()) {                                     // :199
            nextBoundaryMillis$consider(nowMs, best, atMinuteOfDay(cell.getStartMin()));  // :200
            nextBoundaryMillis$consider(nowMs, best, atMinuteOfDay(cell.getEndMin()));    // :201
        }
        int offset = 1;
        while (true) {
            if (offset > 7) { break; }                                          // :205-207
            Day next = dayFor(settings, courses, profiles, offset);              // :208
            if (!next.getCells().isEmpty()) {
                ... nextBoundaryMillis$consider(nowMs, best, atDayMinute(next.getCal(), it.next().getStartMin()));  // :212
            } else {
                offset++;                                                        // :217
            }
        }
        return (Long) best.element;                                              // :220
    }

    private static final void nextBoundaryMillis$consider(long nowMs, Ref.ObjectRef<Long> objectRef, long candidate) {  // :224
        if (candidate > 2000 + nowMs) {                                          // :225  ← 2 秒护栏
            Long current = objectRef.element;
            if (current == null || candidate < current.longValue()) {
                objectRef.element = Long.valueOf(candidate);
            }
        }
    }
```

> ⚠️ `:209-217` 的 `if (!next.getCells().isEmpty()) { … } else { offset++ }` **缺 break**（Kotlin `K-R:198-206` 是 `… if (next.cells.isNotEmpty()) { for (…) consider(…); break } offset++`）——jadx 又丢了一次。**语义以 Kotlin 为准**：找到第一个「有课的未来日」后只取该日各节的**开始时刻**，然后停止扫描。

汇总**触发时刻候选集**（取「> now+2s」中的最小值）：
1. 明天 00:00（`atMinuteOfDay` / `midnight`，`:196-197`）；
2. 今天每一节的**开始**和**结束**分钟（`:199-202`，`atMinuteOfDay` 为 0 表示解析失败 → `:234-236` 直接返回 `0L`，不被采用）；
3. 若今天有课则不再看未来日；否则看未来 1..7 天里**第一个有课日**各节的开始分钟（`:203-219`）。

闹钟取消（`J-R:142-154`）：

```java
    private final void cancelBoundary(Context context) {                        // :142
            ...
            manager.cancel(pending);                                            // :150
            pending.cancel();                                                   // :151
    }
```

`hasPlacedWidget`（`J-R:166-180`）遍历 `PROVIDERS`，任一 provider 有已放置实例即返回 `true`；**没有实例时完全不排闹钟**。

### 4.3 路径 C：广播触发

`DshWidgetRefreshReceiver`（`J-F` 全文 21 行）`onReceive`（`:14-20`）在 `try{}catch(Throwable){}` 里调 `DshWidgetRenderer.INSTANCE.refreshAll(context)`；普通刷新逻辑包括重排闹钟。实机 smali 印证：`DshWidgetRefreshReceiver.smali:45` `onReceive`，`:61` 调 `refreshAll`。

清单里它注册了 6 个 action（`M:71-76`）：

| action | 触发源 | 效果 |
|---|---|---|
| `kebiaocom.example.action.REFRESH_TIMETABLE_WIDGETS` | App 内数据变化（见下） | 全量重绘 + 重排闹钟 |
| `android.intent.action.BOOT_COMPLETED` | 开机 | 同上 |
| `android.intent.action.MY_PACKAGE_REPLACED` | 覆盖安装 | 同上 |
| `android.intent.action.TIME_SET` | 用户改系统时间 | 同上 |
| `android.intent.action.DATE_CHANGED` | 跨日 | 同上 |
| `kebiaocom.example.action.DSH_WIDGET_TICK` | §4.2 的 AlarmManager | 同上 |

**谁发 `REFRESH_TIMETABLE_WIDGETS`**（常量定义 `TimetableWidgetRefresh.java:15`，发送体 `:21-26` 用 `Intent(ACTION_REFRESH).setPackage(pkg)`）：

| 调用点 | 行 |
|---|---|
| `上课早枝道-源码-1.11.5/app/src/main/java/kebiaocom/example/ui/TimetableViewModel.java` | `:114` |
| `.../ui/TimetableViewModel$loadSavedData$1.java` | `:88` |
| `.../sync/TimetableAutoRefreshWorker.java` | `:152`（后台课表同步成功后） |

**同一 action 有两个接收者**：`DshWidgetRefreshReceiver`（刷 5 个 DSH 组件）与 `TimetableWidgetRefreshReceiver`（`exported="false"`，调 `TimetableWidgetRefresh.INSTANCE.updateAll`，刷的是 4 个**未在清单注册**的历史 provider，等于空转）。另有 `WidgetBootReceiver.java:18-25` 只在 `BOOT_COMPLETED` 时调 `updateAll`（同样空转）。

**结论**：DSH 组件的自动刷新 = **30 分钟系统周期**（兜底）+ **按「下一节开始/结束、明天 0 点、下一个有课日的首节开始」精确定时的闹钟**（`RTC_WAKEUP`，有精确闹钟权限时 `setExactAndAllowWhileIdle`）+ **数据变化/开机/改时间/跨日广播**。**没有任何 WorkManager 周期任务参与组件刷新**（`TimetableAutoRefreshWorker` 只负责拉取课表，完成后发一条广播）。

---

## 5. 文本与交互规则

### 5.1 表头

`J-R:300-304`：

```java
        String dateText = new SimpleDateFormat("MM.dd", Locale.getDefault()).format(shown.getCal().getTime());   // :300
        String dayText = WidgetTimetableHelperKt.dayOfWeekLabel(WidgetTimetableHelperKt.calendarToAppDayOfWeek(shown.getCal()));  // :301
        setText(views, res, "dsh_date", dateText, colors.getText());      // :303
        setText(views, res, "dsh_day", dayText, colors.getAccent());      // :304
```

- 日期格式 **`MM.dd`**（例：`05.02`），与 App 内 `getTodayLabel()` 的 `M月d日`（见 `01-timetable-algorithms.md`）**不同**。
- 星期文案来自 `dayOfWeekLabel`（`WidgetTimetableHelperKt.java:184-203`）：`周一` … `周日`。
- **表头是「显示那一天」的日期**（今天无课时会变成未来那天）。

### 5.2 空状态：`今日无课`

`J-R:305-315`：

```java
        if (shown.getCells().isEmpty()) {                       // :305
            for (int i = 0; i < 5; i++) {                       // :306
                visible(views, res, "dsh_grp_" + i, false);     // :307
            }
            int emptyId = res.string("dsh_widget_empty");       // :309
            String emptyText = emptyId != 0 ? context.getString(emptyId) : "今日无课";   // :310
            setText(views, res, "dsh_empty", emptyText, colors.getSub());               // :312
            visible(views, res, "dsh_empty", true);             // :313
            return views;                                       // :314
        }
```

到达这里的前提是**未来 7 天都没有课**（否则 §2.4 的顺延会选出一个有课日）。此时表头仍显示「那个候选日」的日期/星期。

### 5.3 「没有更多课」状态

Android 侧**没有专门的「今日课程已结束」文案**，而是复用 §2.7 的第二栏/第二行：当前课保留在第一位，第二位换成下一个有课日的第 1 节，并把 `*_head` 改成 `明天` 或 `周三`（`J-R:430-436`）。若未来 7 天都没有课，则第二栏被隐藏（`J-R:358-360` / `renderRows` 的 `cell == null` 分支 `:385`）。

### 5.4 每行的格式化结果

以 `Cell` 派生属性（`J-R:725-740`）为准：

| 位置 | 内容 | 例 |
|---|---|---|
| `*_name` / `rN_name` | 课程名（trim 后） | `高等数学` |
| `*_detail` / `rN_detail` | 地点 + 教师，以**单个空格**连接（`J-R:488`） | `教一101 张三` |
| `*_time`（仅 2x2/2x4c） | `HH:mm - HH:mm`（两侧各一空格，`:728`）；无时间则退化为节次 | `08:00 - 09:40` |
| `rN_t1` / `rN_t2`（2x4 系/4x4） | `t1` = 开始时间（无则节次）、`t2` = 结束时间（`:735,:739`） | `08:00` / `09:40` |
| 节次文案 | `"<startPeriod>-<endPeriod>节"`（数据层 `WidgetTimetableHelperKt.java:309`） | `3-4节` |

> 即：**地点与老师在同一行、用一个空格分开；时间在右侧单独一列**（`t1`/`t2` 上下两行），2x2/2x4c 则用一条 `time` 行 `HH:mm - HH:mm`。

### 5.5 每档尺寸显示的课程数

| kind | 显示 | 数量 |
|---|---|---|
| `2x2` | 当前 + 接下来（上下两栏） | 最多 2 |
| `2x4` | 当前 + 接下来（两行） | 最多 2 |
| `2x4b` | 同上（带圆角卡片底） | 最多 2 |
| `2x4c` | 当前 + 接下来（左右双栏 + 分隔线） | 最多 2 |
| `4x4` | **当天所有课**的前 5 节 + 页脚 `还有 N 节课` | 5 + 提示 |

（`J-R:374-379,:397-408`；`MAX_ROWS_4X4 = 5` 定义在 `J-R:41`。）

### 5.6 点击行为：只拉起 App，无 extra

`J-R:587-594`：

```java
    private final PendingIntent launchPendingIntent(Context context) {                     // :587
        Intent intent = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());  // :588
        if (intent == null) { return null; }
        intent.addFlags(335544320);                                                        // :592  (FLAG_ACTIVITY_NEW_TASK|FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(context, 0, intent, 201326592);                   // :593  (0x0C000000)
    }
```

- 整个面板一个点击目标：`views.setOnClickPendingIntent(dsh_panel, pending)`（`J-R:281-283`）；**没有**逐行点击、**没有** `setOnClickFillInIntent`、**没有** `RemoteViewsService`/`collection`。
- **Intent 不带任何 extra / data URI**，就是启动器入口 `MainActivity`。
- `requestCode = 0`，flags `201326592` = `FLAG_UPDATE_CURRENT | FLAG_IMMUTABLE`。

---

## 6. Android 能力 → iOS WidgetKit 对照

> 说明：WidgetKit 的 `TimelineProvider` 只提供**建议**的时间线，刷新时机最终由系统决定；`RemoteViews` 的 XML 布局（`FrameLayout` + `LinearLayout weight` + `shape` drawable + `setViewVisibility`）在 iOS 上**没有任何可直接复用的形式**——iOS 侧必须用 SwiftUI 视图树重新实现视觉，用 `@Environment(\.widgetFamily)` 重新实现尺寸分档，用 `Color`/`containerBackground`/`Text` 重新实现配色与字号。

### 6.1 对照表

| # | Android 能力 | 出处 | iOS / WidgetKit 对应 | 诚实结论 |
|---|---|---|---|---|
| W1 | `AppWidgetProvider` + `<receiver>` + `appwidget-provider` XML | `M:39-68`；`X` 5 个文件 | `@main` 里的 `WidgetBundle` + `Widget` + `StaticConfiguration` + `WidgetConfiguration` 描述 | 概念对应；**声明形式完全不同，XML 不可搬** |
| W2 | 5 个独立 provider = 5 个桌面入口 | `M:39-68` | 一个 `Widget` + `supportedFamilies([.systemSmall,.systemMedium,.systemLarge])`（或 2~3 个 Widget 分别对应） | 近似；iOS 的 family 由**尺寸**决定，Android 由**用户挑哪个 provider** 决定 |
| W3 | `minWidth/minHeight`（dp）+ `targetCellWidth/Height` | `X` 各文件 | `supportedFamilies` + 固定 3 档（小/中/大） | **表格不存在**：iOS 只有三档固定尺寸，无法声明「110dp×180dp」这类自由尺寸；`minResizeWidth/Height` 无从表达 |
| W4 | `resizeMode="horizontal|vertical"` | `dsh_widget_provider_2x2.xml:4` | 系统默认只允许在 family 内微调（大号组件的高度可略变） | 近似；**无法自定义可拉伸方向** |
| W5 | `widgetCategory="home_screen"` | `dsh_widget_provider_2x2.xml:12` | 只支持主屏（+ 锁屏 accessory family） | 对应 |
| W6 | `updatePeriodMillis=1800000`（30 分钟周期） | `dsh_widget_provider_2x2.xml:5` | `TimelineReloadPolicy.after(date)` / `.atEnd`，**预算由系统给**（通常远稀于 30 分钟） | **不等价**：iOS 不保证周期，更不保证 30 分钟 |
| W7 | `AlarmManager.setExactAndAllowWhileIdle` 精确到「下一节开始/结束」 | `J-R:107-140`；`K-R:117-134` | `WidgetCenter.shared.reloadTimelines(ofKind:)`（App 内主动调用）+ 时间线里预排 `TimelineEntry` | **近似但会失真**：可在时间线里预先给出未来多个 entry（如今天各节开始/结束），但系统只在其预算内刷新；**不能保证按点重绘** |
| W8 | `canScheduleExactAlarms()` + 权限引导 | `J-R:122`（`03-reminder-and-refresh.md:1423` 有完整清单） | 无对应概念 | **无对应** |
| W9 | 6 个广播 action（`BOOT_COMPLETED`/`TIME_SET`/`DATE_CHANGED`/`MY_PACKAGE_REPLACED`/数据变更/`DSH_WIDGET_TICK`） | `M:71-76` | `reloadTimelines` 由 App 内数据变更触发；跨日/改时间靠 App 回到前台重算（`UIApplication.significantTimeChangeNotification`） | **无开机广播**；改时间/跨日无法即时通知组件 |
| W10 | `RemoteViews` 布局（`FrameLayout`/`LinearLayout weight`/`TextView textSize`） | `L` 5 个文件 | SwiftUI 视图（`VStack`/`HStack`/`Text`/`Spacer`/`ContainerRelativeShape`） | **无法复制**：必须重写；XML、`@id`、`getIdentifier` 按名查资源、`setTextViewText` 这套机制在 iOS 不存在 |
| W11 | `setViewVisibility(0/8)` 动态隐藏行 | `J-R:619`；`L` 各文件 `visibility="gone"` | `if` 条件渲染 / `ViewThatFits` | 语义等价（写法不同） |
| W12 | 12 色 Morandi 哈希取色（`abs(name.hashCode()) % 12`） | `J-R:49,:525-528` | Swift **String.hashValue 与 Java hashCode 不同**，且 iOS 每次启动会随机化 | ⚠️ **必须原样复刻 Java 的 `String.hashCode()` 算法**，否则颜色与 Android 不一致 |
| W13 | `ui_dark_mode` / `ui_optimize_mode` 由 App 自己控制深浅与单色 | `J-R:530-542` | SwiftUI `@Environment(\.colorScheme)` 只能反映**系统**深浅 | 需在容器视图里按 App 的偏好手绘颜色；widget 自身**不能**自己切换系统外观以外的配色分支（可读共享容器里的偏好） |
| W14 | 面板整块点击 → 启动 App（无 extra） | `J-R:587-594` | `widgetURL(_:)` 一个 URL，App 侧解析 | 对应；但 iOS 只能传 **URL**，无法像 Android 那样带任意 `Intent` extras |
| W15 | 任意动画/自定义手势 | 不存在（`RemoteViews` 限制；本实现也没有） | WidgetKit 视图**不支持**自绘动画、手势、滚动条 | 双方都受限；iOS 侧系统会给默认过渡 |
| W16 | 滚动列表（本实现也没有用） | 无 `ListView`/`RemoteViewsService`（DSH 路径） | 不支持滚动（`List` 在 widget 里是静态的） | **无对应**（Android 侧 `RemoteViewsService` 可以滚动，但本 App 的 DSH 路径没用） |
| W17 | 每 30 分钟 + 精确闹钟 + 广播的三路刷新 | §4 | `TimelineProvider` 单路（App 主动 `reloadTimelines` + 系统预算） | 见 W6/W7：**不存在「精确刷新时刻」** |
| W18 | `previewImage` / `previewLayout` | `X`（只有 `previewLayout`，无 `previewImage`） | Xcode SwiftUI Preview + widget gallery 自动截图 | 近似 |
| W19 | `PENDINGINTENT` / `FLAG_IMMUTABLE` 等 intent 语义 | `J-R:160,:593` | 无对应（URL + `Link`/`widgetURL`） | **无对应**（iOS 无 PendingIntent 概念） |
| W20 | widget 生命周期回调 `onEnabled`/`onDisabled`（挂/撤闹钟） | `J-P:22,:28` | 无对应（无法感知用户加了/删了组件） | **无对应**：iOS 无法在组件被添加/移除时执行代码 |

### 6.2 明确「不可能」清单（写 iOS 时不要承诺）

1. **把 `RemoteViews` 布局 XML 直接搬进 WidgetKit** —— 不可能。iOS 侧只有 SwiftUI。
2. **精确刷新时刻**（例如「正好在 09:40 下课时重绘」）—— 不可能。`TimelineProvider` 的 entry 时间只是建议，实际重绘由系统预算决定；`reloadTimelines` 也不是即时的（系统可节流/丢弃）。
3. **30 分钟固定刷新** —— 不可能保证。iOS 刷新预算因设备状态、App 使用频率、低电量模式而变。
4. **开机/改系统时间/跨日广播** —— 无对应广播；只能靠 App 回到前台自己重算。
5. **任意动画、手势、滚动** —— widget 视图内不支持（`List` 在 widget 中是静态的）。
6. **`getIdentifier` 按名查资源式的「布局与代码解耦」** —— SwiftUI 编译期类型化视图，没有这种运行期名字查表机制。
7. **同时支持 5 种自由尺寸** —— iOS 只有 small/medium/large（+ 锁屏 accessory），最多 3~4 档；`minWidth/minHeight/minResizeWidth/minResizeHeight` 这套尺寸声明不存在。
8. **点击时携带任意 extras** —— iOS 只能通过 `widgetURL` 传一个 URL。
9. **组件被添加/移除时执行代码**（`onEnabled`/`onDisabled`）—— 无对应。
10. **`updatePeriodMillis` 级别的「系统代我周期刷新」** —— 无对应保证。

---

## 7. 逐字证据索引（便于回查）

| 事实 | 出处 |
|---|---|
| 5 个 provider 声明 | `M:39-68` |
| 刷新接收者 6 个 action | `M:69-78` |
| 历史遗留 receiver/service 声明 | `M:28-37,:79-80` |
| `updatePeriodMillis=1800000` | `res/xml/dsh_widget_provider_2x2.xml:5`（5 文件同值） |
| 尺寸属性表 | `res/xml/dsh_widget_provider_{2x2,2x4,2x4b,2x4c,4x4}.xml` |
| provider 转发 | `DshWidget2x2Provider.java:14,18,22,24,28,30` |
| `update` → `render` → `scheduleNextBoundary` | `DshWidgetRenderer.java:56-63` |
| `renderAll` 遍历 PROVIDERS | `DshWidgetRenderer.java:75-90` |
| kind 常量 | `DshWidgetRenderer.java:43-47` |
| PROVIDERS 数组 | `DshWidgetRenderer.java:48` |
| MORANDI 12 色 | `DshWidgetRenderer.java:49` |
| `TIME_RE`/`PERIOD_RE` | `DshWidgetRenderer.java:50-51` |
| 边界闹钟 | `DshWidgetRenderer.java:107-164`（Kotlin `DshWidget.kt:117-134`） |
| `nextBoundaryMillis` | `DshWidgetRenderer.java:183-231`（Kotlin `DshWidget.kt:166-208`） |
| `buildInner`（背景/点击/数据/顺延） | `DshWidgetRenderer.java:267-299` |
| 表头 | `DshWidgetRenderer.java:300-304` |
| 空状态 | `DshWidgetRenderer.java:305-315` |
| kind dispatch | `DshWidgetRenderer.java:317-350` |
| `renderColumns` / `renderRows` | `DshWidgetRenderer.java:353-368` / `:370-409` |
| `firstAndSecond` | `DshWidgetRenderer.java:411-440` |
| `toCell` | `DshWidgetRenderer.java:465-489` |
| `applySection` / `applyRow` | `DshWidgetRenderer.java:491-505` |
| 取色 `barDrawable`/`blockDrawable`/`themeSuffix`/`paletteIndex` | `DshWidgetRenderer.java:507-528` |
| `isDark`/`isOptimized`/`colorsFor` | `DshWidgetRenderer.java:530-549` |
| `layoutName`（jadx 丢失 default） | `DshWidgetRenderer.java:565-585`；Kotlin `DshWidget.kt:500-506`；smali `DshWidgetRenderer.smali:2642,2660,2678,2696,2701-2702` |
| 点击 PendingIntent | `DshWidgetRenderer.java:587-594` |
| setter 实现 | `DshWidgetRenderer.java:596-620`；smali `:1168,3904,3940,3943,4367` |
| `Cell.getTimeText/getStartText/getEndText` | `DshWidgetRenderer.java:725-740` |
| 数据层 `detail` 拼接 | `WidgetTimetableHelperKt.java:308-317` |
| 当日筛选 | `WidgetTimetableHelperKt.java:284-320` |
| `loadWidgetContext` | `WidgetTimetableHelperKt.java:205-209` |
| 数据变更广播发送点 | `TimetableViewModel.java:114`；`TimetableViewModel$loadSavedData$1.java:88`；`TimetableAutoRefreshWorker.java:152` |
| 刷新接收者实现 | `DshWidgetRefreshReceiver.java:14-20` |

---

## 8. 不确定项 / 无法验证

以下内容在本仓库现有证据中**无法确定**，一律不做推测；写 iOS 实现前需要补证或实机验证。

1. **`DshWidgetRenderer.java:299`（`shown = shown2;`）是否真的会覆盖「顺延到今天之后第一个有课日」的结果。**
   jadx 把 Kotlin 单变量合并成两个变量，`:294` 的 `shown = candidate` 与 `:299` 的 `shown = shown2` 在 Java 文本里互相矛盾。**未在实机上验证**（需要一台装了 1.11.5 的设备，制造「今天无课、明天有课」的场景观察表头日期）。
   *倾向判断（非结论）*：Kotlin 原文只有一条赋值语句，`:299` 是反编译产物，实机应表现为顺延生效。
2. **`nextBoundaryMillis` 的 `while (true)` 在没有任何「有课日」时的退出行为。**
   `J-R:203-219` 的 Java 文本里，若 7 天内每天都无课，`offset` 会一直自增到 `> 7` 后 `break`（`:205-207`）——即最多 7 次循环后退出，不是死循环。但同一函数在 jadx 里已被判定 `Code decompiled incorrectly`，**未在实机核对**；Kotlin 原文 `K-R:198-206` 是 `while (offset <= DAYS_TO_SEARCH)`，与此一致。
3. **`themeSuffix` 的 `dk`/`lt` 变体在实机上是否真的与 `dsh_bar_N` 同色。**
   本仓库里 `dsh_cbar_lt_0.xml` 与 `dsh_cbar_dk_0.xml` 都是 `#FFA8A8C0`（`dsh_bar_0` 也是），而 `res/values-night/dsh_colors.xml` 里 `dsh_bar_0` 被改成 `#FFC2C2D2`。**代码路径上 `applyRow` 用的是 `dsh_cbar_*`/`dsh_cblock_*`（不是 `dsh_bar_*`/`dsh_block_*`），所以深色模式下色条到底走哪套颜色，取决于这些 `dsh_cbar_dk_N` 资源实际内容**——本次只抽查了 index 0（`dsh_cbar_lt_0` / `dsh_cbar_dk_0` / `dsh_bar_0`），**未逐个核对 0..11 的全部 44 个色条/色块文件**。
4. **`res/values/dsh_ids.xml` 的完整 60 个 id 逐一列表**：本轮确认了分组与命名规律（`dsh_*` 公共 id、`r0..r4_{block,bar,name,detail,t1,t2}`、`cur_*`/`next_*`/`c0_*`/`c1_*`），**未逐行抄录该文件的 60 行原文**，也未逐行核对 `dsh_widget_2x4.xml`（66 行）与 `dsh_widget_2x4c.xml`（69 行）之外的每个 `android:xxx` 属性是否与其它布局完全一致。
5. **`K-R`（`DshWidget.kt`）文件的真实来源。**
   `K-R:22-43` 的头注释自称是「随 APK 打包进 class4.dex」的实现还原，且 `README.md:52` 把它与 `java/.../DshWidgetRenderer.java` 对列。**它不在 APK 里**（APK 里只有 smali），因此它是**仓库内的人工/工具还原稿**，不是原始工程源码。凡 `K-R` 与 `J-R` 冲突处，本轮一律以 smali 佐证（见 `layoutName`），但**无法保证 `K-R` 每一行都逐字等于原始 Kotlin**。
6. **`targetCellWidth/targetCellHeight` 在 Android 12 以下设备上的实际行为**：这两个属性是 API 31+ 才有，**未验证**在低版本上被忽略后，`2x4b`/`2x4c` 的 4×2 摆放是否仍成立。
7. **`updatePeriodMillis` 与自建闹钟同时存在时的实际唤醒频率**：**未在实机测量**；理论上系统会按 30 分钟发 `APPWIDGET_UPDATE`，与精确闹钟叠加。真实耗电/唤醒次数未知。
8. **`2x2` 的「上下两栏」与函数名 `renderColumns`（columns = 列）语义相反**：布局上 `dsh_grp_0`/`dsh_grp_1` 是**垂直**堆叠（`dsh_widget_2x2.xml` 的父布局是 `orientation="vertical"`），而 `2x4c` 才是真左右双栏。这里只记录事实（布局是上下、函数名叫 columns），**不解释作者意图**。
9. **`TimetableWidgetRefresh.updateAll` 是否真的完全空转**：4 个历史 provider 未在清单注册，`getAppWidgetIds` 应为空；但**未在实机确认**这些 provider 的 `ComponentName` 是否还会被系统唤醒（理论上不会）。
10. **`previewImage` 缺失的影响**：5 个 `appwidget-provider` 只有 `previewLayout`（`X` 各文件），**未验证**在没有 `previewImage` 的启动器上选择器里显示什么（Android 12+ 用 `previewLayout`）。

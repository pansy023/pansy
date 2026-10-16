# 上课早枝道 · iOS 移植工程

本目录是 Android 版「上课早枝道」的 iOS 原生移植工程，**与 Android 工程完全隔离**（Android 侧在 `c:\Users\Pansy\DeepSeek harness\apk_work\` 与 `c:\Users\Pansy\DeepSeek harness\上课早枝道-源码-1.11.5\`，本工程只读取取证，不修改它们）。

> 工程于 2026-10-16 从 `c:\Users\Pansy\DeepSeek harness\上课早枝道-iOS` 迁到当前工作区 `c:\Users\Pansy\TREA\IOS KEBIAO`（原目录因沙箱限制未能删除，是本工程的旧副本；**以此处为准**）。

本文件只回答三件事：**现在真实存在什么**、**还没有什么**、**怎么验证**。

> ⚠️ 全工程**一次都没有编译过**（本机是 Windows，没有 `swift`/`xcodebuild`），测试也**一次都没有执行过**。理由与影响见 §4、§6。

---

## 1. 目录结构

```
IOS KEBIAO/                          （工程根；目录名与工程无关，脚本用相对自身定位）
├── project.yml                      XcodeGen 工程描述（生成的 .xcodeproj 不入库）
├── .gitignore                       挡掉 .xcodeproj / *.ipa / .build / 生成的 Info.plist
├── .github/workflows/ios-build.yml  云端 macOS 构建（真跑单测 + 真编译 + 未签名 IPA，见 §9）
├── KebiaoCore/                      Swift Package（纯逻辑层，不依赖任何 UI 框架）
│   ├── Package.swift                swift-tools-version 5.9，平台 .iOS(.v17) / .macOS(.v14)
│   ├── Sources/KebiaoCore/
│   │   ├── Models/                  Course / AppSettings / PeriodTime / TimetableProfile / UserCredentials
│   │   ├── Logic/                   JavaHash / MorandiPalette / TimeSlotLogic / TimetableLayout / WeekLogic
│   │   ├── Store/                   TimetableRepository（协议 + 内存实现）/ TimetableStore（@MainActor ObservableObject）
│   │   └── Storage/                 UserDefaultsTimetableRepository（真实落盘）/ KeychainCredentialStore（密码）
│   └── Tests/KebiaoCoreTests/       WeekLogicTests / JavaHashTests / MorandiPaletteTests / TimetableLayoutTests
│                                    TimeSlotLogicTests / TimetableStoreTests / PersistenceTests
│                                    StorageRoundTripTests
├── apps/Kebiao/                     SwiftUI App（界面层，依赖本地 package KebiaoCore）
│   ├── KebiaoApp.swift              @main + WindowGroup + 注入 AppEnvironment
│   ├── AppEnvironment.swift         依赖容器：唯一状态源 TimetableStore + editorRequest
│   ├── Support/Theme.swift          颜色/圆角/字号 + CourseCardStyle（卡片外观解算）
│   └── Views/                       RootView（导航 + 统一 sheet）/ TimetableView / TimetableGrid
│                                    CourseCard / WeekSwitcher / CourseDetailOverlay（就地展开）
│                                    CourseEditorView（课程增删改）/ SettingsView（学期周次与显示开关）
├── docs/recon/                      5 份反编译取证文档（见 §3）
├── docs/superseded/                 被取代的并存实现（不进构建，只作参考）
└── tools/                           swift_sanity_check.py（编码/配平体检）
                                     swift_api_check.py（跨文件成员引用 + 顶层类型重名）
                                     storage_key_diff.py（Swift 键字面量 ↔ storage.md 表逐键差分）
                                     java_hash_expectations.py / _expectations.txt / _sanity.txt
```

**尚未创建（不是遗漏，是还没做到）**：`apps/KebiaoWidget/`（WidgetKit 扩展，`project.yml` 里已备好注释掉的 target）、任何 `.xcodeproj`（在 Mac 上 `xcodegen generate` 生成）、`apps/Kebiao/Info.plist`（由 xcodegen 依 `project.yml` 的 `info:` 块生成，**不要手写**）、日志 / 关于 / 免责声明页面（阶段⑤）。

---

## 2. 已对齐的 Android 行为（每条都有 Java/smali 行号证据，不是推测）

| 行为 | 证据 | 对应实现 / 测试 |
| --- | --- | --- |
| 课程在某周是否上课（单双周 + 指定周次） | `TimetableScreenKt.smali:9676-9703`；⚠️ **jadx 的读法会得出相反结论**，以 smali 为准 | `WeekLogic.courseOccursInWeek` / `WeekLogicTests` |
| 单双周判定 | 同一处 smali：`week % 2 == 1` | `WeekLogic.isOddWeek` / `WeekLogicTests` |
| 当前教学周（含学期周数钳制） | `TimetableScreenKt.java` 的 `getCurrentTeachingWeek` | `WeekLogic.currentTeachingWeek` / `WeekLogicTests` |
| 莫兰迪 12 色 + Java `String.hashCode()` 等价算法 | `TimetableGridV2.kt` 的 `paletteColor`；12 个 ARGB 取自 `<clinit>` | `JavaHash` / `MorandiPalette` / 两个测试（期望值由 `tools/java_hash_expectations.py` 生成） |
| 卡片几何：三块面板、相邻合并、钳制、最小高度 | `TimetableGridV2.kt:362-421, 475-569`（`CardGap=5.dp`、`MinCardHeight=12.dp`） | `TimetableLayout` / `TimetableLayoutTests` |
| 文本自适应字号 | `TimetableGridV2.kt` 的 `fitTextSize`（`cap=max(configured,7)`，按高度算后取模） | `TimetableLayout` / `TimetableLayoutTests` |
| 就地展开的落点矩形（×1.8 / ×1.85、最小 190×196、夹回屏内） | `TimetableGridV2.kt:191-207`（逐行展开见 `docs/recon/algorithms.md` §5.2） | `TimetableLayout.expandTarget` / `CourseExpansionGeometry` / `TimetableLayoutTests` |
| 展开动画只插值矩形本身（不是 `scaleEffect`） | `TimetableGridV2.kt:173-260` | `CourseDetailOverlay.FloatingCardAnimator`（`AnimatableModifier`，位置/尺寸/圆角/阴影全部由单一 `progress` 驱动） |
| 作息时间槽生成（默认 10 节 08:10–21:10） | `TimetableScreenKt.java:198-256` 与 `LocalStorage.java:263-278` | `TimeSlotLogic` / `TimeSlotLogicTests` |
| 状态层与落盘时机（增删改后立即 save + 重排提醒 + 刷小组件） | `TimetableViewModel.java`；`insertCourse` 的 id 取 `size()+1`（原版的怪癖，照抄） | `TimetableStore` / `TimetableStoreTests` |
| 「显示非本周课程」关掉时，不属于本周的课**不画** | `TimetableScreenKt.java:4496-4505`（先滤掉）；`:4558`（开着时把开关交给网格用于降透明度） | `TimetableStore.coursesForDisplayedWeek` / `TimetableStoreTests` |
| 课程编辑页的字段、候选值、校验与钳制 | `AddCourseScreenKt.java:362`（标题）、`:659/867/937/1077/1147/1192`（六个下拉）、`:1399-1406`（空名不保存、`coerceAtLeast`）、`:1431`（12 实参位序 + `coerceIn(isOdd,0,2)`）；候选 `:294`/`:303`；初值 `:241/249/258/266/275/286` | `Views/CourseEditorView`（⚠️ 尚未编译） |
| 存储：键名/默认值逐一对照；`showSaturday`/`showSunday` 缺键时回退旧键 `showWeekend` | `docs/recon/storage.md`（42 个键）；`LocalStorage.java:41,77,79` | `Storage/UserDefaultsTimetableRepository` / `PersistenceTests` |
| 密码不再明文落偏好 | Android 明文存在 `LocalStorage.java:41` | `Storage/KeychainCredentialStore`（`kSecClassGenericPassword`） |
| 小组件的尺寸/主题矩阵、边界闹钟刷新、`dk`/`lt` 后缀 | `docs/recon/04-widget.md`（`DshWidgetRenderer.java` + `DshWidget.kt` + 5 个 provider + 60+ 资源） | 阶段⑤ 未实现（取证已完成） |

---

## 3. 反编译取证文档（所有实现的依据）

- `docs/recon/01-timetable-algorithms.md` —— 课表算法总览（927 行）
- `docs/recon/algorithms.md` —— 5 个算法的逐指令核对（513 行）
- `docs/recon/02-jwxt-login-and-parser.md` —— 强智教务登录、Cookie/会话、HTML 解析
- `docs/recon/03-reminder-and-refresh.md` —— 课前提醒与自动刷新；内含 **Android→iOS 能力对照表 A1–A15**（哪些 iOS 做不到、替代方案是什么）
- `docs/recon/storage.md` —— SharedPreferences / org.json 全部键与默认值（42 个键）
- `docs/recon/04-widget.md` —— 小组件（928 行）：5 个 provider 的尺寸矩阵、主题（`ui_dark_mode` / `ui_optimize_mode`，`dk`/`lt` 是 **drawable 名后缀**）、`AlarmManager.RTC_WAKEUP` 边界闹钟 + `updatePeriodMillis=1800000`、§7 的「Android 能力 → iOS 对应/无对应」表、§8 的 9 条未证实项

> 阶段① 的取证到此**五份齐了**。`04-widget.md` 明确写了「`RemoteViews` 的 XML 布局不能照搬」「iOS 桌面小组件无法做到精确刷新时刻、无动画/滚动、无 `onEnabled`/`onDisabled` 等价物」——阶段⑤ 按这张表做事，不假装等价。

---

## 4. 关键设计决定（附理由）

1. **存储用 `UserDefaults` + JSON 字符串，不用 SwiftData。** Android 的契约是「一个 `timetable_prefs` 文件 + 42 个标量键 + `courses_json` 这类 JSON 字符串键」，字段名/键名/默认值必须一致。`UserDefaults` 能逐键 1:1 对齐；SwiftData 是对象图 + 自己的 schema，要对齐键名得再包一层，反而更容易偏离契约（且单位测试需要真容器）。
2. **密码走 Keychain，不落 `UserDefaults`。** 这是对 Android「明文存密码」缺陷的修正，属于同一存储契约下的实现改进；读凭据时 `UserDefaults` 的 `password` 键会被清掉。**未实现**明文的一次性迁移（iOS 全新安装不存在该键；若要迁移，可参考 `docs/superseded/` 里那份变体的 `migrateLegacyPlaintextPasswordIfNeeded()`）。
3. **配色必须自己算 Java `String.hashCode()`**（32 位溢出 + `and 0x7fffffff` 取桶）。Swift 的 `hashValue` 每进程随机加盐，同一门课会换色；`Theme.swift` 里写明了这条禁令。
4. **暂不引入 SwiftSoup。** 阶段④ 才用得上；`docs/recon/02-jwxt-login-and-parser.md` 记录的是 jsoup 选择器，SwiftSoup 与 jsoup API 基本 1:1，倾向届时用 SwiftSoup。现在加依赖会让 `swift test` 依赖网络，且当前没有任何代码使用它。
5. **不用第三方 UI 依赖**，全部原生 SwiftUI；颜色/圆角/间距集中在 `Support/Theme.swift`。
6. **Xcode 工程由 `project.yml`（XcodeGen）生成**，不手写 `.xcodeproj`；`KebiaoCore` 同时是 SwiftPM package，因此算法与存储测试可以脱离 Xcode 用 `swift test` 跑。

---

## 5. 怎么验证

**有 macOS + Xcode 的机器上（唯一能真正验证的路径）：**

```bash
cd KebiaoCore
swift test                       # 8 个测试文件、约 100 个用例，全部从未跑过
cd .. && xcodegen generate       # 生成 Kebiao.xcodeproj，再用 Xcode 打开
```

**只有 Windows（本机现状）：**

```powershell
python tools/swift_sanity_check.py
python tools/swift_api_check.py KebiaoCore apps
python tools/storage_key_diff.py   # 存储键契约：Swift 键字面量 ↔ storage.md 逐键差分
```

最后一次运行结果（43 个 `.swift` 文件；下面的数字每次新增文件都会重跑，以最终一次运行为准）：

- `swift_sanity_check.py` → **exit 0**：43 个文件 `(){}[]` 配平、UTF-8 无 BOM、纯 LF、无 U+FFFD、无制表符。
- `swift_api_check.py` → **exit 0**：核对核心成员引用 1101 处、未声明 0 处、顶层类型重名 0 处、协议一致性 10 处（缺要求 0 处）。
- `storage_key_diff.py` → **exit 0**：Swift 用到的 36 个字面量键都能在 `storage.md` 里找到。

**这些工具证明不了什么**：它们只查成员是否存在、顶层类型是否重名。**不查类型、不查参数、不查协议实现是否完整**，也不查「裸标识符用错」（实测就漏掉过一个真实编译错误，见 §6）。

---

## 6. 已知风险 —— 第一次在 Mac 上编译时必须处理

1. **一切都没有编译验证过。** 上面两个静态工具给出 exit 0 ≠ 能编译。已经出现过两次实例：`Views/CourseDetailOverlay.swift` 声明了 `sourceRect`/`targetRect`，`body` 却引用不存在的 `geometry`（预览里还按 `geometry:` 传参），是人工逐行审出来的，已修；`Storage/UserDefaultsTimetableRepository.swift` 读 `autoCheckUpdate` 时回落到 `AppSettings.default`（**true**），而原版读取字面量是 `false`（`storage.md` §9 U3），代码注释还自称取 false——实现与注释、与证据文档三方不一致，是靠「照证据文档写断言」的审计用例发现的，已按 false 修正。macOS 上第一件事就是 `swift build` 把真错误找全。
2. **`PersistenceTests` 的 actor 隔离**：它是 `@MainActor final class` 又 override 了 `setUp()`/`tearDown()`（对比 `TimetableStoreTests` 是 `@MainActor` 但两个都没 override）。若报 isolation 错误，最小修复是给这两个 override 加 `nonisolated`，或把 fixture 建在每个用例内部。
3. **`Info.plist` 不要手写**：`project.yml` 同时设了 `GENERATE_INFOPLIST_FILE: NO` 和 `info:` 块，plist 由 xcodegen 生成。
4. **`project.yml` 从未被 xcodegen 解析过**（本机没有 xcodegen），字段名是否都合法要到 Mac 上才知道。
5. **并发写冲突已经发生过一次**：本工程曾被多个代理并发写入，出现过「同一个 `UserDefaultsTimetableRepository` 两份实现」，那会让模块直接编译失败。多余的一份已移到 `docs/superseded/`（`.swift.txt`，不参与构建）。改文件前先看一眼有没有别人刚动过。同理，那份变体的配套文件 `Store/SecretStore.swift` 已一并移入 `docs/superseded/`（当时它已无任何引用可查）——**现在密码只有一条实现路径：`Storage/KeychainCredentialStore`**。
6. **未加任何第三方依赖**，因此 `swift test` 不需要网络。
7. **本轮新增的 SwiftUI 代码风险最高**：`Views/CourseEditorView.swift`、`Views/SettingsView.swift`、`RootView` 的 `.sheet(item:)`、以及 `Theme.swift` 里被删掉的 `MoreAction` 都是纯静态检查过、**没有任何编译器看过**。尤其这几处只能到 Mac 上才知道对错：`@EnvironmentObject` 的 `$environment.editorRequest` 投影、`WritableKeyPath` 泛型推断（`settingsBinding(\.showSaturday)`）、`LabeledContent` 嵌在 `Stepper` 标签里、以及 `AppSettings` 的 27 个字段是否都可由 app target 写入。**这一批是 `swift build` 之后第一批要盯的**。

---

## 7. 进度（对照 m03200 的七阶段）

| 阶段 | 状态 |
| --- | --- |
| ① 项目审查 | ✅ 完成（5 份取证文档） |
| ② 架构设计 | 🟡 独立工程 + package/app/widget 三层已定，`project.yml` 已写；widget target 待阶段⑤ |
| ③ 核心功能（课表展示/课程计算/编辑/持久化） | 🟡 课表展示（网格/侧栏/周切换/就地展开）、课程计算、持久化、**课程新增/编辑/删除**（`CourseEditorView`）、**学期与周次/显示开关设置**（`SettingsView`）都已落盘；差「作息时间表管理」与背景图/字号等剩余设置项 |
| ④ 教务接入（P2） | ⬜ 未开始（取证已完成） |
| ⑤ 提醒 / 小组件 / 其它页面 | ⬜ 未开始（提醒与小组件的取证都已完成，实现未动） |
| ⑥ 编译测试 | 🟡 已备好云端流水线（`.github/workflows/ios-build.yml`：真跑单测 + 真编译 + 未签名 IPA，见 §9）；**尚未执行过**，缺一个 GitHub 仓库与一次 push |
| ⑦ 签名安装 | 🟡 本机做不出 IPA；路径已定：云端产出未签名包 → Windows 侧 SideStore/AltStore + 免费 Apple ID 重签后装到 iPhone（免费账号 7 天到期需重签） |

---

## 8. 下一步

1. 到 macOS 上跑 `swift build` / `swift test`，按 §6 逐条修真实错误（这是「编译通过 / 测试通过」的唯一凭证）。
2. 补 P1 剩余项：作息时间表（`TimetableProfile`）管理界面、背景图与卡片高度/字号、「显示主界面滑动条」（原版有、iOS 侧 `WeekSwitcher` 尚无此开关）。
3. P2 教务：`URLSession` + HTML 解析，严格按 `02-jwxt-login-and-parser.md`。
4. P3 提醒：`UNUserNotificationCenter`，按 `03-reminder-and-refresh.md` 的 A 表处理 iOS 无法等价的能力。
5. P4 小组件：先补一份 WidgetKit 取证/设计文档，再动手（`RemoteViews` 不能照搬）。
6. P5 其它页面：日志 / 关于 / 免责声明 / 分享导出。

---

## 9. 没有 Mac 时怎么拿到能装进 iPhone 的包（云端 macOS 构建）

**硬约束**：把 Swift 源码编成 iOS 可执行文件**必须有 macOS + Xcode**——iOS SDK / SwiftUI / UIKit 只随 Xcode 分发，Windows 上没有受支持的替代工具链。所以「不需要在 Mac 上运行」成立（App 跑在 iPhone 上，与 Mac 无关），但要**产出**这个包，必须有某台 Mac 参与。本机没有 Mac，所以把这一步外包给 GitHub 的 macOS runner。

**流水线**：`.github/workflows/ios-build.yml`（两个互不依赖的 job）

| job | 干什么 | 为什么重要 |
| --- | --- | --- |
| `core-tests` | `cd KebiaoCore && swift test --parallel` | **全工程唯一能真跑的验证**：周次判断 / 单双周 / Java `String.hashCode()` 配色 / 卡片几何 / 时间槽 / 存储往返。在这之前 0 个用例被执行过 |
| `app-build` | `brew install xcodegen` → `xcodegen generate` → `xcodebuild`（`CODE_SIGNING_ALLOWED=NO`）→ 校验 `.app` 存在 → 打包 `Kebiao-unsigned.ipa` → 上传工件 | 第一次让编译器真正看过 `apps/` 与 `KebiaoCore/`。产物是**未签名**包 |

**你要做的四步：**

1. 本机装 git 并在 GitHub 建一个仓库：`winget install Git.Git`，然后 `git init` / `commit` / 添加 remote / `push`。**别把 `KebiaoCore/.build/`、`*.xcodeproj`、`*.ipa` 提上去**——`.gitignore` 已经挡好了。
2. push 后到仓库的 **Actions** 页看结果。`core-tests` 会打印真实用例结果；`app-build` 失败时会停在第一个真实编译错误上（这是好事——那份错误清单就是阶段⑥ 的待办）。
3. 从工件里下载 `Kebiao-unsigned.ipa`。
4. 在 Windows 侧用 **SideStore**（iOS 17+，需配 StosVPN / 本地设备对）或 **AltStore + AltServer + iTunes**，配你自己的 **免费 Apple ID** 重新签名后装到 iPhone。免费账号签出来的证书 **7 天失效**，到期要在同一工具里重签一次；想要不重签就得付费开发者账号（$99/年）。

**必须说清的边界**：这条链路我**没有验证过**（本机连 git 都没有），也**没有产出过任何 IPA**。未签名包不能直接双击安装；免费账号侧载会改 bundle id 的签名者但不会改 `com.kebiaocom.example.kebiao` 本身。

**已知最可能让第一次 CI 编译失败的点**（按 `swift build` 的报错顺序修即可）：

1. 界面层的 SwiftUI 代码**从未被编译器看过**（§6 第 7 条）：`$environment.editorRequest` 投影、`WritableKeyPath` 泛型推断、`LabeledContent` 嵌在 `Stepper` 里。
2. `PersistenceTests` 覆写了 `setUp()`/`tearDown()` 而类型是 `@MainActor`（§6 第 2 条），可能报 actor 隔离。
3. `KebiaoApp` 在非隔离的属性初始化式里调用 `@MainActor` 的 `AppEnvironment.live()`——Swift 5 语言模式下只是警告，但会出现在日志里。
4. `project.yml` 从未被 xcodegen 解析过（§6 第 4 条）；`info:` 块生成的 `apps/Kebiao/Info.plist` 也从未真的生成过。
5. 没有任何 `Assets.xcassets`，安装后是**默认图标**（不影响装和跑，属于外观缺口）。

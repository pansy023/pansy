# 02 — 强智教务（Qiangzhi JWXT）登录 + 课表抓取：逆向规格

> 目的：把 Android 课表应用「上课早枝道」反编译 Java 里与强智教务系统交互的**完整网络流程与解析规则**逐字提取出来，供写成等价的 iOS（URLSession + HTML 解析）实现。
> 只做提取与分析。本文档为新建文件，未修改任何现有文件。
>
> **来源（唯一权威）**：`上课早枝道-源码-1.11.5\app\src\main\java\kebiaocom\example\` 下的 jadx 产物。
> 行号均为该目录下文件的实际行号。
>
> **可信度约定**：所有 URL、字段名、正则、中文文案均照抄反编译代码。凡字节码/反编译产物推不出来的，一律标 `// 不确定：…`，不猜。

---

## 0. 来源文件清单

| 文件 | 行数 | 职责 |
|---|---|---|
| `data\QiangzhiJwxtParser.java` | 1380 | 解析器主体：URL 构造、HTTPS 提升、加密、两种 HTML 解析风格、字段抽取、去重合并 |
| `data\QiangzhiJwxtParser$login$2.java` | 358 | 登录协程（真正的网络流程） |
| `data\QiangzhiJwxtParser$fetchTimetable$2.java` | 147 | 抓课表协程 |
| `sync\JwxtTimetableSync.java` | 110 | 编排：new parser → login → fetchTimetable → 重排 id |
| `data\UserCredentials.java` | 110 | 凭据模型 + `DEFAULT_JWXT_URL` |
| `data\TimetableProfile.java` | 105 | 作息时间表（课次→时间由本地配置决定，非抓取） |
| `data\LocalStorage.java` | 296 | SharedPreferences 持久化（key / JSON 字段名） |
| `sync\JwxtTimetableSync$fetchFromJwxt$1.java` | 30 | 上面协程的状态机续体 |
| `data\Course.java` | — | 课程模型（字段顺序见 §9） |
| `sync\TimetableAutoRefreshWorker.java` | 190 | 后台自动同步入口 |

---

## 1. 网络库与请求方式

**结论：全程只用 jsoup（`org.jsoup.Jsoup.connect`）。没有 OkHttp，没有 HttpURLConnection。**

已确认的 `Jsoup.connect` 调用点（共 9 处）：

- `data\QiangzhiJwxtParser.java:120`
- `data\QiangzhiJwxtParser$login$2.java:145, 158, 199, 232, 248, 286, 322`
- `data\QiangzhiJwxtParser$fetchTimetable$2.java:96`

### 1.1 超时

**没有任何一处调用 `.timeout(...)`。** 全部依赖 jsoup 默认值（连接 30s / 读取 30s）。

```java
// QiangzhiJwxtParser$login$2.java:145 —— 典型的链式调用，没有 .timeout()
cookies = Jsoup.connect(str4).method(Connection.Method.GET).ignoreHttpErrors(true).execute().cookies();
```

> Swift/URLSession 等价实现要点：用 `URLSessionConfiguration.default`，显式设 `timeoutIntervalForRequest = 30`、`timeoutIntervalForResource = 30` 以复刻 jsoup 默认值。

### 1.2 User-Agent

只有两处设置 UA，且为**硬编码的 Windows Chrome UA 前缀**：

```java
// QiangzhiJwxtParser$login$2.java:251-257（成功收尾的 Cookie 采集跳）
//   以及 QiangzhiJwxtParser$fetchTimetable$2.java:96-98（抓课表）
.header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
```

注意：**首页跳（第 145 行）与 `/Logon.do?...flag=sess` 跳（第 158 行）和登录 POST（第 199 行）都没有设 UA**，只有后两跳设了。

> Swift 等价：给这两类请求设同样的 `User-Agent` 头；其余可留空或统一用系统默认（差异可能影响服务端行为，保守做法是**全部请求都设这个 UA**）。
> `// 不确定：为何只在两处设置 UA —— 反编译可见事实如此，原始 Kotlin 是否在别处（如拦截器）补设无法从字节码判断。`

### 1.3 Referer

```java
// login$2.java:199 —— 登录 POST
.header("Referer", str4)                       // str4 = secureBaseUrl + "/"

// login$2.java:120 —— 选课入口模拟跳（在 QiangzhiJwxtParser.java:120）
.header("Referer", str2)                       // str2 = secureBaseUrl + "/jsxsd/framework/xsrkxz.htmlx"

// login$2.java:247-257 —— 成功收尾
String str30 = getSecureBaseUrl() + "/jsxsd/framework/xsMainV.htmlx";
Connection cookies3 = Jsoup.connect(str30).cookies(mutableMap2);
str8 = this.this$0.timetableReferer;
if (str8 != null) { str30 = str8; }            // 有选课入口页时 Referer 改用它
... .header("Referer", str30) ...

// fetchTimetable$2.java:80-84 —— 抓课表
str2 = this.this$0.timetableReferer;
if (str2 == null) { str2 = getSecureBaseUrl() + "/jsxsd/framework/xsMainV.htmlx"; }
```

> Swift 等价：每次请求显式设 `Referer`，用一个 `var timetableReferer: URL?` 保存选课入口页 URL。

### 1.4 重定向策略

用 `.ignoreHttpErrors(true)`（**每一处调用都有**）让 4xx/5xx 不抛异常；重定向由 jsoup 内部自动跟随，再用 `execute.url()` 拿**最终** URL：

```java
// login$2.java:218
String url = execute.url().toString();
```

```java
// fetchTimetable$2.java:104 —— 显式判断未自动跟随的 302
if (execute.statusCode() == 302 && (header = execute.header("location")) != null
        && StringsKt.contains$default(header, "Login", false, 2, null)) { ... }
```

> Swift 等价：`URLSession` 默认自动跟随重定向；用 `task.currentRequest?.url` / `response.url` 取最终 URL。注意 `URLSession` 会把 302 跟随掉，`statusCode == 302` 那条分支在 iOS 上基本不会触发——**改用「最终 URL 路径或 location 含 `Login`」判断会话过期**。
> `// 不确定：jsoup 是否把 POST 的 302 也跟随（jsoup 默认对所有 Method 都跟随）。反编译看不到实现，iOS 端建议用自己的过期判断（见 §4.3）。`

### 1.5 编码（GBK / UTF-8）

**代码里没有任何 `charset(...)`、没有 `new String(bytes, "GBK")`、没有 `Content-Type; charset=` 设置。** 全部当作字符串处理：
`execute.body()` → `String`；`execute.parse()` → jsoup `Document`；`execute.cookies()`。

```java
// login$2.java:210-217
try {
    body2 = execute.parse().text();
} catch (Exception unused) {
    body2 = execute.body();
    if (body2 == null) { body2 = ""; }
}
```

> 关于字符集，唯一可能的线索在 jadx 资源里（未在本次范围核验）：
> `// 不确定：jsoup 的响应字符集由 Content-Type 的 charset 决定，否则用 jsoup 默认（UTF-8）。若目标强智站点是 GBK 且只声明在 <meta charset>，jsoup 能从 meta 探测；URLSession 不会 —— iOS 端建议：先取 Content-Type charset，再回落到 HTML meta，最后 GBK 尝试解码。反编译代码本身不做这件事。`

### 1.6 HTTP→HTTPS 强制提升

所有 URL 都经 `getSecureBaseUrl()`，它把 `http://` 前缀替换为 `https://`：

```java
// QiangzhiJwxtParser.java:76-82（Lazy"委托内部）
str = QiangzhiJwxtParser.this.baseUrl;
if (StringsKt.startsWith$default(str, "http://", false, 2, (Object) null)) {
    str4 = QiangzhiJwxtParser.this.baseUrl;
    str2 = StringsKt.replace$default(str4, "http://", "https://", false, 4, (Object) null);
} else {
    str2 = QiangzhiJwxtParser.this.baseUrl;
}
// :86
LogManager.d$default(logManager2, str3, "使用HTTPS URL: " + str2, null, 4, null);
```

> Swift 等价：`baseURL` 字符串做 `replacingOccurrences(of: "http://", with: "https://")`，再 URL 化。

---

## 2. 登录流程

`login$2` 是 `SuspendLambda`，字段 `$username` / `$password` / `this$0`，入口 `invokeSuspend`（`login$2.java:58`）。
整体是 **4 跳（正常）或 5 跳（触发验证跳）**。

### 2.1 跳 1：访问首页取初始 Cookie

```java
// login$2.java:125,134,136,143
LogManager...("开始登录，用户名: " + this.$username);
...("登录URL: " + secureBaseUrl6);
this.this$0.timetableReferer = null;
...("步骤1: 访问首页: " + str4);

// login$2.java:138-139
secureBaseUrl = getSecureBaseUrl();
str4 = secureBaseUrl + "/";

// login$2.java:145  —— 逐字
cookies = Jsoup.connect(str4).method(Connection.Method.GET).ignoreHttpErrors(true).execute().cookies();

// login$2.java:149
LogManager...("初始Cookie: " + cookies);
```

- **GET** `{base}/`
- **无** User-Agent、**无** Referer、**无** body
- `// 不确定：首页返回的 <title> 或其他标记未做校验。`

### 2.2 跳 2：POST 取加密参数（scode / sxh）

```java
// login$2.java:152  —— 逐字 URL
String str26 = secureBaseUrl2 + "/Logon.do?method=logon&flag=sess";

// login$2.java:156
LogManager...("获取加密参数: " + str26);

// login$2.java:158  —— 逐字请求，注意是 POST 但没有任何表单数据
body = Jsoup.connect(str26).cookies(cookies).method(Connection.Method.POST)
        .ignoreHttpErrors(true).execute().body();

// login$2.java:166
LogManager...("加密参数响应: " + body);
```

**响应分割**（`login$2.java:172-184`）：

```java
if (!(body.equals("no")) && body.contains("#")) {
    split$default = StringsKt.split$default(body, new String[]{"#"}, ...);
    str27 = split[0];   // scode（s-code 原文）
    str28 = split[1];   // sxh（数字序列，作为切片长度表）
    ...("scode: " + take(str27, 50) + "...");
    ...("sxh: " + str28);
}
```

**失败分支**（`login$2.java:336-344`）：若响应 `equals("no")` 或不含 `#` →

```java
LogManager...("获取加密参数失败");
return false;   // 不尝试登录 POST
```

> Swift 等价：
> ```swift
> let (data, _) = try await session.data(for: req)   // POST, cookies 带上
> let body = String(data: data, encoding: .utf8) ?? ""
> guard body != "no", let hash = body.firstIndex(of: "#") else { return false }
> let scode = String(body[body.startIndex..<hash])
> let sxh   = String(body[body.index(after: hash)...])
> ```

### 2.3 跳 3：登录 POST

**密码编码**（`login$2.java:186`）：

```java
encryptCode = this.this$0.encryptCode(this.$username + "%%%" + this.$password, str27, str28);
//                                 ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ 注意 "%%%" 是固定的三段分隔符
```

```java
// login$2.java:190
LogManager...("加密后的encoded: " + encryptCode);

// login$2.java:193  —— 逐字 URL
String str29 = secureBaseUrl3 + "/Logon.do?method=logon";

// login$2.java:197
LogManager...("POST登录: " + str29);

// login$2.java:199  —— 逐字，完整表单
Connection.Response execute = Jsoup.connect(str29)
        .method(Connection.Method.POST)
        .cookies(cookies)
        .header("Referer", str4)                                              // str4 = {base}/
        .header(HttpConnection.CONTENT_TYPE, HttpConnection.FORM_URL_ENCODED) // application/x-www-form-urlencoded
        .data("userAccount", this.$username)
        .data("userPassword", "")                                             // 逐字：空字符串
        .data("encoded", encryptCode)
        .ignoreHttpErrors(true).execute();
```

**完整表单字段（只有 3 个）**

| 字段 | 值 | 取值来源 |
|---|---|---|
| `userAccount` | 用户名 | `login(username, password)` 的 `$username` |
| `userPassword` | **空字符串 `""`** | 硬编码；真实密码只在 `encoded` 里 |
| `encoded` | `encryptCode` 结果 | `encryptCode(username + "%%%" + password, scode, sxh)` |

**没有验证码字段**：全代码库无 `RANDOMCODE`、无 `verifycode.servlet`、无 checkcode（grep 全文件零命中）。

### 2.4 加密算法（逐字，非 MD5 / 非 DES）

`QiangzhiJwxtParser.java:127-162`，方法签名：

```java
public final String encryptCode(String code, String scodeOrig, String sxh)
```

完整逻辑（照抄结构，去编译器噪声）：

```java
// QiangzhiJwxtParser.java:127-162
public final String encryptCode(String code, String scodeOrig, String sxh) {
    // i 从 0 起；str2 累加结果
    while (i < 20) {
        int i2 = i + 1;
        String substring  = sxh.substring(i, i2);                 // sxh 第 i 个字符（单字符）
        Integer intOrNull = StringsKt.toIntOrNull(substring);     // 解析成个位数字
        int intValue = intOrNull != null ? intOrNull.intValue() : 0;   // 非数字 → 0
        String substring2 = code.substring(i, i2);                // code 第 i 个字符
        String str;
        if (intValue <= scodeOrig.length()) {
            str = scodeOrig.substring(0, intValue);               // 取 scode 前 intValue 个字符
        } else {
            str = scodeOrig;                                      // 越界 → 全取
        }
        str2 = str2 + substring2 + str;                           // 交错拼接
        if (intValue <= scodeOrig.length()) {
            scodeOrig = scodeOrig.substring(intValue);            // scode 消费掉前 intValue 个
        } else {
            scodeOrig = "";
        }
        i = i2;
    }
    // :158 —— 第 20 位之后的 code 剩余部分直接追加
    return str2 + code.substring(i);
}
```

参数语义：
- `code` = `username + "%%%" + password`
- `scodeOrig` = `/Logon.do?method=logon&flag=sess` 响应按 `#` 分割的 **[0]** 段
- `sxh` = 同一响应按 `#` 分割的 **[1]** 段

> Swift 等价实现（逐字符，等价于上面的循环）：
> ```swift
> func encryptCode(_ code: String, _ scodeOrig: String, _ sxh: String) -> String {
>     let c = Array(code), s = Array(scodeOrig), x = Array(sxh)
>     var scode = s
>     var out = ""
>     var i = 0
>     while i < 20 {
>         let d = i < x.count ? (Int(String(x[i])) ?? 0) : 0   // 越界/非数字 → 0
>         let codeCh = i < c.count ? String(c[i]) : ""         // 越界保护（Java 会崩）
>         let n = min(d, scode.count)
>         out += codeCh + String(scode[0..<n])
>         scode.removeFirst(n)
>         i += 1
>     }
>     out += i < c.count ? String(c[i...]) : ""
>     return out
> }
> ```
> `// 不确定：` (a) 当数字 > scode 剩余长度时的行为已按反编译照抄（取全部、剩余置空）；(b) **若 `code` 短于 20 字符，Java 版会在 `code.substring(i,i2)` 抛 `StringIndexOutOfBoundsException`**（jadx 未加保护），iOS 端应加越界保护；(c) 该算法与强智官方 `encrypt` 实现是否逐字节一致无法从字节码证明，但**这是本应用实际发送的内容**，服务端接受它。

### 2.5 登录结果判定（含全部中文文案）

```java
// login$2.java:200-219
...("登录响应状态: " + execute.statusCode());                 // :203
Map<String,String> mutableMap = MapsKt.toMutableMap(cookies); // :206
mutableMap.putAll(execute.cookies());                         // :209 —— Cookie 逐跳累积
// :210-217
try { body2 = execute.parse().text(); }
catch (Exception unused) { body2 = execute.body(); if (body2 == null) body2 = ""; }
String url = execute.url().toString();                        // :218 —— 最终重定向 URL
...("登录响应内容: " + take(body2, 500));                      // :224
```

判定链（按代码里的顺序）：

| 优先级 | 条件（逐字） | 结果 | 日志文案 | 行号 |
|---|---|---|---|---|
| 1 | `body2` 含 `"欢迎"` **或** 含 `"主页"` | 成功 | `"登录成功！"` | `:227` / `:315` |
| 2 | `body2` 含 `"用户名或密码错误"` **或** 含 `"密码错误"` | 失败，`return false` | `"登录失败: 用户名或密码错误"` | `:228` / `:304` |
| 3 | `url` 忽略大小写含 `"xsrkxz"` **或** `body2` 含 `"入口选择"` **或** (`body2` 含 `"进入选课"` **且** 含 `"进入首页"`) | 当作成功（选课入口页） | `"登录成功（选课入口页）"` | `:229` / `:279` |
| 4 | 兜底：GET 主页面取 `<title>` | 见下 | `"主页面标题: " + str5` | `:230-238` |

第 4 条的完整代码（逐字）：

```java
// login$2.java:231-232
str5 = Jsoup.connect(secureBaseUrl5 + "/jsxsd/framework/xsMainV.htmlx")
        .cookies(mutableMap).method(Connection.Method.GET)
        .ignoreHttpErrors(true).execute().parse().select("title").text();

// login$2.java:240-242  —— 标题恰好是 "登录"，或包含 "Login" → 失败
if (!Intrinsics.areEqual(str5, "登录")) {
    if (!StringsKt.contains$default(str5, "Login", ...)) {
        ... 成功路径 ...
    }
}
// :271
LogManager...("登录失败");
return false;
```

> `// 不确定：login$2.java:229 的三个子条件里，`进入选课` 与 `进入首页` 在反编译里是**与**关系。原始 Kotlin 里极可能是 `||`，jadx 将 `！contains(A) && !contains(B)` 形式的否定合取反推成 `contains(A) && contains(B)` 时容易出错。同时 `passCourseSelectionGatewayIfNeeded`（`QiangzhiJwxtParser.java:110`）里同样两个字符串是**或**关系，两处逻辑不一致，进一步说明此处可疑。iOS 端建议用**或**（更宽松，且与 :110 一致）。`

**成功路径公共尾部**（在 `:243-265`、`:281-299`、`:317-335` 三处各重复一遍，逐字如下）：

```java
// login$2.java:245（成功收尾里）
this.this$0.passCourseSelectionGatewayIfNeeded(url, body2, mutableMap2);

// login$2.java:247-257
String str30 = getSecureBaseUrl() + "/jsxsd/framework/xsMainV.htmlx";
Connection cookies3 = Jsoup.connect(str30).cookies(mutableMap2);
str8 = this.this$0.timetableReferer;
if (str8 != null) { str30 = str8; }
Map<String,String> cookies4 = cookies3
        .header("Referer", str30)
        .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
        .method(Connection.Method.GET).ignoreHttpErrors(true).execute().cookies();
mutableMap2.putAll(cookies4);
this.this$0.cookies = mutableMap2;      // 会话 Cookie 落到解析器实例上

// login$2.java:262
LogManager...("登录成功，Cookie数量: " + map.size());
return true;
```

**异常分支**（`login$2.java:345-353`）：

```java
LogManager.e(str3, "登录异常", e);   // :350  TAG = "登录异常"
return false;
```

### 2.6 选课入口网关（`xsrkxz`）

```java
// QiangzhiJwxtParser.java:107-124
public final void passCourseSelectionGatewayIfNeeded(String responseUrl, String responseBody, Map<String,String> cookieMap) {
    // :108-110 触发条件
    if (!contains(responseUrl, "xsrkxz", ignoreCase=true)) {
        if (!contains(responseBody, "xsrkxz", true) && !contains(responseBody, "入口选择", false)
            && (!contains(responseBody, "进入选课", false) || !contains(responseBody, "进入首页", false))) {
            return;   // 不触发
        }
    }
    // :116
    LogManager.i$default(logManager, this.TAG, "选课入口页：模拟「进入首页」GET xsMainV.jsp", null, 4, null);

    // :118-120  —— 逐字
    String str2 = getSecureBaseUrl() + "/jsxsd/framework/xsrkxz.htmlx";
    String str3 = getSecureBaseUrl() + "/jsxsd/framework/xsMainV.jsp";
    Map<String,String> cookiesLocal = Jsoup.connect(str3).cookies(cookieMap)
            .header("Referer", str2)
            .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
            .method(Connection.Method.GET).ignoreHttpErrors(true).execute().cookies();

    // :122-123
    cookieMap.putAll(cookiesLocal);
    this.timetableReferer = str3;      // 供后续抓课表当 Referer
}
```

> Swift 等价：登录成功后，若最终 URL / 页面文本命中上述条件，就 GET `{base}/jsxsd/framework/xsMainV.jsp`（Referer = `{base}/jsxsd/framework/xsrkxz.htmlx`），把响应 Cookie 合并，并把 `timetableReferer` 设为该 jsp URL。

### 2.7 验证码 / 加密 结论

- **验证码：无。** 全流程没有验证码请求、没有 `RANDOMCODE` 字段、没有图片识别。只有账号 + 密码。
  - `// 不确定：目标站点若对某些 IP/账号强制验证码，需要人工先在该站点验证；应用本身没有处理路径。`
- **加密：有**，但**不是 MD5/DES/Base64**。它是强智的 `encrypt` 字符交错算法（§2.4），密钥材料来自服务端 `/Logon.do?method=logon&flag=sess` 返回的 `scode#sxh`。**密码明文只出现在请求构造前的字符串拼接里（`username + "%%%" + password`），之后永不以明文出现在网络字段中**（`userPassword` 字段固定为空串）。

---

## 3. 会话管理

- **存储**：解析器实例字段 `private Map<String,String> cookies`（`QiangzhiJwxtParser.java:49`），构造函数初始化为 `MapsKt.emptyMap()`（`:62`）。
- **传递**：每个请求显式 `.cookies(map)`。**jsoup 的 `Connection` 对象不复用**——每次都是新建的 `Jsoup.connect(...)` 链式对象。
- **累积**：每一跳的响应 Cookie 都合并进同一个 map：

```java
// login$2.java:206-209
Map<String,String> mutableMap = MapsKt.toMutableMap(cookies);
mutableMap.putAll(execute.cookies());

// login$2.java:257
mutableMap2.putAll(cookies4);
this.this$0.cookies = mutableMap2;
```

- **持久化**：**没有**。Cookie 只活在内存里的 `QiangzhiJwxtParser` 实例中；`LocalStorage` 里没有任何 Cookie key。进程结束即失效 → 每次同步都要重新登录。
  `// 不确定：是否有其它组件（如 WorkManager 的持久化）缓存了会话 —— 在 LocalStorage 与 JwxtTimetableSync 范围内未见。`
- **过期判断**：

```java
// QiangzhiJwxtParser$fetchTimetable$2.java:104-110
if (execute.statusCode() == 302 && (header = execute.header("location")) != null
        && StringsKt.contains$default(header, "Login", false, 2, null)) {
    LogManager...("Session已过期，需要重新登录");
    return CollectionsKt.emptyList();   // 返回空表，不自动重登
}
```

> Swift 等价：用 `HTTPCookieStorage.shared` 或自建 `[HTTPCookie]` 字典；给 `URLSession` 配 `httpCookieStorage` + `httpShouldSetCookies = true` 让 Cookie 自动累积。过期判断改为：**重定向后的最终 URL 路径含 `Login`（忽略大小写）**，或响应体命中登录页 `<title>登录</title>`。检测到过期后同样返回空课表（由上层决定是否重新登录）。

---

## 4. 课表抓取

### 4.1 URL 与查询参数

```java
// fetchTimetable$2.java:79  —— 逐字
String str9 = secureBaseUrl + "/jsxsd/xskb/xskb_list.do";
```

- **GET**，**没有任何查询参数**：不带学年、不带学期、不带周次。
- `// 不确定：` (a) 学年/学期/周次**很可能**由服务端按当前会话的默认值（或上次在网页端选中的值）决定，应用完全没有传 —— 反编译可见的事实是"零参数"；(b) 若需要切学期，需另行在网页端操作，本应用无此代码路径。
- 返回页面的行列约定 → §4.2；是否为响应式（`xsMainV.htmlx`）或打印版（`xskb_list.do`）由 `// 不确定：` 标注。

完整请求（逐字）：

```java
// fetchTimetable$2.java:79-98
String str9 = secureBaseUrl + "/jsxsd/xskb/xskb_list.do";
str2 = this.this$0.timetableReferer;
if (str2 == null) { str2 = getSecureBaseUrl() + "/jsxsd/framework/xsMainV.htmlx"; }
LogManager...("获取课表: " + str9);
LogManager...("当前Cookie数量: " + map2.size());

Connection connect = Jsoup.connect(str9);
Connection.Response execute = connect.cookies(map)
        .header("Referer", str2)
        .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
        .method(Connection.Method.GET)
        .ignoreHttpErrors(true)
        .execute();
LogManager...("课表响应状态: " + execute.statusCode());   // :102
```

### 4.2 双解析风格与优先级

```java
// fetchTimetable$2.java:112-134
body = ...;                                    // 响应体
parseDoStyle = parseDoStyle(body);             // :115  风格 A（DO 风格，旧版强智）
if (parseDoStyle.isEmpty()) {
    parseDoStyle = parseWakeUpStyle(body);     // :117  风格 B（WakeUp 风格，兜底）
}
if (parseDoStyle.isEmpty()) {
    LogManager...("未命中可用课表解析规则，返回空课表");   // :123
    return CollectionsKt.emptyList();                  // :125
}
mergeDuplicateCourses = mergeDuplicateCourses(parseDoStyle);   // :127
collapseAdjacentCourses = collapseAdjacentCourses(...);        // :128
LogManager...( "WakeUp风格解析成功：原始 " + parseDoStyle.size() + " 门，去重后 "
             + mergeDuplicateCourses.size() + " 门，合并连排后 " + collapseAdjacentCourses.size() + " 门"); // :134
return collapseAdjacentCourses;
```

> **顺序结论**：`parseDoStyle`（选择器 `table#timetable`）**先试**；`parseWakeUpStyle`（纯字符串切片）是**兜底**。两种风格都要支持。

### 4.3 风格 A：`parseDoStyle`（选择器 `table#timetable`）

```java
// QiangzhiJwxtParser.java:169-227
public final List<Course> parseDoStyle(String html) {
    Element selectFirst = Jsoup.parse(html).selectFirst("table#timetable");   // :171
    if (selectFirst == null) { return CollectionsKt.emptyList(); }            // :173
    Elements select = selectFirst.select("tr");                               // :175
    int i = 0;   // 大节序号（从 0 起，每命中一行 +1）
    for (Element element : select) {
        // :183-188  取该行 <th> 文本，去掉所有空格
        Element selectFirst2 = element.selectFirst("th");
        ...
        String text = selectFirst2.text();
        replace$default = StringsKt.replace$default(text, " ", "", ...);

        // :189  只有同时含 "第" 和 "大节" 的行才算"大节行"
        if (StringsKt.contains$default(replace$default, "第", ...)
                && StringsKt.contains$default(replace$default, "大节", ...)) {
            i++;                                            // :190
            Elements select2 = element.select("> td");      // :191  直接子 td
            int i2 = 0;
            for (Element element3 : select2) {
                int i3 = i2 + 1;
                if (1 <= i3 && i3 < 8) {                    // :200  列 1..7 = 周一..周日
                    String content = extractDoCellContent(element3);   // :202
                    if (!StringsKt.isBlank(content)) {
                        List<Course> list = parseKbContent(content, i, i3);  // :204
                        if (!list.isEmpty()) { arrayList.addAll(list); }     // :206
                    }
                }
                i2 = i3;
            }
        }
    }
    LogManager...("DO风格解析结果: " + arrayList.size() + " 门课程");   // :218
    return arrayList;
    // catch: LogManager...("DO风格解析失败: " + e.getMessage());  // :223
    //        return CollectionsKt.emptyList();                   // :225
}
```

**行列约定（风格 A）**
- 表格：`table#timetable`
- 行：`.select("tr")`，其中**只有** `<th>` 文本同时含 `第` 与 `大节` 的行才计为一个大节行
- 大节序号 `i`：**从 1 开始**（`:190` 先自增再用），即 `i = 1` 表示第一个大节
- 列：`element.select("> td")` 的**直接子 td**，索引 `i3 = i2+1` 落在 `1 <= i3 < 8` 才处理 → **列 1..7 对应 周一..周日**（列 0 = 节次标签列，被跳过）

**单元格内容提取**（`QiangzhiJwxtParser.java:229-292`，逐字要点）：

```java
Elements select = td.select("div.kbcontent");                   // :232
// 只保留 html 含 "<font" 的 div（忽略大小写）
if (StringsKt.contains(html, "<font", true)) { ... }            // :239
// 优先挑 html 含 title='教师' / title="教师" / title=教师 的那个 div
if (contains(str, "title='教师'", true) || contains(str, "title=\"教师\"", true)
        || contains(str, "title=教师", true)) { break; }         // :254
// 没挑到就用第一个
if (element2 == null) element2 = (Element) CollectionsKt.firstOrNull(arrayList2);   // :260
String obj3 = StringsKt.trim(html3).toString();                  // :266
if (!StringsKt.isBlank(obj3) && !Intrinsics.areEqual(obj3, "&nbsp;")) { return obj3; }   // :267-268
// 兜底：同样的逻辑走 div.kbcontent1
Elements select2 = td.select("div.kbcontent1");                  // :270
... 只取 html 含 "<font" 的 ...                                   // :281
return blank ? "" : obj4;                                        // :291
```

**`rowspan` 处理：没有任何 rowspan 属性解析代码。**

> Swift/URLSession 等价：用 `SwiftSoup`（等价于 jsoup，同样是 CSS 选择器 + DOM）或 `Fuzi`/`HTMLKit` + `XPath`。
> 选择器直接用：`try doc.select("table#timetable").first()` → `.select("tr")`，每行 `try row.select("th").first()?.text()`，`row.select("> td")`（SwiftSoup 支持 `:scope > td` 或 `row.children().filter { $0.tagName() == "td" }`）。
> **`rowspan` 必须自己补**：Android 端靠"每个 td 对应固定列 + 大节行严格配对"侥幸工作；若真实页面有 `rowspan`，两端结果都会错位，需自行按 rowspan 填充网格。`// 不确定：目标站点该页是否真的没有 rowspan —— 反编译代码只是没处理。`

### 4.4 风格 B：`parseWakeUpStyle`（纯字符串切片兜底）

`QiangzhiJwxtParser.java:311-616`；辅助 `parseWakeUpLater`（`:628-751`）、`countCenterCells`（`:754-766`）。
**逐字的关键切片常量：**

```java
String str5 = "left=100,top=50')\">";        // :321   单元格块的起始标记（WakeUp 模板）
String str6 = "substring(...)";
int indexOf$default2 = StringsKt.indexOf$default(html, "Table1", 0, false, ...);   // :324
if (indexOf$default2 < 0) return CollectionsKt.emptyList();                       // :326
int indexOf$default3 = StringsKt.indexOf$default(html, ">", indexOf$default2, ...);          // :328
if (indexOf$default3 < 0) return CollectionsKt.emptyList();                                 // :330
int indexOf$default4 = StringsKt.indexOf$default(html, "</table>", indexOf$default3, ...);   // :332
if (indexOf$default4 < 0) return CollectionsKt.emptyList();                                 // :334
String substring = html.substring(indexOf$default3, indexOf$default4);   // :336  Table1 的内容
```

然后：

```java
// :342-348  逐个 <tr>...</tr> 切片
int idxOpen  = indexOf(substring, "<tr>", i4);
int idxClose = indexOf(substring, "</tr>", idxOpen);
String row   = substring.substring(idxOpen, idxClose);
String marker = "left=100,top=50')\">";
if (StringsKt.contains$default(row, marker, false, 2, null)) {          // :348
    // :349-352  从 ">第" 后取到 "节" 之间 → 大节号
    int idxDi  = indexOf(row, ">第", 0, false, ...);
    int i5     = idxDi + 2;
    int idxJie = indexOf(row, "节", i5, false, ...);
    String num = row.substring(i5, idxJie);      // :353
    Integer intOrNull = StringsKt.toIntOrNull(num);  // :355
}
```

**分块与文本化**（`parseWakeUpLater` / `splitCourseSegments`）：

```java
// QiangzhiJwxtParser.java:642-647（parseWakeUpLater 内）
if (StringsKt.contains$default(str, "<br><", false, 2, null)) {
    substringAfter$default = StringsKt.substringBefore$default(
            StringsKt.substringAfter$default(str, ">", null, 2, null), "<br><", null, 2, null);
} else {
    substringAfter$default = StringsKt.substringAfter$default(str, ">", null, 2, null);
}
List split$default2 = StringsKt.split$default(substringAfter$default, new String[]{"<br>"}, false, 0, 6, null);
```

```java
// QiangzhiJwxtParser.java:952-1009  splitCourseSegments —— 一段单元格文本切成多门课
List<String> split = new Regex("-{5,}").split(str, 0);       // :954  ★ 5 个以上连续 '-' 作分隔
// → trim、丢空
// 若上面切出来为空：
if (!StringsKt.contains$default(str, "left=100,top=50", false, 2, null)) {    // :970
    return listOf(trim(html)) 去空;                                           // :971-983
}
List split$default = StringsKt.split$default(str,
        new String[]{"left=100,top=50')\">"}, false, 0, 6, null);             // :985
// :993-1001  每段截到第一个 "</td>" 为止，trim
Integer valueOf = Integer.valueOf(StringsKt.indexOf$default(str2, "</td>", 0, false, 6, null));
String substring = str2.substring(0, valueOf != null ? valueOf.intValue() : str2.length());
```

**单双周的字符串判定（风格 B 专用，与风格 A 的 `parseWeekMeta` 不同）**：

```java
// :438-439（parseWakeUpStyle 内）
if (StringsKt.contains$default(str, "单周", false, 2, null)) {
    i2 = StringsKt.contains$default(str, "双周", false, 2, null) ? 2 : 0;
}
// :595 同一模式重复一次
// :651-654（parseWakeUpLater 内，对 str3）
if (StringsKt.contains$default(str3, "单周", false, 2, null)) { ... }
i4 = StringsKt.contains$default(str3, "双周", false, 2, null) ? 2 : 0;
```

**周次范围提取（风格 B）**：

```java
// :768  private final Integer extractWakeUpStartWeek(String detail)
// :781  private final Integer extractWakeUpEndWeek(String detail)
```

> `// 不确定：这两个方法体（:768-793 区间）的逐字正则/切片逻辑未在本轮核验到行号级原文，只有签名与行号确认。若要 1:1 复刻风格 B 的周次解析，需要先 decompress/read QiangzhiJwxtParser.java:768-793。风格 A（`extractWeekRange`/`parseWeekMeta`）已 100% 逐字确认，**iOS 首选实现风格 A 的规则**。`

**一处 jadx 明显的反编译瑕疵（不要照抄）**：

```java
// :443 与 :651 附近
if (!StringsKt.contains$default((CharSequence) str, (CharSequence) "节/周", false, 2, (Object) null)) { ... }
// 后面紧跟一个 indexOf("节/周") > 0 的取值分支
```

> `// 不确定：` 这里的 `if (!contains(...))` 守卫被 jadx 取反了（真实语义应为 `if (contains(...))`），且 `"节/周"` 疑似是从字面量 `"节"` + `"周"` 拼接被内联后的产物（jadx 把相邻的分支字符串合并）。**不要照抄这一行**；风格 A 不受影响。

### 4.5 分隔符结论

| 层级 | 分隔符 | 出处 |
|---|---|---|
| 一个单元格 → 多门课 | `<td>` 内文本用 **连续 5 个以上 `-`**（正则 `-{5,}`）切分 | `QiangzhiJwxtParser.java:954` |
| 单元格块之间 | 字符串常量 `left=100,top=50')\">` | `:321`、`:985`、`parseWakeUpLater:636` |
| 单元格内字段行 | `<br>` / `<br><` | `:643-647` |
| 纯文本预览（仅日志/调试） | `<br>` → `" \| "`，其余标签 → 空，`&nbsp;` → 空格 | `:884` |
| 教学楼 + 教室拼接 | 单个**空格** `" "` | `:1107` |

> Swift 等价：`text.components(separatedBy:)` 无法直接表达 `-{5,}`，用 `text.replacingOccurrences(of: "-{5,}", with: "\u{1}", options: .regularExpression).components(separatedBy: "\u{1}")`，或 `NSRegularExpression` 枚举分段。`<br>` 变成 `"\n"` 后按行取字段。

### 4.6 `parseKbContent`：单个课程块 → Course

```java
// QiangzhiJwxtParser.java:874-950（逐字要点）
List<String> splitCourseSegments = splitCourseSegments(html);          // :879
for (String str : splitCourseSegments) {
    // :884 仅用于日志的纯文本预览
    String obj = trim(new Regex("<[^>]+>").replace(
                     new Regex("<br\\s*/?>", IGNORE_CASE).replace(str, " | "), "")
                 .replace("&nbsp;", " "));
    LogManager...("课程块原始文本: " + obj);                             // :887

    String extractCourseName = extractCourseName(str);                  // :889
    if (extractCourseName == null) { continue; }                        // :890  ★ 取不到课名就跳过整块
    String extractTeacher       = extractTeacher(str);                  // :893
    String extractLocationMerged= extractLocationMerged(str);           // :894
    String extractWeekRange     = extractWeekRange(str);                // :895
    WeekMeta parseWeekMeta      = parseWeekMeta(extractWeekRange, str); // :896
    Pair<Integer,Integer> extractPeriodRange = extractPeriodRange(str); // :897

    // :898-903  节次起点
    intValue = extractPeriodRange != null ? extractPeriodRange.getFirst()
             : (extractStartPeriod(str) != null ? extractStartPeriod(str) : (periodRow * 2) - 1);
    // :904-908  节次终点
    intValue2 = extractPeriodRange != null ? extractPeriodRange.getSecond()
              : (extractEndPeriod(str) != null ? extractEndPeriod(str) : periodRow * 2);

    LogManager...("课程解析结果: name=" + ... + ", weekRange=" + ... + ", dayOfWeek=" + ...
                  + ", period=" + intValue + "-" + intValue2
                  + ", startWeek=" + ... + ", endWeek=" + ... + ", isOdd=" + ...);   // :918-934

    // :938  —— Course 构造，字段顺序见 §9
    arrayList.add(new Course(0, extractCourseName, extractTeacher, extractLocationMerged,
                             dayOfWeek, intValue, intValue2, getStableColor(extractCourseName),
                             extractWeekRange, parseWeekMeta.getStartWeek(),
                             parseWeekMeta.getEndWeek(), parseWeekMeta.isOdd()));
}
// catch (Exception e): LogManager...("解析课程内容失败: " + e.getMessage());   // :946
//                      return CollectionsKt.emptyList();                    // :948
```

### 4.7 字段抽取器（逐字规则）

#### `extractCourseName(String html)` — `:1011-1056`

```java
Document doc = Jsoup.parseBodyFragment(html);                 // :1016
// :1017  排除的 title 值
{"教师", "教室", "教学楼", "周次(节次)", "周次", "通知单编号", "班级", "备注"}
// :1018  排除的 name 属性值
{"wkxx", "tzdbh", "jxlmc", "xsks", "bzstr", "ktmcstr"}
// :1019 遍历所有 <font>
// :1031 NBSP → 空格，trim
// :1036-1043 跳过：title 在黑名单 / name 属性在黑名单 /
//              文本以 "通知单编号" 开头 / 以 "班级：" 开头 / 等于 "备注："
// :1049-1052 返回第一个合格 <font> 的 .text()
// :1054 无合格项或异常 → null
```

> Swift 等价：`doc.body()?.select("font")`，逐项 `try font.attr("title")` / `attr("name")` 过滤，取 `try font.text()`。

#### `extractTeacher(String html)` — `:1065-1098`

```java
Jsoup.parseBodyFragment(html).select("font[title='教师'], font[title=\"教师\"]");   // :1070
// 取不到 → extractByTitleAttr(html, "教师")                                        // :1078/1080
// 再取不到 → 正则兜底：
Pattern.compile("title=['\"]教师['\"][^>]*>([^<]+)</font>")                        // :1084
//   取 group(1) 并 trim
```

#### `extractLocationMerged(String html)` — `:1100-1111`

```java
room = extractRoomRaw(html);
building = extractBuildingRaw(html);
return (both non-blank) ? building + " " + room                                       // :1107
                        : (the non-blank one);                                        // :1110
```

#### `extractRoomRaw(String html)` — `:1120-1153`

```java
Jsoup.parseBodyFragment(html).select("font[title='教室'], font[title=\"教室\"]");   // :1125
// 取不到 → extractByTitleAttr(html, "教室")                                        // :1133/1135
// 再取不到 → 正则：Pattern.compile("title=['\"]教室['\"][^>]*>([^<]+)</font>")      // :1139
// 最后：去掉字面量 "</a>"，再用 new Regex("<[^>]+>") 清掉所有标签，trim             // :1152
```

#### `extractBuildingRaw(String html)` — `:1155-1167`

```java
Jsoup.parseBodyFragment(html).select("font[name=jxlmc], font[title='教学楼'], font[title=\"教学楼\"]");  // :1159
// NBSP → 空格，trim；异常 → ""
```

#### `extractByTitleAttr(String fragmentHtml, String titleKeyword)` — `:1169-1224`

```java
// 第一轮：select("[title]")，title 精确等于（trim 后）titleKeyword → 返回 .text().trim()（非空）
// :1212 第二轮：再扫一遍，title contains(titleKeyword) → 返回 .text().trim()
// 都没有 → ""
```

#### `extractWeekRange(String html)` — `:1226-1236` ★核心

```java
// :1227  —— 逐字，先归一化再匹配
Matcher matcher = Pattern.compile("(\\d+(?:-\\d+)?(?:,\\d+(?:-\\d+)?)*)\\((?:周|单|双)\\)")
    .matcher(
        StringsKt.replace$default(                       // 4) 去掉 "周次"
          StringsKt.replace$default(                     // 3) 去掉所有空格
            StringsKt.replace$default(                   // 2) &nbsp; → 空格
              new Regex("<[^>]+>").replace(              // 1b) 所有标签 → " "
                new Regex("<br\\s*/?>", IGNORE_CASE).replace(html, " "),   // 1a) <br> → " "
                " "),
              "&nbsp;", " ", false, 4, null),
            " ", "", false, 4, null),
          "周次", "", false, 4, null));
if (matcher.find()) {
    String group = matcher.group(1);
    if (group == null) { group = ""; }
    return true ^ StringsKt.isBlank(group) ? group : "1-20";      // :1233  ★兜底 "1-20"
}
return "1-20";                                                    // :1235  ★兜底 "1-20"
```

> **归一化顺序必须一致**：`<br>`→空格 → 其余标签→空格 → `&nbsp;`→空格 → **删除所有空格** → 删除字面量 `周次`。
> 因此 `周次(节次)` 会先被删掉 `周次` 变成 `(节次)`，不干扰正则。

#### `parseWeekMeta(String weekRange, String html)` — `:1315-1335` ★核心

```java
// :1317-1323  —— 逐字：数字是从 weekRange（原始串，未去空格）里抽的
List<Integer> numbers = mapNotNull(Regex("\\d+").findAll(weekRange)) { it.toIntOrNull() };

Integer min = CollectionsKt.minOrNull(numbers);
int startWeek = (min != null) ? min : 1;                 // :1324-1325  ★兜底 startWeek = 1
Integer max = CollectionsKt.maxOrNull(numbers);
int endWeek   = (max != null) ? max : 20;                // :1326-1327  ★兜底 endWeek = 20

// :1328  ★ 单双周在 weekRange + html 的拼接上去空格后判断
String joined = StringsKt.replace$default(weekRange + html, " ", "", false, 4, null);
int isOdd = 0;                                           // :1316
if (new Regex("单周|\\(单\\)").containsMatchIn(joined)) {        // :1329
    isOdd = 1;
} else if (new Regex("双周|\\(双\\)").containsMatchIn(joined)) { // :1331
    isOdd = 2;
}
return new WeekMeta(startWeek, endWeek, isOdd);          // :1334
```

**`isOdd` 取值约定：`0` = 每周，`1` = 单周，`2` = 双周。**
**注意：不展开成周次列表**，只存 `startWeek` / `endWeek` / `isOdd` 三个数。

#### 节次

```java
// :1337-1344  extractStartPeriod
Pattern.compile("\\[(\\d+)-\\d+节\\]").matcher(html);   // group(1) → toIntOrNull；否则 null

// :1346-1353  extractEndPeriod
Pattern.compile("\\[\\d+-(\\d+)节\\]").matcher(html);   // group(1) → toIntOrNull；否则 null

// :1355-1371  extractPeriodRange —— 优先用这个
Pattern.compile("(\\d+)\\s*-\\s*(\\d+)\\s*节").matcher(html);   // :1359
// :1365-1366 只有 start > 0 且 end >= start 才返回 Pair(start, end)，否则 null
```

#### `getStableColor(String name)` — `:1373-1379`

```java
if (blank) return palette.get(0);                                        // :1376
return palette.get(Math.abs((int) StringsKt.first(str)) % palette.size());   // :1378
// palette（:63）：
// {-11751600, -14575885, -26624, -6543440, -16728876, -43230, -8825528,
//  -10453621, -12627531, -1499549}
```

> Swift 等价：`let i = abs(Int(name.unicodeScalars.first!.value)) % palette.count`（Java 的 `(int) char` = UTF-16 code unit，与 Swift `Character` 的标量值对 BMP 字符一致，对 emoji/组合字符不一致 → 颜色可能不同，可接受）。

---

## 5. 课次解析（周次 / 节次）

### 5.1 周次

| 输入形态 | `extractWeekRange` 结果 | `startWeek` | `endWeek` | `isOdd` |
|---|---|---|---|---|
| `1-16周` | `1-16` | 1 | 16 | 0 |
| `1,3,5周` | `1,3,5` | 1 | 5 | 0 |
| `1-16(单)` | `1-16` | 1 | 16 | 1 |
| `1-16(双)` | `1-16` | 1 | 16 | 2 |
| `1,3,5(单)` | `1,3,5` | 1 | 5 | 1（来自 html 里的 `单周`/`(单)`） |
| 匹配失败（如 `第1-16周` 被删了 `周` 但仍应匹配；`1~16周` 则失败） | `1-20`（硬兜底） | 1 | 20 | 0 或 html 里的单双 |

**解析失败兜底值（逐字）：** `weekRange = "1-20"`（`:1233`、`:1235`）；`startWeek = 1`（`:1325`）；`endWeek = 20`（`:1327`）；`isOdd = 0`（`:1316`）。
**注意 `1,3,5周` 这类非连续周次被压成 `startWeek=1, endWeek=5`**，即**中间的 2、4 周也会被显示**。iOS 端若要精确，需自行扩展成周次集合（但那会与 Android 行为不一致）。

### 5.2 节次

- 优先：`extractPeriodRange` 正则 `(\d+)\s*-\s*(\d+)\s*节` → `(start, end)`，且要求 `start > 0 && end >= start`（`:1365-1366`）。
- 其次：`extractStartPeriod` 的 `\[(\d+)-\d+节\]` / `extractEndPeriod` 的 `\[\d+-(\d+)节\]`。
- 兜底：用**大节行号**估算 —— `startPeriod = periodRow * 2 - 1`，`endPeriod = periodRow * 2`（`:902`、`:908`）。即第 1 大节 → 1–2 节，第 2 大节 → 3–4 节，依此类推。

### 5.3 是否使用内置时间表

**抓取阶段完全不用时间表。** 抓到的只有"节次序号"（`startPeriod` / `endPeriod`）。课次→具体钟点由本地作息表决定：

```java
// LocalStorage.java:263-279  defaultTimetableProfiles()
Pair[]{ ("08:10","08:55"), ("09:05","09:50"), ("10:20","11:05"), ("11:15","12:00"),
        ("14:10","14:55"), ("15:05","15:50"), ("16:20","17:05"), ("17:15","18:00"),
        ("19:30","20:15"), ("20:25","21:10") }        // :265  10 节课
// :278  → new TimetableProfile("default", "默认", size, arrayList)
```

其它默认值（`LocalStorage.java:69-89`）：`periodsPerDay = 12`、`periodDurationMinutes = 45`、`breakDurationMinutes = 10`、`firstPeriodStartTime = "08:00"`、`semesterWeeks = 20`、`showSaturday = showSunday = showWeekend`(默认 false)。

> Swift 等价：抓取结果只存 `startPeriod`/`endPeriod`；渲染时用本地 `TimetableProfile` 映射到钟点。可复用上面 10 节默认表。

---

## 6. 异常与提示（全部中文原字符串）

### 6.1 日志（LogManager，非用户可见）

| 文案（逐字） | 出处 |
|---|---|
| `"开始登录，用户名: " + username` | `login$2.java:125` |
| `"登录URL: " + secureBaseUrl` | `login$2.java:134` |
| `"步骤1: 访问首页: " + str4` | `login$2.java:143` |
| `"初始Cookie: " + cookies` | `login$2.java:149` |
| `"获取加密参数: " + str26` | `login$2.java:156` |
| `"加密参数响应: " + body` | `login$2.java:166` |
| `"scode: " + take(str27, 50) + "..."` | `login$2.java:179` |
| `"sxh: " + str28` | `login$2.java:184` |
| `"加密后的encoded: " + encryptCode` | `login$2.java:190` |
| `"POST登录: " + str29` | `login$2.java:197` |
| `"登录响应状态: " + statusCode` | `login$2.java:203` |
| `"登录响应内容: " + take(body2, 500)` | `login$2.java:224` |
| `"主页面标题: " + str5` | `login$2.java:238` |
| `"登录成功，Cookie数量: " + map.size()` | `login$2.java:262` |
| `"登录成功（选课入口页）"` | `login$2.java:279` |
| `"登录失败: 用户名或密码错误"` | `login$2.java:304` |
| `"登录成功！"` | `login$2.java:315` |
| `"获取加密参数失败"` | `login$2.java:340` |
| `"登录失败"` | `login$2.java:271` |
| `"登录异常"`（e 级，带异常） | `login$2.java:350` |
| `"选课入口页：模拟「进入首页」GET xsMainV.jsp"` | `QiangzhiJwxtParser.java:116` |
| `"使用HTTPS URL: " + url` | `QiangzhiJwxtParser.java:86` |
| `"获取课表: " + str9` | `fetchTimetable$2.java:88` |
| `"当前Cookie数量: " + map2.size()` | `fetchTimetable$2.java:94` |
| `"课表响应状态: " + statusCode` | `fetchTimetable$2.java:102` |
| `"Session已过期，需要重新登录"` | `fetchTimetable$2.java:108` |
| `"未命中可用课表解析规则，返回空课表"` | `fetchTimetable$2.java:123` |
| `"WakeUp风格解析成功：原始 N 门，去重后 M 门，合并连排后 K 门"` | `fetchTimetable$2.java:134` |
| `"获取课表失败"`（e 级，带异常） | `fetchTimetable$2.java:140` |
| `"DO风格解析结果: " + N + " 门课程"` | `QiangzhiJwxtParser.java:218` |
| `"DO风格解析失败: " + e.getMessage()` | `QiangzhiJwxtParser.java:223` |
| `"WakeUp风格解析失败: " + e.getMessage()` | `QiangzhiJwxtParser.java:613` |
| `"课程块原始文本: " + text` | `QiangzhiJwxtParser.java:887` |
| `"课程解析结果: name=…, weekRange=…, dayOfWeek=…, period=…-…, startWeek=…, endWeek=…, isOdd=…"` | `QiangzhiJwxtParser.java:918-934` |
| `"解析课程内容失败: " + e.getMessage()` | `QiangzhiJwxtParser.java:946` |

### 6.2 用户可见（抛给 UI 的 Exception / 提示）

| 文案（逐字） | 出处 | 触发条件 |
|---|---|---|
| `"登录教务系统失败，请检查账号密码"` | `JwxtTimetableSync.java:85` | `login(...)` 返回 false 时抛出 |
| `// 不确定：` 用户界面上的 toast/snackbar 中文文案 | `TimetableViewModel.java` / `ui\*.java` | 在 ViewModel 范围内未捕获到独立的用户提示字符串；UI 可能直接展示上面的异常 `message`，或用状态码而非文案 |

```java
// JwxtTimetableSync.java:84-86  —— 逐字
if (((Boolean) obj).booleanValue()) {
    throw new Exception("登录教务系统失败，请检查账号密码");
}
```

> `// 不确定：` 这里的 `if (login(...) == true) throw` 逻辑显然是反的（jadx 把 `if (!login)` 反推错）。**原始语义一定是 `if (!登录成功) throw`。iOS 端按"登录失败 → 抛此文案"实现。**

### 6.3 后台自动同步（`TimetableAutoRefreshWorker.java`）

- 该 Worker 负责定时/条件触发的自动同步；其中文提示与错误分支在 `:1-190` 范围内。
  `// 不确定：Worker 内具体的中文通知文案未在本轮逐字核验（早期 grep 只确认了文件规模与职责）。若 iOS 端要实现后台刷新提示，需要 read TimetableAutoRefreshWorker.java 全文。`

---

## 7. 重复导入（合并 / 覆盖 / 去重）

### 7.1 导入策略：**全量覆盖**

```java
// ui\TimetableViewModel.java（insertCourses 路径）
// 先 deleteAllCourses，再逐条 insertCourses；列表为空时不动本地数据
```

- 抓取结果**非空** → **清空本地课表再全量写入**（覆盖，不追加）。
- 抓取结果**为空** → **不覆盖**（保留本地已有课表）。
- 相关方法：`TimetableViewModel.java:179 deleteAllCourses`、`:192 refreshTimetable`。

> Swift 等价：`if !fetched.isEmpty { try db.deleteAll(); try db.insert(fetched) }`。

### 7.2 解析阶段的两层去重（`QiangzhiJwxtParser`）

**第 1 层 `mergeDuplicateCourses`（`:795-811`）** —— 按复合键判重，**保留首次出现**，并把缺失字段补齐：

```java
// :799  —— 逐字：判重键（用 "|" 连接 8 个字段）
CollectionsKt.joinToString$default(CollectionsKt.listOf(new String[]{
    course.getName(),
    String.valueOf(course.getDayOfWeek()),
    String.valueOf(course.getStartPeriod()),
    String.valueOf(course.getEndPeriod()),
    course.getWeekRange(),
    String.valueOf(course.getStartWeek()),
    String.valueOf(course.getEndWeek()),
    String.valueOf(course.isOdd())
}), "|", null, null, 0, null, null, 62, null);

// :801-806  已有同键 → 合并：teacher 为空则用新值、location 为空则用新值（其它字段保持第一份）
// :804 逐字关键表达式
StringsKt.isBlank(course2.getTeacher()) ^ true ? course2.getTeacher() : course.getTeacher()
StringsKt.isBlank(course2.getLocation()) ^ true ? course2.getLocation() : course.getLocation()
```

> 即判重键 = `name|dayOfWeek|startPeriod|endPeriod|weekRange|startWeek|endWeek|isOdd`。

**第 2 层 `collapseAdjacentCourses`（`:814-872`）** —— 相邻同课合并（连排合并）：

```java
// :849-856  先按 (dayOfWeek, startPeriod, name, location, teacher) 排序
// :863  —— 逐字，判定"可合并"的 9 个条件
Intrinsics.areEqual(course2.getName(),     course3.getName())
&& Intrinsics.areEqual(course2.getLocation(), course3.getLocation())
&& Intrinsics.areEqual(course2.getTeacher(),  course3.getTeacher())
&& course2.getDayOfWeek() == course3.getDayOfWeek()
&& course2.getEndPeriod() + 1 == course3.getStartPeriod()      // ★ 节次紧邻
&& Intrinsics.areEqual(course2.getWeekRange(), course3.getWeekRange())
&& course2.getStartWeek() == course3.getStartWeek()
&& course2.getEndWeek()   == course3.getEndWeek()
&& course2.isOdd()        == course3.isOdd()
// :864  合并 = 保留前者的 startPeriod，取后者的 endPeriod
(r26 & 64) != 0 ? course2.endPeriod : course3.getEndPeriod()
```

> Swift 等价：先按 `mergeKey` 做 `Dictionary(grouping:)` 或有序 `reduce` 合并缺失字段；再 `sorted { (day, start, name, location, teacher) 字典序 }`，然后单次遍历合并 `endPeriod + 1 == next.startPeriod` 的相邻项。

---

## 8. 持久化

**容器：Android `SharedPreferences`，文件名 `"timetable_prefs"`，模式 `0`（MODE_PRIVATE）。**

```java
// LocalStorage.java:31
SharedPreferences sharedPreferences = context.getSharedPreferences("timetable_prefs", 0);
```

### 8.1 key 字面量一览

| key | 类型 | 写入处 | 读取处 | 说明 |
|---|---|---|---|---|
| `"username"` | String | `LocalStorage.java:41`（`HintConstants.AUTOFILL_HINT_USERNAME`） | `:46` | 教务账号（**明文**） |
| `"password"` | String | `LocalStorage.java:41`（`HintConstants.AUTOFILL_HINT_PASSWORD`） | `:50` | 教务密码（**明文**） |
| `"jwxtUrl"` | String | `LocalStorage.java:41` | `:54`（默认 `UserCredentials.DEFAULT_JWXT_URL`） | 教务系统根 URL |
| `"courses_json"` | String(JSON) | `LocalStorage.java:111` | `:118` | 课表数组 |
| `"timetable_profiles_json"` | String(JSON) | `LocalStorage.java:187` | `:193` | 作息表数组 |
| `"backgroundImageUri"` | String | `:64` | `:68` | |
| `"periodsPerDay"` | Int | `:64` | `:69`（默认 12） | |
| `"periodDurationMinutes"` | Int | `:64` | `:70`（默认 45） | |
| `"breakDurationMinutes"` | Int | `:64` | `:71`（默认 10） | |
| `"firstPeriodStartTime"` | String | `:64` | `:72`（默认 `"08:00"`） | |
| `"firstWeekStartDate"` | String | `:64` | `:74` | |
| `"semesterWeeks"` | Int | `:64` | `:75`（默认 20） | |
| `"showSaturday"` | Bool | `:64` | `:77`（回落到旧 key `"showWeekend"`） | |
| `"showSunday"` | Bool | `:64` | `:79`（回落到 `"showWeekend"`） | |
| `"showWeekend"` | Bool | — | `:77`/`:79` | **旧版兼容 key** |
| `"showNonCurrentWeekCourses"` | Bool | `:64` | `:80` | |
| `"showWeekSlider"` | Bool | `:64` | `:81` | |
| `"reverseMainText"` | Bool | `:64` | `:82` | |
| `"autoCheckUpdate"` | Bool | `:64` | `:83` | |
| `"autoSyncTimetableFromJwxt"` | Bool | `:64` | `:84` | |
| `"selectedTimetableProfileId"` | String | `:64` | `:85`（默认 `"default"`） | |
| `"classReminderEnabled"` | Bool | `:64` | `:87` | |
| `"classReminderMode"` | String | `:64` | `:88`（默认 `"weak"`） | |
| `"classReminderMinutes"` | Int | `:64` | `:89`（默认 10） | |
| `"nonCurrentWeekCourseAlphaPercent"` | Int | `:64` | `:89`（默认 45） | |
| `"courseCardAlphaPercent"` | Int | `:64` | `:89`（默认 100） | |
| `"courseFrostedIntensityPercent"` | Int | `:64` | `:89`（默认 100） | |
| `"courseCellHeightDp"` | Int | `:64` | `:89`（默认 69） | |
| `"courseTextSizeSp"` | Int | `:64` | `:89`（默认 10） | |
| `"showCourseTime"` | Bool | `:64` | `:89`（默认 true） | |
| `"showCourseLocation"` | Bool | `:64` | `:89`（默认 true） | |
| `"showCourseTeacher"` | Bool | `:64` | `:89`（默认 true） | |
| `"disclaimer_dont_show"` | Bool | `:286` | `:282`（默认 false） | |
| `"usage_guide_dont_show"` | Bool | `:294` | `:290`（默认 false） | |

**没有**任何 Cookie / 会话 key。

> **`"username"` / `"password"` 的 key 字面量来源已核实**：`androidx.autofill.HintConstants.AUTOFILL_HINT_USERNAME = "username"`、`AUTOFILL_HINT_PASSWORD = "password"`、`AUTOFILL_HINT_NAME = "name"`（见 `apk_work\jadx_out\sources\androidx\autofill\HintConstants.java:48,24,21`）。

### 8.2 `courses_json` 结构（逐字字段名 + 默认值）

写入（`LocalStorage.java:94-111`）：

```java
jSONObject.put("id",            course.getId());
jSONObject.put("name",          course.getName());       // HintConstants.AUTOFILL_HINT_NAME == "name"
jSONObject.put("teacher",       course.getTeacher());
jSONObject.put("location",      course.getLocation());
jSONObject.put("dayOfWeek",     course.getDayOfWeek());
jSONObject.put("startPeriod",   course.getStartPeriod());
jSONObject.put("endPeriod",     course.getEndPeriod());
jSONObject.put("color",         course.getColor());
jSONObject.put("weekRange",     course.getWeekRange());
jSONObject.put("startWeek",     course.getStartWeek());
jSONObject.put("endWeek",       course.getEndWeek());
jSONObject.put("isOdd",         course.isOdd());
// :111
this.prefs.edit().putString("courses_json", jSONArray.toString()).apply();
```

读取默认值（`LocalStorage.java:137-151`）：

| 字段 | 读默认值 |
|---|---|
| `id` | `i`（循环索引，初值 0） |
| `name` | `""` |
| `teacher` | `""` |
| `location` | `""` |
| `dayOfWeek` | `1` |
| `startPeriod` | `1` |
| `endPeriod` | `1` |
| `color` | `-11751600`（palette 第 0 项） |
| `weekRange` | `"1-20"` |
| `startWeek` | `1` |
| `endWeek` | `20` |
| `isOdd` | `0` |

解析异常：`"getCourses parse error"`（`:159`）→ 返回空列表。

### 8.3 `timetable_profiles_json` 结构

写入（`LocalStorage.java:170-187`）：外层对象 `{"id", "name", "periodsPerDay", "periodTimes": [ {"index","start","end"} ]}`；
读取默认值（`:224-247`）：`index` → `i2+1`；`start` → `"08:00"`；`end` → `"08:45"`；`id` → `"profile_" + i`；`name` → `"课表" + (i+1)`；`periodsPerDay` → `coerceAtLeast(periodTimes.size(), 1)`。
解析异常：`"getTimetableProfiles parse error"`（`:258`）→ 返回内置默认表。

> Swift 等价：`UserDefaults` 存 `courses_json` 等字符串（保持互操作），或直接改成 `Codable` + 独立文件。**字段名建议保持原样**，便于与 Android 端数据互通、便于对照。

---

## 9. Course 模型（构造参数顺序）

```java
// QiangzhiJwxtParser.java:938  —— 逐字
new Course(0, extractCourseName, extractTeacher, extractLocationMerged,
           dayOfWeek, intValue, intValue2, getStableColor(extractCourseName),
           extractWeekRange, parseWeekMeta.getStartWeek(),
           parseWeekMeta.getEndWeek(), parseWeekMeta.isOdd())
```

参数顺序（12 个）：`id, name, teacher, location, dayOfWeek, startPeriod, endPeriod, color, weekRange, startWeek, endWeek, isOdd`。

> 抓取阶段 `id` 一律传 `0`；`JwxtTimetableSync.java:70-78` 在返回前用下标回填：`copy(... id = i3 ...)`，`i3 = i2 + 1`（**从 1 开始编号**）。

> Swift 等价：
> ```swift
> struct Course: Codable {
>     var id: Int; var name: String; var teacher: String; var location: String
>     var dayOfWeek: Int; var startPeriod: Int; var endPeriod: Int; var color: Int
>     var weekRange: String; var startWeek: Int; var endWeek: Int; var isOdd: Int
> }
> ```
> 注意 `dayOfWeek` 约定：**1 = 周一 … 7 = 周日**（来自 `> td` 列的 `1 <= i3 < 8`，`QiangzhiJwxtParser.java:200`）。

---

## 10. 敏感信息处理

### 10.1 现状（Android 端）

```java
// LocalStorage.java:41  —— 逐字
boolean commit = this.prefs.edit()
        .putString(HintConstants.AUTOFILL_HINT_USERNAME, credentials.getUsername())   // "username"
        .putString(HintConstants.AUTOFILL_HINT_PASSWORD, credentials.getPassword())   // "password"
        .putString("jwxtUrl", credentials.getJwxtUrl())
        .commit();
```

- **密码明文**，存于 `SharedPreferences("timetable_prefs")` 的 key `"password"`。
- 容器仅靠 `MODE_PRIVATE`（`0`）保护 —— 非加密。
- 日志泄露：`:40` 打印 `"saveCredentials: username=" + username + ", jwxtUrl=" + jwxtUrl`（**不含**密码）；`:58` 打印 `"getCredentials: username=…, jwxtUrl=…`（**不含**密码）。登录日志（`login$2.java:125`）打印用户名，**不打印密码**；但 `login$2.java:190` 打印 **`"加密后的encoded: " + encryptCode`** —— 该串可由用户名 + 密码逆推（算法公开，见 §2.4），**等价于密码泄露**。
- Cookie 不持久化（§3）。

### 10.2 iOS 端建议

- 用户名 / 密码 / `jwxtUrl` 的敏感部分 → **Keychain**（`kSecClassGenericPassword`，`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`）。
- 密码**不要**写入 `UserDefaults`，**不要**写日志。若必须调试，只记录 `encoded` 的长度与前 4 字符。
- 会话 Cookie 用内存态 `HTTPCookieStorage`，退出即清；如需缓存，用 Keychain 或带 `kSecAttrAccessible*` 的文件保护。

---

## 11. 不确定项汇总（`// 不确定：…` 全表）

1. **jsoup 未显式设置超时** —— 全部依赖 jsoup 默认（约 30s connect / 30s read）。iOS 端应显式设 30s。
2. **字符集** —— 代码无 `charset()`、无 `new String(bytes, "GBK")`；依赖 jsoup 的 Content-Type/meta 探测。iOS 需自行处理，建议 charset → meta → GBK 回落。
3. **jsoup 重定向** —— 是否跟随 `POST` 的 302 未知（jsoup 默认跟随所有方法）；iOS `URLSession` 会把 302 跟随掉，`fetchTimetable$2.java:104` 的 `statusCode == 302` 分支在 iOS 上基本不触发。
4. **账户锁定 / 限流 / 验证码强制** —— 应用无任何处理路径。
5. **`login$2.java:229` 的 `进入选课` && `进入首页`** —— jadx 很可能把 `||` 反推成 `&&`；`QiangzhiJwxtParser.java:110` 同名字符串是 `||`。建议 iOS 用 `||`。
6. **`JwxtTimetableSync.java:84` 的 `if (login == true) throw`** —— 逻辑显然是反的（应为 `if (!login) throw`）。
7. **`QiangzhiJwxtParser.java:443` / `:651` 附近的 `if (!contains(str, "节/周"))`** —— jadx 取反 + 相邻字面量被内联合并；**不要照抄**。
8. **`parseWakeUpLater` / `extractWakeUpStartWeek`（`:768-793`）/ `extractWakeUpEndWeek`（`:781-793`）的字面量细节** —— 本轮只确认签名与行号；若要 1:1 复刻风格 B，需再读该区间原文。风格 A 已完全逐字确认。
9. **课表页 `xskb_list.do` 的学年 / 学期 / 周次参数** —— 应用**完全不传**（零查询参数）。切学期需先在网页端操作，本应用无该代码路径。
10. **`rowspan` 处理** —— 代码中不存在任何 rowspan 解析；若真实页面有 rowspan，两端都会列错位。
11. **HTML 结构变化的兜底** —— 只有"风格 A → 风格 B → 返回空表"三层，没有第三种（如新版 `xsMainV` 内嵌 JSON）解析器。若两者都未命中，就是空课表。
12. **`TimetableAutoRefreshWorker` 的用户提示文案** —— 未逐字核验。
13. **`TimetableViewModel` 的 UI 提示文案** —— 未捕获到独立字符串，可能直接展示异常 message。
14. **`UserCredentials.DEFAULT_JWXT_URL` 之外的默认 URL** —— 只此一个：`https://jwgl.xihang.com.cn`（`UserCredentials.java:13`）；这是**西安航空学院**的教务地址，说明本应用主要面向该校，其它学校需用户自行填 `jwxtUrl`。
15. **`encryptCode` 与强智官方 `encrypt` 的逐字节一致性** —— 无法从字节码证明，但这是应用实际发送并被服务端接受的内容。

---

## 12. iOS 端实现清单（TL;DR）

```
1. HTTPS 化 baseURL（http:// → https://）
2. URLSessionConfiguration.default + timeout 30s（connect/read 同 jsoup 默认）
3. Cookie：HTTPCookieStorage.shared 自动累积；自建 timetableReferer
4. 跳 1  GET  {base}/                                    （无 UA/Referer）
5. 跳 2  POST {base}/Logon.do?method=logon&flag=sess     （带 Cookie，无 body）
         body == "no" 或 不含 "#"  →  失败 "获取加密参数失败"
         scode = body.split("#")[0], sxh = body.split("#")[1]
6. 跳 3  POST {base}/Logon.do?method=logon               （Cookie + Referer {base}/ + UA）
         Content-Type: application/x-www-form-urlencoded
         userAccount = 用户名
         userPassword = ""                              ← 逐字空串
         encoded = encryptCode(用户名 + "%%%" + 密码, scode, sxh)
7. 判定：body 含 欢迎/主页 → 成功
         body 含 用户名或密码错误/密码错误 → 失败
         最终URL 含 xsrkxz 或 body 含 入口选择 或 (含 进入选课 || 含 进入首页) → 成功（选课入口页）
         否则 GET {base}/jsxsd/framework/xsMainV.htmlx 取 <title>；
              title == "登录" 或含 "Login" → 失败；否则成功
8. 成功尾部：必要时走选课网关 GET {base}/jsxsd/framework/xsMainV.jsp
         （Referer {base}/jsxsd/framework/xsrkxz.htmlx，设 timetableReferer）
         再 GET {base}/jsxsd/framework/xsMainV.htmlx（Referer = timetableReferer ?? 自身，UA）
         合并所有 Cookie
9. 抓课表 GET {base}/jsxsd/xskb/xskb_list.do          （Cookie + Referer + UA，零查询参数）
         若最终 URL/location 含 "Login" → 会话过期 → 返回空表
10. 解析：先 table#timetable（DO 风格），空则 Table1 字符串切片（WakeUp 风格）
11. 字段：font[title='教师'] / font[title='教室'] / font[title='教学楼'] / font[name=jxlmc]
12. 周次：正则 (\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*)\((?:周|单|双)\)   兜底 "1-20"
         startWeek=min(数字)??1, endWeek=max(数字)??20, isOdd=单周/单)→1, 双周/(双)→2, else 0
13. 节次：(start-end)节 → (start,end)；否则 [s-e节]；否则 periodRow*2-1 / periodRow*2
14. 后处理：mergeDuplicateCourses（键 name|day|startP|endP|weekRange|sW|eW|isOdd）
           → collapseAdjacentCourses（同 name/location/teacher/day/周次 且 endPeriod+1==startPeriod 则并）
15. 导入：非空 → 全量覆盖（先删后插）；空 → 不动本地
16. 落库：字段名照抄 courses_json（id,name,teacher,location,dayOfWeek,startPeriod,
           endPeriod,color,weekRange,startWeek,endWeek,isOdd）
17. 凭据：Keychain（不要 UserDefaults）；日志不打印 encoded 全串
```

---

*文档结束。所有 URL、表单字段、正则、分隔符、中文文案均取自上述反编译文件的实际行；推不出来的地方已全部标注 `// 不确定：…`，未做任何猜测性补全。*

# 教务登录失败修复 · 补丁说明

> 本目录只给你看，**不要提交进货仓**。

---

## 一、这次的 bug 到底是什么

登录教务系统时，要先把 `学号%%%密码` 用服务端下发的 `scode`/`sxh` 做**字符交织**，生成
`encoded` 字段再提交。原版 Android 的循环上界是**主串的长度**：

```java
int length = code.length();
while (i < length) { ... }
```

我之前移植时，把这个上界写成了**固定常量 20**（原版源码里确实有个 `while (i < 20)`
的残留痕迹，我照抄了）。

后果：当 `学号%%%密码` **不足 20 个字符**时（10 位学号 + 6 位密码 = 19 字符，正好命中），
主串已经取完，循环却还在空转，把**多余的 `scode` 片段拼到了 `encoded` 末尾**。

用服务端自己的解密算法反解，可以看到：

| 场景 | 服务端解出来的明文 |
| --- | --- |
| 正确算法 | `2023011234%%%abc123` ✅ |
| 修复前 | `2023011234%%%abc123O` ❌ |

服务端解出的密码**末尾多了一个字符** → 必然判「密码错误」→ 弹出安卓原版那句笼统的
「登录教务系统失败，请检查账号密码」。

所以现象就是：**浏览器能登，App 登不上**，而且换密码也没用。

---

## 二、需要覆盖的 5 个文件

| # | 仓库内路径 | 改了什么 |
| --- | --- | --- |
| 1 | `KebiaoCore/Sources/KebiaoCore/Jwxt/JwxtEncryptor.swift` | **核心修复**：循环上界 `interleaveLimit`(20) → `code.count`；第 20 位起追加剩余后立即结束 |
| 2 | `KebiaoCore/Sources/KebiaoCore/Jwxt/JwxtLoginClient.swift` | 新增 `JwxtLoginResult.diagnostic`：把每个失败分支的**具体原因**带出来 |
| 3 | `KebiaoCore/Sources/KebiaoCore/Jwxt/JwxtTimetableSync.swift` | `JwxtSyncError.loginFailed` 带上 `detail`；错误文案 = 安卓原文 + 括号内诊断 |
| 4 | `KebiaoCore/Tests/KebiaoCoreTests/JwxtEncryptorTests.swift` | 新增**判别性**用例（修复前必失败）+ 修正旧注释 |
| 5 | `KebiaoCore/Tests/KebiaoCoreTests/JwxtTimetableParserTests.swift` | 同步层文案断言改为「前缀一致 + 诊断后缀」 |

本包 `files/` 目录下已按**同样的目录结构**放了这 5 个文件的最终版本，可以直接覆盖。

**不用动**：`project.yml`、图标资源、其它页面 —— 这次是纯逻辑修复。

---

## 三、怎么推送（三选一）

### 方式 A：直接用你现有的工作区（推荐，最省事）

你本地工作区里**已经带着这次修复**了，所以只要把本地 HEAD 对齐远端、再只提交这 5 个文件：

```bash
git fetch origin
git reset --mixed origin/main          # 只动 HEAD 和暂存区，不碰工作区文件，修复不会丢
git add KebiaoCore/Sources/KebiaoCore/Jwxt/JwxtEncryptor.swift
git add KebiaoCore/Sources/KebiaoCore/Jwxt/JwxtLoginClient.swift
git add KebiaoCore/Sources/KebiaoCore/Jwxt/JwxtTimetableSync.swift
git add KebiaoCore/Tests/KebiaoCoreTests/JwxtEncryptorTests.swift
git add KebiaoCore/Tests/KebiaoCoreTests/JwxtTimetableParserTests.swift
git commit -F jwxt-login-fix/commit-message.txt
git push origin HEAD:main
```

提交前先 `git status` 扫一眼：正常应该**只有这 5 个文件**是 modified。

> `git reset --mixed` 是安全操作：工作区文件一个都不会被改。万一结果不对，
> `git reset --mixed` 再走一遍就行。**不要**用 `git reset --hard`。

### 方式 B：全新 clone（最干净，不会碰到你现有仓库的乱状态）

```bash
git clone https://github.com/pansy023/pansy.git
cd pansy
```

然后把本包 `files/` 下的 5 个文件，按同名路径**覆盖**过去：

```bash
cp -R /path/to/jwxt-login-fix/files/KebiaoCore .        # macOS / Linux
# Windows PowerShell:
#   Copy-Item -Recurse -Force "<本目录>\files\KebiaoCore" .
```

```bash
git add KebiaoCore
git commit -F /path/to/jwxt-login-fix/commit-message.txt
git push origin main
```

### 方式 C：GitHub 网页端（没有 git 时）

在 GitHub 上打开这 5 个文件 → 铅笔图标编辑 → 全选删除 → 粘贴 `files/` 下对应文件的完整内容
→ Commit。5 个文件提交完即可。注意 `JwxtEncryptor.swift` 和 `JwxtTimetableSync.swift` 内容较短，
`JwxtLoginClient.swift` 有 460 多行，网页粘贴容易漏，能用方式 A/B 就别用这个。

---

## 四、commit message

已放在 `commit-message.txt`，可直接 `git commit -F jwxt-login-fix/commit-message.txt`。
内容与本次改动一一对应（根因、证据、改了哪几处）。

---

## 五、推送之后

1. 到 GitHub **Actions** 页，等最新一次 `iOS Build` 的**两个 job 都变绿**：
   - `KebiaoCore 单元测试`
   - `生成工程并编译 iOS App`
2. 在该 run 页面下载 artifact **`Kebiao-unsigned-ipa`**，解压得到 `Kebiao.ipa`。
3. 用这份新 IPA 覆盖你本地正在用的那份，然后按你原来的方式自签、安装。
4. 装好后进 App：**设置 → 账号与同步** → 填学号/密码 → **保存设置** → **刷新课表**。

### 如果还是失败

这次错误提示不再是笼统的一句话，而会带**括号里的诊断**，例如：

- `服务端判定账号或密码错误（响应含「用户名或密码错误」/「密码错误」）`
- `未取到加密参数：/Logon.do?method=logon&flag=sess 响应为空、为 no 或不含 #`
- `被跳回登录页（验活页 title=登录）`
- `网络/传输异常：xxx`

把这整句（含括号）发我，就能直接定位到是哪一跳出的问题。

---

## 六、附：这次修复的验证依据

- 登录页**自带 JS**：`for (var i = 0; i < code.length; i++)`，`else` 分支
  `encoded += code.substring(i, code.length); i = code.length;`
- 安卓权威源码 `QiangzhiJwxtParser.java:127-162`：`while (i < length)`，`length = code.length()`
- 本机直连 `https://jwgl.xihang.com.cn` 实测：TLS 证书链完整（与 ATS 无关）、
  `POST /Logon.do?method=logon&flag=sess` 正常返回 `scode#sxh`
- 单测：新增用例 `testShortCodeStopsAtCodeLengthInsteadOfTwenty`（修复前必失败）

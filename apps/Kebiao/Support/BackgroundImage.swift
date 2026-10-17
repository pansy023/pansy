import SwiftUI
import UIKit

/// 自定义背景图（`AppSettings.backgroundImageUri`）在 iOS 侧的存取与渲染。
///
/// Android 端把这个键存成 `Uri` 字符串（相册选的 `content://…`、也可能是一个
/// `http(s)` 图片地址）。iOS 没有 `content://` 等价物：相册里的图必须先落进
/// App 沙盒才能长期引用，所以这里的分工是
/// - 相册选中的图 → 写进 `Documents/Backgrounds/background.img`，把**文件路径**写进
///   `backgroundImageUri`（键名与 Android 逐字相同，见 `TimetableStorageKeys.backgroundImageUri`）；
/// - 手动输入的 `http(s)` 地址 → 原样写进同一个键，渲染走 `AsyncImage`。
///
/// 跨平台迁移的已知限制：Android 写下的 `content://…` 在 iOS 上解析不出文件，
/// 会被当作「没有自定义背景」处理（回落到默认背景），不会崩。
///
/// 注意 `AppSettings.hasCustomBackground` 的判据是「非 nil 且非空白」
/// （`TimetableGridV2.kt:768-771`），所以清除背景图必须把该键写成 `nil`，
/// 而不是空串之外还能留下残留文件。
enum BackgroundImageStore {

    /// 沙盒里的背景图目录名。
    static let directoryName = "Backgrounds"
    /// 固定文件名：同一时刻只保留一张背景图，与 Android 的「单值 URI」语义一致。
    static let fileName = "background.img"

    /// 背景图目录（若不存在则创建）。
    static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 背景图文件的绝对路径。
    static func fileURL() throws -> URL {
        try directory().appendingPathComponent(fileName)
    }

    /// 把相册选中的图存成背景图，返回要写进 `backgroundImageUri` 的路径串。
    ///
    /// 扩展名统一为 `.img`：`UIImage(contentsOfFile:)` 按**文件头**判断格式，
    /// 不依赖扩展名，所以原样写字节最省事（也避免重编码损失画质）。
    @discardableResult
    static func save(imageData: Data) throws -> String {
        let url = try fileURL()
        try imageData.write(to: url, options: .atomic)
        return url.path
    }

    /// 删除沙盒里的背景图（「清除背景图（恢复默认）」用）。
    static func removeStoredFile() {
        guard let url = try? fileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// `backgroundImageUri` 解析结果。
    static func resolve(_ uri: String?) -> BackgroundImageSource {
        guard let uri = uri?.trimmingCharacters(in: .whitespacesAndNewlines), !uri.isEmpty else {
            return .none
        }
        // 手动输入的图片地址：只接受 http(s)，其余（含 Android 的 content://）一律
        // 视为「无法解析」→ 回落默认背景。
        if let url = URL(string: uri), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return .remote(url)
        }
        let path = URL(fileURLWithPath: uri).path
        guard FileManager.default.fileExists(atPath: path) else { return .none }
        return .localFile(URL(fileURLWithPath: path))
    }
}

/// `backgroundImageUri` 的三种解析结果。
enum BackgroundImageSource: Equatable {
    /// 没有自定义背景 → 用页面底色。
    case none
    /// 沙盒里的文件。
    case localFile(URL)
    /// 手动输入的远程地址。
    case remote(URL)
}

/// 铺在最底层的背景：默认页面底色，或用户选的自定义背景图。
///
/// 渲染规则（与原版「有自定义背景时面板 alpha 降到 0.62」配套，
/// 见 `Theme.panelColor(dark:hasCustomBackground:)`）：
/// - `.localFile` → 同步读一次沙盒文件并缓存进 `@State`（避免每次 body 求值都解码）；
/// - `.remote` → `AsyncImage`，失败或加载中回落到页面底色；
/// - `.none` / 解析失败 → 页面底色。
struct AppBackground: View {

    /// `AppSettings.backgroundImageUri` 原样传进来（不做判空外的加工）。
    let uri: String?
    /// 是否深色主题（决定回落底色）。
    let dark: Bool

    /// 沙盒图的解码结果缓存。
    @State private var localImage: UIImage?
    /// 缓存对应的文件路径（换图后靠它判断是否需要重新解码）。
    @State private var loadedPath: String?

    private var source: BackgroundImageSource { BackgroundImageStore.resolve(uri) }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 背景图是「铺底」，多出来的部分必须裁掉，否则会撑破布局。
            .clipped()
            // `.task(id:)` 在 uri 变化时重新取图；uri 没变就不重复解码。
            .task(id: uri) {
                await loadLocalImageIfNeeded()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch source {
        case .localFile:
            if let localImage {
                Image(uiImage: localImage)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback
            }

        case let .remote(url):
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    // 加载中 / 失败：先用底色顶住，不闪白。
                    fallback
                }
            }

        case .none:
            fallback
        }
    }

    private var fallback: some View {
        Theme.pageBackground(dark: dark)
    }

    /// 只在需要本地文件时读盘；其余情况把缓存清掉，避免留下上一张图。
    private func loadLocalImageIfNeeded() async {
        guard case let .localFile(url) = source else {
            localImage = nil
            loadedPath = nil
            return
        }
        guard loadedPath != url.path else { return }
        localImage = UIImage(contentsOfFile: url.path)
        loadedPath = url.path
    }
}

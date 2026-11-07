import SwiftUI
import FAPages

struct RootView: View {
    var body: some View {
        TabView {
            NavigationView { HomeScreen() }
                .tabItem { Label("首页", systemImage: "house") }

            NavigationView { BrowseScreen() }
                .tabItem { Label("浏览", systemImage: "square.grid.2x2") }

            NavigationView { SearchScreen() }
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }

            NavigationView { AccountScreen() }
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
        .accentColor(.orange)   // iOS 15 用 accentColor，不是 tint
    }
}

// MARK: - M0 占位屏
//
// 这些屏幕现在只证明「iOS 15 上能跑起来、能编译」。
// M1 会把它们换成真正的瀑布流 / 详情页。

struct HomeScreen: View {
    var body: some View {
        BrowseScreen(startURL: FAURLs.home, title: "FurAffinity")
    }
}

struct BrowsePlaceholder: View {
    var body: some View {
        PlaceholderScreen(
            title: "浏览",
            symbol: "square.grid.2x2",
            message: "排序 · 时间范围 · 类型 · 分级"
        )
        .navigationTitle("浏览")
    }
}

struct SearchPlaceholder: View {
    var body: some View {
        PlaceholderScreen(
            title: "搜索",
            symbol: "magnifyingglass",
            message: "支持标签、作者、多个条件组合"
        )
        .navigationTitle("搜索")
    }
}

struct AccountScreen: View {
    var body: some View {
        List {
            Section {
                NavigationLink("登录 FurAffinity") {
                    Text("M2 实现：WKWebView 内登录并取 cookie")
                        .foregroundColor(.secondary)
                        .padding()
                        .navigationTitle("登录")
                }
            }
            Section("关于") {
                // LabeledContent 是 iOS 16+，这里手搓
                HStack {
                    Text("版本")
                    Spacer()
                    Text(BuildInfo.version).foregroundColor(.secondary)
                }
                HStack {
                    Text("解析层")
                    Spacer()
                    Text("FAPages").foregroundColor(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("我的")
    }
}

struct PlaceholderScreen: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Text("M0 骨架 · iOS 15")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
        .padding(32)
    }
}

enum BuildInfo {
    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }
}

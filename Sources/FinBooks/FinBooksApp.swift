import SwiftUI

@main
struct FinBooksApp: App {
    @StateObject private var dataStore = DataStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(dataStore)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 800)
        .commands {
            // 文件菜单 — 刷新数据（供 AI Agent 写入后从磁盘重新加载）
            CommandGroup(after: .saveItem) {
                Button("从磁盘刷新数据") {
                    DataStore.shared.refreshFromDisk()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
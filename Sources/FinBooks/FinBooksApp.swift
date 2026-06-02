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
    }
}

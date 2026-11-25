import SwiftUI

@main
struct Scan3DApp: App {
    @StateObject private var store = ScanStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}

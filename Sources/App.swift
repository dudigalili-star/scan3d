import SwiftUI

@main
struct Scan3DApp: App {
    @StateObject private var store = ScanStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.25, green: 0.85, blue: 0.7))
        }
    }
}

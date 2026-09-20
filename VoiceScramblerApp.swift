import SwiftUI

@main
struct VoiceScramblerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 560, minHeight: 720)
        }
        .windowResizability(.contentSize)
    }
}

import SwiftUI

@main
struct llama_swiftuiApp: App {
    @StateObject private var state = LlamaState()

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
        }
    }
}

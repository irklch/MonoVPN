import SwiftUI

@main
struct MonoVPNApp: App {
    @State private var model = HomeViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HomeView(model: model)
                .preferredColorScheme(.light)
                .tint(Mono.Palette.primary)
                .task {
                    await model.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Status and connectedDate are re-read from the system on return,
                    // so the counter is correct after backgrounding.
                    if phase == .active {
                        Task { await model.sceneDidBecomeActive() }
                    }
                }
        }
    }
}

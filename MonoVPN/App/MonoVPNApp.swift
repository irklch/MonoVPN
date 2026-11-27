import SwiftUI

/// Точка входа приложения Mono VPN.
///
/// Создаёт единственную модель главного экрана, запускает её при старте,
/// принимает команды от виджета через URL и обновляет состояние при возврате
/// приложения на передний план.
@main
struct MonoVPNApp: App {
    /// Модель главного экрана; живёт всё время работы приложения.
    @State private var model = HomeViewModel()
    /// Текущая фаза сцены — нужна, чтобы заметить возврат из фона.
    @Environment(\.scenePhase) private var scenePhase

    /// Единственная сцена приложения: окно с главным экраном.
    var body: some Scene {
        WindowGroup {
            HomeView(model: model)
                .preferredColorScheme(.light)
                .tint(Mono.Palette.primary)
                .task {
                    await model.start()
                }
                .onOpenURL { url in
                    // Команда от виджета (нужна только тогда, когда VPN-конфигурацию
                    // ещё предстоит создать в приложении).
                    guard let command = TunnelCommand(url: url) else { return }
                    Task { await model.handle(command) }
                }
                .onChange(of: scenePhase) { _, phase in
                    // При возврате статус и connectedDate перечитываются из системы,
                    // поэтому счётчик времени верен и после ухода в фон.
                    if phase == .active {
                        Task { await model.sceneDidBecomeActive() }
                    }
                }
        }
    }
}

import SwiftUI

/// Монохромная палитра и размеры. Без градиентов, акцентных цветов и тяжёлых теней.
enum Mono {
    /// Цвета интерфейса.
    enum Palette {
        /// Фон экранов.
        static let background = Color.white
        /// Основной цвет текста, иконок и главной кнопки.
        static let primary = Color.black
        /// Второстепенный текст и подписи.
        static let secondary = Color(white: 0.52)
        /// Неактивные элементы и приглушённые состояния.
        static let tertiary = Color(white: 0.72)
        /// Заливка карточек, полей и второстепенных кнопок.
        static let fill = Color(white: 0.955)
        /// Разделители в списках.
        static let separator = Color(white: 0.9)
        /// Цвет содержимого поверх `primary` (текст и иконки на чёрном).
        static let onPrimary = Color.white
    }

    /// Размеры и отступы.
    enum Metrics {
        /// Горизонтальный отступ экранов от краёв.
        static let screenPadding: CGFloat = 24
        /// Радиус скругления карточек.
        static let cornerRadius: CGFloat = 22
        /// Минимальная высота кнопок и полей ввода.
        static let controlHeight: CGFloat = 54
        /// Диаметр главной кнопки подключения.
        static let connectButtonSize: CGFloat = 136
    }

    /// Анимации интерфейса.
    enum Animation {
        /// Пружинная анимация смены состояния подключения и сервера.
        static let state = SwiftUI.Animation.spring(response: 0.42, dampingFraction: 0.86)
    }
}

/// Залитая чёрная капсула — главное действие на экране.
struct PrimaryButtonStyle: ButtonStyle {
    /// Доступна ли кнопка; неактивная окрашивается в `tertiary`.
    @Environment(\.isEnabled) private var isEnabled

    /// Капсула на всю ширину; при нажатии становится полупрозрачной.
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Mono.Palette.onPrimary)
            .frame(maxWidth: .infinity, minHeight: Mono.Metrics.controlHeight)
            .background(Capsule().fill(isEnabled ? Mono.Palette.primary : Mono.Palette.tertiary))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Светло-серая капсула для второстепенных действий.
struct SecondaryButtonStyle: ButtonStyle {
    /// Доступна ли кнопка; у неактивной текст окрашивается в `tertiary`.
    @Environment(\.isEnabled) private var isEnabled

    /// Капсула на всю ширину с серой заливкой; при нажатии становится полупрозрачной.
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(isEnabled ? Mono.Palette.primary : Mono.Palette.tertiary)
            .frame(maxWidth: .infinity, minHeight: Mono.Metrics.controlHeight)
            .background(Capsule().fill(Mono.Palette.fill))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Круглая кнопка-иконка для заголовков.
struct IconButton: View {
    /// Имя символа SF Symbols.
    let systemName: String
    /// Подпись для VoiceOver (кнопка без текста).
    let accessibilityLabel: LocalizedStringKey
    /// Показывать индикатор загрузки вместо иконки.
    var isLoading = false
    /// Действие по нажатию.
    let action: () -> Void

    /// Серый круг 42×42 с иконкой или индикатором загрузки.
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Mono.Palette.fill)
                if isLoading {
                    ProgressView().tint(Mono.Palette.primary)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Mono.Palette.primary)
                }
            }
            .frame(width: 42, height: 42)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

/// Строка заголовка в верхней части модальных окон.
struct SheetHeader<Trailing: View>: View {
    /// Ключ локализации заголовка.
    let title: LocalizedStringKey
    /// Необязательные элементы справа от заголовка (например, кнопка обновления).
    @ViewBuilder var trailing: Trailing

    /// Крупный заголовок слева и `trailing` справа.
    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Mono.Palette.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.top, 28)
        .padding(.bottom, 20)
    }
}

/// Небольшая серая подпись с иконкой для ошибок и подсказок (без цветовых акцентов).
struct NoticeText: View {
    /// Имя символа SF Symbols.
    let systemName: String
    /// Текст подписи (уже локализованный).
    let text: String

    /// Иконка и многострочный текст мелким серым шрифтом.
    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemName)
        }
        .font(.footnote)
        .foregroundStyle(Mono.Palette.secondary)
    }
}

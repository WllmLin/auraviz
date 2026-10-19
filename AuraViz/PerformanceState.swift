import SwiftUI

/// Look-and-feel choices shared by the control window's preview and the
/// output window, so both always render the same visual.
final class PerformanceState: ObservableObject {
    @Published var mode: VisualMode = .circle
    @Published var theme: ColorTheme = .aurora
    @Published var circleFramesPerSecond = 30
}

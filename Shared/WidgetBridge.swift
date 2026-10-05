import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Tells WidgetKit that shared data changed.
enum WidgetBridge {
    static func reload() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

import SwiftUI

@main
struct CellarApp: App {
    var body: some Scene {
        MenuBarExtra("Cellar", image: "MenuBarIcon") {
            PanelPlaceholder()
        }
        .menuBarExtraStyle(.window)
    }
}
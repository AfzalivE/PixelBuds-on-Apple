import SwiftUI

@main
struct PixelBudsBatteryApp: App {
    @State private var store: BatteryStore

    init() {
        let store = BatteryStore()
        store.start()
        _store = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }

        #if os(macOS)
        MenuBarExtra {
            BatteryPanel(store: store)
                .padding()
                .frame(width: 300)
        } label: {
            Text(store.menuBarTitle)
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}

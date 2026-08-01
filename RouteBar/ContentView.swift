import SwiftUI

struct ContentView: View {
    var body: some View {
        MainWindowView()
    }
}

#if DEBUG && !DISABLE_PREVIEWS
#Preview {
    ContentView()
        .environmentObject(AppModel())
        .environmentObject(RuntimeLog.shared)
}
#endif

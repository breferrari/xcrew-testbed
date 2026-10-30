import SwiftUI

/// The plan the test plan's configuration names, passed on by the UI test.
let plan = ProcessInfo.processInfo.environment["PLAN"] ?? "A"

struct ContentView: View {
    @State private var steps = 0

    var body: some View {
        VStack {
            Text(steps == 0 ? "Welcome" : "Done").accessibilityIdentifier("title")
            Text("Plan \(plan)").accessibilityIdentifier("plan")
            Button("Continue") { steps += 1 }.accessibilityIdentifier("continue")
        }
    }
}

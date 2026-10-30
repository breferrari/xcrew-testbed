import Feature
import SwiftUI

@main
struct FieldApp: SwiftUI.App {
    var body: some Scene {
        WindowGroup {
            Text(Greeting(name: "Ada").hello).accessibilityIdentifier("greeting")
        }
    }
}

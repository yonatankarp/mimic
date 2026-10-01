import SwiftUI

/// Why Make or Resize can't start, with a way to Settings when the reason is the setup
/// rather than a job already running.
struct CantStart: View {
    @Environment(AppModel.self) private var model
    let reason: String
    var body: some View {
        Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        if model.requiredProblem != nil { OpenSettingsButton(tab: .general) { Text("Open Settings") } }
    }
}

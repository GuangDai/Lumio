import SwiftUI

struct TerminalSettingsSection: View {
    @State private var choice = TerminalApp.choice
    @State private var options = TerminalApp.options()
    @State private var saveFailed = false

    var body: some View {
        SettingsRow(
            "Terminal app", icon: "terminal",
            detail: "Used by Open in Terminal and ⌘T"
        ) {
            Picker("Terminal app", selection: Binding(
                get: { choice },
                set: { app in
                    saveFailed = !TerminalApp.setChoice(app)
                    if !saveFailed {
                        choice = app
                        options = TerminalApp.options()
                    }
                }
            )) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        } below: {
            if saveFailed {
                Text("Couldn't save the terminal selection.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear {
            choice = TerminalApp.choice
            options = TerminalApp.options()
        }
    }
}

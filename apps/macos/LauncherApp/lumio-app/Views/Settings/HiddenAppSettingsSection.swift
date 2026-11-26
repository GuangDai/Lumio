import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HiddenApplicationSettingsRow: View {
    @State private var selection: Selection?
    @State private var error: String?

    private nonisolated struct Selection: Identifiable, Sendable {
        let id = UUID()
        let names: [String]
    }

    var body: some View {
        SettingsRow("Hidden applications", icon: "eye.slash", detail: error ?? "Choose apps to hide from search results") {
            Button("Choose Apps…") {
                guard let names = AppExcludeWriter.excludedNames() else {
                    error = "Couldn't read the config file"
                    return
                }
                error = nil
                selection = Selection(names: names)
            }
        }
        .sheet(item: $selection) { selection in
            HiddenApplicationPicker(names: selection.names)
        }
    }
}

private struct HiddenApplicationPicker: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var applications: [AppBundleLocator.Application] = []
    @State private var names: [String]
    @State private var query = ""
    @State private var hiddenOnly = false
    @State private var isLoading = true
    @State private var saveError: String?

    private let originalNames: [String]

    init(names: [String]) {
        originalNames = names
        _names = State(initialValue: names)
    }

    var body: some View {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hidden = Set(names.map(AppExcludeWriter.normalize))
        let visible = applications.filter { app in
            app.matches(needle) && (!hiddenOnly || !hidden.isDisjoint(with: ruleKeys(for: app)))
        }
        let recognized = Set(applications.flatMap { ruleKeys(for: $0) })
        let otherNames = Set(names).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.filter { name in
            !recognized.contains(AppExcludeWriter.normalize(name)) && (needle.isEmpty || name.localizedStandardContains(needle))
        }

        VStack(alignment: .leading, spacing: 12) {
            Text("Hidden Applications")
                .font(.headline)
            TextField("Search applications", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            Picker("Application filter", selection: $hiddenOnly) {
                Text("All Apps").tag(false)
                Text("Hidden").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            List {
                ForEach(visible) { app in
                    let keys = ruleKeys(for: app)
                    appToggle(app.name, path: app.path, keys: keys, nameToHide: app.bundleName)
                }
                ForEach(otherNames, id: \.self) { name in
                    appToggle(name, path: nil, keys: [AppExcludeWriter.normalize(name)], nameToHide: name)
                }
            }
            .listStyle(.inset)
            .overlay {
                if isLoading && visible.isEmpty && otherNames.isEmpty {
                    ProgressView("Finding applications…")
                } else if visible.isEmpty && otherNames.isEmpty {
                    Text(hiddenOnly && needle.isEmpty ? "No hidden applications" : "No applications match")
                        .foregroundStyle(.secondary)
                }
            }

            if let saveError {
                Text(saveError)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Choose Other Apps…", action: chooseAppBundles)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(hidden == Set(originalNames.map(AppExcludeWriter.normalize)))
            }
        }
        .padding(16)
        .frame(minWidth: 440, idealWidth: 490, minHeight: 400, idealHeight: 520)
        .onAppear { searchFocused = true }
        .onExitCommand { dismiss() }
        .task { await loadApplications() }
    }

    private func ruleKeys(for app: AppBundleLocator.Application) -> Set<String> {
        [app.id, AppExcludeWriter.normalize(app.name)]
    }

    private func appToggle(_ name: String, path: String?, keys: Set<String>, nameToHide: String) -> some View {
        Toggle(isOn: Binding(
            get: { names.contains { keys.contains(AppExcludeWriter.normalize($0)) } },
            set: { hidden in
                saveError = nil
                if hidden {
                    names.append(nameToHide)
                } else {
                    names.removeAll { keys.contains(AppExcludeWriter.normalize($0)) }
                }
            }
        )) {
            Label {
                Text(name)
                    .lineLimit(1)
            } icon: {
                Group {
                    if let path {
                        Image(nsImage: RowIconCache.icon(forFile: path))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "app")
                    }
                }
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            }
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel("Hide \(name)")
    }

    private func loadApplications() async {
        let settings = AppExcludeWriter.appScanSettings()
        let scan = Task.detached(priority: .userInitiated) {
            AppBundleLocator.installedApplications(additionalRoots: settings.roots, depth: settings.depth)
        }
        let installed = await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
        guard !Task.isCancelled else { return }
        applications = installed
        isLoading = false
    }

    private func chooseAppBundles() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose Apps"
        guard panel.runModal() == .OK else { return }
        var hidden = Set(names.map(AppExcludeWriter.normalize))
        for app in panel.urls.compactMap({ AppBundleLocator.application(at: $0) }) {
            if hidden.isDisjoint(with: ruleKeys(for: app)), hidden.insert(app.id).inserted {
                names.append(app.bundleName)
            }
        }
        query = ""
        hiddenOnly = true
        saveError = nil
    }

    private func apply() {
        guard AppExcludeWriter.save(names, replacing: originalNames) != nil else {
            saveError = "Couldn't save hidden applications"
            return
        }
        NotificationCenter.default.post(name: .lookReloadConfigRequested, object: nil)
        dismiss()
    }
}

import MimicCore
import SwiftUI

/// Describe it's ✨ box: asks the AI helper for a fuller description and shows it for editing.
/// Shows nothing while no helper is chosen, so Describe it stays as it always was.
struct ImproveBox: View {
    /// What the person typed.
    let description: String
    /// What the mini is (MiniKind's raw value): the helper writes for a character or an object.
    var kind = "character"
    /// The improved text; nil means the person's own description is used.
    @Binding var improved: String?
    @AppStorage(HelperConfig.providerKey) private var provider = HelperProvider.off.rawValue
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        if provider != HelperProvider.off.rawValue {
            if improved != nil {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("✨ Improved description").font(.headline)
                        Spacer()
                        Button("Use Mine Instead") { improved = nil }
                            .help("Go back to the description you wrote. The improved one is dropped.")
                    }
                    TextEditor(text: Binding(get: { improved ?? "" }, set: { improved = $0 }))
                        .frame(minHeight: 90)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.4)))
                        .accessibilityLabel("Improved description")
                    Text("Make My Mini draws from this one. Change anything you like.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Button("✨ Improve Description") { improve() }
                        .disabled(working || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("The AI helper chosen in Settings writes a fuller description of your character. You can edit it or go back to yours.")
                    if working { ProgressView().controlSize(.small) }
                    if let problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func improve() {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines), kind = kind
        working = true
        problem = nil
        Task {
            // Off the main thread: reading the key may wait on a Keychain prompt after an update.
            let result = await Task.detached {
                Result { try (DescriptionHelper.configured(defaults: .standard) ?? { throw HelperError.off }()).improve(text, kind: kind) }
            }.value
            working = false
            switch result {
            case .success(let better): improved = better
            case .failure(let error): problem = "\(error) Your own description still works."
            }
        }
    }
}

/// Settings → AI helper for descriptions: which provider, its key, model and address, and a Test.
struct HelperSection: View {
    @AppStorage(HelperConfig.providerKey) private var provider = HelperProvider.off.rawValue
    @AppStorage(HelperConfig.modelKey) private var model = ""
    @AppStorage(HelperConfig.urlKey) private var address = ""
    @State private var keyText = ""
    @State private var hasKey = false
    @State private var ollamaModels: [String] = []
    @State private var ollamaProblem: String?
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    private var current: HelperProvider { HelperProvider(rawValue: provider) ?? .off }

    var body: some View {
        Section {
            Picker("Helper", selection: $provider) {
                Text("Off").tag(HelperProvider.off.rawValue)
                Text("Claude (Anthropic)").tag(HelperProvider.anthropic.rawValue)
                Text("OpenAI-compatible service").tag(HelperProvider.openai.rawValue)
                Text("Ollama, on this Mac").tag(HelperProvider.ollama.rawValue)
            }
            .help("Writes a fuller description of your character from a few words, in ✍️ Describe it.")
            if current.isCloud { keyRow }
            if current == .openai {
                TextField("Service address", text: $address, prompt: Text(HelperProvider.openai.defaultURL))
                    .help("The service's API address. Leave blank for OpenAI; other services list theirs in their documentation.")
            }
            if current == .ollama { ollamaRow }
            if current != .off && current != .ollama {
                TextField("Model", text: $model, prompt: Text(current.defaultModel.isEmpty ? "e.g. the model's name from the service" : current.defaultModel))
                    .help(current == .anthropic ? "Blank uses Claude Haiku 4.5: quick and inexpensive for this." : "The model's name, as the service writes it.")
            }
            if current != .off {
                HStack(alignment: .firstTextBaseline) {
                    Button("Test") { test() }.disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult {
                        Text(testResult.ok ? "✅ \(testResult.text)" : testResult.text)
                            .font(.callout).foregroundStyle(testResult.ok ? Color.primary : .red)
                    }
                }
            }
        } header: {
            Text("AI helper for descriptions")
        } footer: {
            Text(current == .ollama
                 ? "Optional. Ollama runs on this Mac, so your descriptions stay here."
                 : "Optional. Cloud services receive only the description you type, nothing else. Keys are kept in your Mac's Keychain.")
                .foregroundStyle(.secondary)
        }
        .onChange(of: provider) { _, _ in model = ""; address = ""; testResult = nil; load() }
        .task { load() }
    }

    private var keyRow: some View {
        HStack {
            if hasKey {
                Label("API key saved in your Keychain", systemImage: "key.fill")
                Spacer()
                Button("Remove") {
                    Keychain.delete(account: provider)
                    hasKey = false
                    testResult = nil
                }
            } else {
                SecureField("API key", text: $keyText, prompt: Text("Paste your key"))
                    .onSubmit(saveKey)
                Button("Save", action: saveKey).disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var ollamaRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("Model", selection: $model) {
                    if !ollamaModels.contains(model) { Text(model.isEmpty ? "Choose…" : model).tag(model) }
                    ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
                }
                Button("Refresh") { load() }
            }
            if let ollamaProblem { Text(ollamaProblem).font(.callout).foregroundStyle(.secondary) }
            // Small models add glow and props the prompt rules out; a bigger one installed here does better.
            if let better = DescriptionHelper.recommendedOllama(ollamaModels), better != model {
                HStack {
                    Text("💡 \(better) is installed and follows the instructions better. It takes a few seconds longer.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Use It") { model = better }
                }
            }
        }
    }

    private func saveKey() {
        let key = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try Keychain.save(key, account: provider)
            keyText = ""
            hasKey = true
            testResult = nil
        } catch {
            testResult = (false, "\(error)")
        }
    }

    private func load() {
        hasKey = current.isCloud && Keychain.has(account: provider)
        guard current == .ollama else { return }
        Task {
            let result = await Task.detached { Result { try DescriptionHelper.ollamaModels() } }.value
            switch result {
            case .success(let names):
                ollamaModels = names
                ollamaProblem = names.isEmpty ? "No models installed yet. In Terminal: ollama pull gemma3" : nil
                if model.isEmpty, let first = names.first { model = DescriptionHelper.recommendedOllama(names) ?? first }
            case .failure(let error):
                ollamaModels = []
                ollamaProblem = "\(error)"
            }
        }
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            let result = await Task.detached {
                Result { try (DescriptionHelper.configured(defaults: .standard) ?? { throw HelperError.off }()).test() }
            }.value
            testing = false
            switch result {
            case .success: testResult = (true, "It works.")
            case .failure(let error): testResult = (false, "\(error)")
            }
        }
    }
}

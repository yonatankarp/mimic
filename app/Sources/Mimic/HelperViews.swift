import MimicCore
import SwiftUI

/// Description's Improve box: asks the AI helper for a fuller description and shows it for editing.
/// Shows nothing while no helper is chosen, so Description stays as it always was.
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
                        Label("Improved description", systemImage: "sparkles").font(.headline)
                        Spacer()
                        Button("Use Original") { improved = nil }
                            .help("Go back to the description you wrote")
                    }
                    TextEditor(text: Binding(get: { improved ?? "" }, set: { improved = $0 }))
                        .frame(minHeight: 90)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.4)))
                        .accessibilityLabel("Improved description")
                    Text("Make Mini draws from this one. Change anything you like.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Button("Improve Description", systemImage: "sparkles") { improve() }.labelStyle(.titleAndIcon)
                        .disabled(working || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("The AI helper writes a fuller description you can edit")
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
    /// What Improve reads, so the key is saved under the account it looks for.
    private var config: HelperConfig { HelperConfig.load(.standard) }

    /// A key is only sent to the address it was saved for, so an address that isn't the provider's
    /// own is named here, whoever set it.
    private var addressNote: String? {
        guard current.isCloud, !config.isDefaultHost else { return nil }
        guard let host = config.host, config.isSecure else { return "\(HelperError.badURL)" }
        return "Set to \(host). Keys are kept per address: one saved here is only sent to \(host)."
    }

    var body: some View {
        Section {
            Picker("Helper", selection: $provider) {
                Text("Off").tag(HelperProvider.off.rawValue)
                Text("Claude (Anthropic)").tag(HelperProvider.anthropic.rawValue)
                Text("OpenAI-compatible service").tag(HelperProvider.openai.rawValue)
                Text("Ollama, on this Mac").tag(HelperProvider.ollama.rawValue)
            }
            .help("Writes a fuller description from a few words, in New Mini")
            if current.isCloud { keyRow }
            if current == .openai {
                TextField("Service address", text: $address, prompt: Text(HelperProvider.openai.defaultURL))
                    .help("The service's API address; leave blank for OpenAI")
            }
            if let addressNote { Text(addressNote).font(.callout).foregroundStyle(.secondary) }
            if current == .ollama { ollamaRow }
            if current != .off && current != .ollama {
                TextField("Model", text: $model, prompt: Text(current.defaultModel.isEmpty ? "e.g. the model's name from the service" : current.defaultModel))
                    .help(current == .anthropic ? "Blank uses Claude Haiku 4.5: quick and inexpensive" : "The model's name, as the service writes it")
            }
            if current != .off {
                HStack(alignment: .firstTextBaseline) {
                    Button("Test") { test() }.disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult {
                        Label(testResult.text, systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.callout).foregroundStyle(testResult.ok ? Color.primary : .red)
                    }
                }
            }
        } header: {
            Text("AI helper for descriptions")
        } footer: {
            Text(current == .ollama
                 ? "Optional. Ollama runs on this Mac, so what you type stays here."
                 : "Optional. A cloud helper receives only what you type: a description, or what to change in a picture, never the picture itself. Keys are kept in your Mac's Keychain.")
                .foregroundStyle(.secondary)
        }
        .onChange(of: provider) { _, _ in model = ""; address = ""; testResult = nil; load() }
        .onChange(of: address) { _, _ in testResult = nil; load() }
        .task { load() }
    }

    private var keyRow: some View {
        HStack {
            if hasKey {
                Label("API key saved in your Keychain", systemImage: "key.fill")
                Spacer()
                Button("Remove") {
                    if let account = config.keyAccount { Keychain.delete(account: account) }
                    hasKey = false
                    testResult = nil
                }
            } else {
                SecureField("API key", text: $keyText, prompt: Text("Paste your key"))
                    .onSubmit(saveKey)
                Button("Save", action: saveKey).disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty || config.keyAccount == nil)
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
                    Label("\(better) is installed and follows the instructions better. It takes a few seconds longer.", systemImage: "lightbulb")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Use It") { model = better }
                }
            }
        }
    }

    private func saveKey() {
        let key = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let account = config.keyAccount else { return }
        do {
            try Keychain.save(key, account: account)
            keyText = ""
            hasKey = true
            testResult = nil
        } catch {
            testResult = (false, "\(error)")
        }
    }

    private func load() {
        hasKey = config.keyAccount.map { Keychain.has(account: $0) } ?? false
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

/// Settings → Pictures (#247): Draw Things on this Mac, or Black Forest Labs online with the
/// person's own key, kept in the Keychain like the helper's.
struct PicturesSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ImageService.key) private var service = ImageService.drawThings.rawValue
    @State private var keyText = ""
    @State private var hasKey = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    private var online: Bool { service == ImageService.bfl.rawValue }

    var body: some View {
        Section {
            Picker("Make pictures with", selection: $service) {
                Text("Draw Things, on this Mac").tag(ImageService.drawThings.rawValue)
                Text("Black Forest Labs, online").tag(ImageService.bfl.rawValue)
            }
            .help("What draws a character from a description and turns a picture into a grey sculpt")
            if online {
                HStack {
                    if hasKey {
                        Label("API key saved in your Keychain", systemImage: "key.fill")
                        Spacer()
                        Button("Remove") {
                            Keychain.delete(account: OnlineImages.keyAccount)
                            hasKey = false
                            changed()
                        }
                    } else {
                        SecureField("API key", text: $keyText, prompt: Text("Paste your key"))
                            .onSubmit(saveKey)
                        Button("Save", action: saveKey).disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Button("Test") { test() }.disabled(testing || !hasKey)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult {
                        Label(testResult.text, systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.callout).foregroundStyle(testResult.ok ? Color.primary : .red)
                    }
                    Spacer()
                    Link("Get a key", destination: URL(string: "https://dashboard.bfl.ai")!)
                }
            }
        } header: {
            Text("Pictures")
        } footer: {
            Text(online
                 ? "Your description, or the picture to redraw, is sent to Black Forest Labs. Each picture Mimic draws or redraws is one paid request on your account: one for a description or a grey sculpt, plus one for each side picture it redraws. A picture used as it is costs nothing. The key is kept in your Mac's Keychain."
                 : "Draw Things makes the pictures on this Mac, so nothing is sent anywhere.")
                .foregroundStyle(.secondary)
        }
        .onChange(of: service) { _, _ in changed() }
        .task { hasKey = Keychain.has(account: OnlineImages.keyAccount) }
    }

    /// The checks follow the choice and the key: Needs Setup, New Mini and this tab.
    private func changed() {
        testResult = nil
        if !model.running { Health.shared.check(model.install) }
    }

    private func saveKey() {
        let key = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try Keychain.save(key, account: OnlineImages.keyAccount)
            keyText = ""
            hasKey = true
            changed()
        } catch {
            testResult = (false, "\(error)")
        }
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            // Off the main thread: reading the key may wait on a Keychain prompt after an update.
            let result = await Task.detached {
                Result { try OnlineImages { Keychain.read(account: OnlineImages.keyAccount) }.check() }
            }.value
            testing = false
            switch result {
            case .success: testResult = (true, "It works.")
            case .failure(let error): testResult = (false, "\(error)")
            }
        }
    }
}

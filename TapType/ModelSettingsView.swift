import SwiftUI

struct ModelSettingsView: View {
    @ObservedObject private var apple = AppleSpeechAssets.shared
    @ObservedObject private var store = ModelStore.shared
    @AppStorage("speechProvider") private var speechProvider = "apple"
    @AppStorage("writingProvider") private var writingProvider = "apple"
    @AppStorage("cleanupMode") private var cleanupMode = CleanupMode.cleanup.rawValue
    @Binding var cloud: Bool
    @State private var configured = Set(CloudProvider.allCases.filter { (try? ProviderKeys.read($0)) != nil })
    let busy: Bool
    var body: some View {
        Section {
            Picker("Speech", selection: $speechProvider) {
                ForEach(SpeechProvider.allCases.filter { $0.downloaded ? store.installed.contains($0.rawValue) : $0.cloud.map { configured.contains($0) } ?? true }) { provider in
                    Text(provider.modelName).lineLimit(1).tag(provider.rawValue)
                        .disabled(provider.downloaded ? !store.installed.contains(provider.rawValue) : provider.cloud.map { !configured.contains($0) } ?? false)
                }
            }
            Picker("Your words", selection: $cleanupMode) {
                ForEach(CleanupMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            if cleanupMode != "original" {
                Picker("Writing", selection: $writingProvider) {
                    ForEach(WritingProvider.allCases.filter { $0.cloud.map { configured.contains($0) } ?? true }) { provider in
                        Text(provider.cloud?.writingModel ?? "Apple").tag(provider.rawValue)
                            .disabled(provider.cloud.map { !configured.contains($0) } ?? false)
                    }
                }
            }
            DisclosureGroup("On-device models") {
                HStack {
                    Text("Apple Speech")
                    Spacer()
                    if apple.downloading { ProgressView(); Button("Cancel") { apple.cancel() } }
                    else if !apple.installed { Button("Get") { apple.download() } }
                    else { Text("Ready").foregroundStyle(.secondary) }
                }.font(.subheadline)
                if let notice = apple.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                ForEach(store.models) { model in
                    HStack(spacing: 8) {
                        Button(model.name.replacingOccurrences(of: " · English", with: "")) { speechProvider = model.id }
                            .disabled(!store.installed.contains(model.id))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if store.downloading == model.id {
                            ProgressView(value: store.fraction).frame(width: 40)
                            Button("Cancel") { store.cancelDownload() }
                        } else if store.installed.contains(model.id) {
                            Button("Uninstall", role: .destructive) { store.remove(model.id) }
                        } else {
                            Button("Get · " + model.size) { store.download(model) }.disabled(store.downloading != nil)
                        }
                    }.font(.subheadline).buttonStyle(.borderless)
                }
                if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }
            Button { cloud = true } label: {
                HStack {
                    Text("Cloud providers")
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                }.contentShape(Rectangle())
            }
        } footer: {
            if SpeechProvider(rawValue: speechProvider)?.cloud != nil || (cleanupMode != "original" && writingProvider != "apple") {
                Text("Completed phrases are sent while you speak. Cloud provider charges apply.")
            } else { Text("Speech and cleanup stay on this iPhone.") }
        }
        .pickerStyle(.menu)
        .disabled(busy || store.inUse)
        .onAppear(perform: refreshConfigured)
        .task { await apple.refresh() }
        .onChange(of: cloud) { _, presented in if !presented { refreshConfigured() } }
    }
    private func refreshConfigured() {
        configured = Set(CloudProvider.allCases.filter { (try? ProviderKeys.read($0)) != nil })
        if let provider = SpeechProvider(rawValue: speechProvider),
           provider.downloaded ? !store.installed.contains(provider.rawValue) : provider.cloud.map({ !configured.contains($0) }) ?? false {
            speechProvider = "apple"
        }
        if let provider = WritingProvider(rawValue: writingProvider)?.cloud, !configured.contains(provider) { writingProvider = "apple" }
    }

}

struct CloudSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var provider = CloudProvider.openAI
    @State private var key = ""
    @State private var speechModel = CloudProvider.openAI.speechModel
    @State private var writingModel = CloudProvider.openAI.writingModel
    @State private var hasKey = (try? ProviderKeys.read(.openAI)) != nil
    @State private var notice: String?
    @State private var testing = false
    @State private var drafts: [CloudProvider: CloudSettingsDraft] = [:]
    @State private var testTask: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                Picker("Provider", selection: $provider) { ForEach(CloudProvider.allCases) { Text($0.title).tag($0) } }
                Section {
                    SecureField(hasKey ? "Replace saved API key" : "API key", text: $key)
                        .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if hasKey {
                        Button(testing ? "Checking…" : "Test connection") {
                            testing = true; notice = nil
                            let selected = provider
                            testTask = Task {
                                defer { testing = false }
                                do {
                                    _ = try await CloudModels.test(selected)
                                    if !Task.isCancelled { notice = "Connected. Model access depends on your account." }
                                } catch { if !Task.isCancelled { notice = error.localizedDescription } }
                            }
                        }
                        Button("Remove key", role: .destructive) {
                            do { try ProviderKeys.remove(provider); hasKey = false; key = ""; notice = "Key removed." }
                            catch { notice = error.localizedDescription }
                        }
                    }
                } footer: { Text("Keys stay in this iPhone’s Keychain. Testing checks your account without sending audio or text.") }
                Section("Models") {
                    TextField("Speech model", text: $speechModel)
                    TextField("Writing model", text: $writingModel)
                }.textInputAutocapitalization(.never).autocorrectionDisabled()
                if let notice { Section { Text(notice).font(.subheadline).foregroundStyle(.secondary) } }
                Section { Text("Choose this provider on the home screen to use it. Your provider’s privacy terms and API charges apply.").font(.caption).foregroundStyle(.secondary) }
            }
            .disabled(testing)
            .navigationTitle("Cloud providers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Back") { dismiss() }.disabled(testing) }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { saveAndClose() }.disabled(testing) }
            }
            .interactiveDismissDisabled(!key.isEmpty || !drafts.isEmpty || speechModel != provider.speechModel || writingModel != provider.writingModel)
            .onChange(of: provider) { old, value in
                drafts[old] = CloudSettingsDraft(key: key, speech: speechModel, writing: writingModel)
                let draft = drafts[value] ?? CloudSettingsDraft(key: "", speech: value.speechModel, writing: value.writingModel)
                key = draft.key; speechModel = draft.speech; writingModel = draft.writing
                hasKey = (try? ProviderKeys.read(value)) != nil; notice = nil
            }
            .onDisappear { testTask?.cancel(); key = "" }
        }.preferredColorScheme(.dark)
    }
    private func saveAndClose() {
        drafts[provider] = CloudSettingsDraft(key: key, speech: speechModel, writing: writingModel)
        do {
            for draft in drafts.values { try draft.validate() }
            for (provider, draft) in drafts {
                if !draft.key.isEmpty { try ProviderKeys.save(draft.key, for: provider) }
                UserDefaults.standard.set(draft.speech.trimmingCharacters(in: .whitespacesAndNewlines), forKey: provider.rawValue + "SpeechModel")
                UserDefaults.standard.set(draft.writing.trimmingCharacters(in: .whitespacesAndNewlines), forKey: provider.rawValue + "WritingModel")
            }
            key = ""; drafts = [:]; dismiss()
        } catch { notice = error.localizedDescription }
    }

}


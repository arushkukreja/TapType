import SwiftUI

struct CloudModelUsage: Codable, Hashable, Identifiable {
    let provider: String
    let model: String
    let writing: Bool
    var id: String { provider + ":" + (writing ? "writing:" : "speech:") + model }
    var title: String { CloudProvider(rawValue: provider)?.title ?? provider }
    var kind: String { writing ? "Writing" : "Speech" }
}

struct CloudRate: Codable, Equatable {
    // Speech: input is USD/minute. Writing: all values are USD/million tokens.
    let input: Double
    let output: Double
    let cached: Double
    var valid: Bool { [input, output, cached].allSatisfy { $0.isFinite && (0...1_000_000).contains($0) } }
    static func published(_ model: CloudModelUsage) -> Self? {
        // Verified 2026-11-08 against the official rate pages linked in CloudUsageView.
        switch (model.provider, model.model, model.writing) {
        case ("openAI", "gpt-live-transcribe", false): return .init(input: 0.017, output: 0, cached: 0)
        case ("openAI", "gpt-transcribe", false): return .init(input: 0.0045, output: 0, cached: 0)
        case ("openAI", "gpt-4o-transcribe", false): return .init(input: 0.006, output: 0, cached: 0)
        case ("openAI", "gpt-4o-mini-transcribe", false): return .init(input: 0.003, output: 0, cached: 0)
        case ("openAI", "gpt-6-luna", true): return .init(input: 0.1, output: 0.5, cached: 0.01)
        case ("openAI", "gpt-4.1-mini", true), ("openAI", "gpt-4.1-mini-2025-04-14", true):
            return .init(input: 0.4, output: 1.6, cached: 0.1)
        case ("groq", "whisper-large-v3-turbo", false): return .init(input: 0.04 / 60, output: 0, cached: 0)
        case ("groq", "whisper-large-v3", false): return .init(input: 0.111 / 60, output: 0, cached: 0)
        // Enterprise/custom models need the user's account rate; never assume they are free.
        default: return nil
        }
    }
}

struct CloudUsageEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let model: CloudModelUsage
    var seconds: Double?
    var streamed: Bool? = nil
    var purpose: String? = nil
    var rate: CloudRate?
    var confirmed = false
    var inputTokens: Int?
    var outputTokens: Int?
    var cachedTokens: Int?
    var usd: Double? {
        guard confirmed || streamed == true, let rate, rate.valid else { return nil }
        if !model.writing {
            guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
            let minimum = model.provider == "groq" ? 10.0 : 0
            return max(minimum, seconds) / 60 * rate.input
        }
        guard let inputTokens, let outputTokens, let cachedTokens,
              (0...1_000_000_000).contains(inputTokens), (0...1_000_000_000).contains(outputTokens),
              (0...inputTokens).contains(cachedTokens) else { return nil }
        return (Double(inputTokens - cachedTokens) * rate.input + Double(cachedTokens) * rate.cached + Double(outputTokens) * rate.output) / 1_000_000
    }
}

@MainActor
final class CloudUsageStore: ObservableObject {
    static let shared = CloudUsageStore()
    @Published private(set) var entries: [CloudUsageEntry] = []
    @Published private(set) var rates: [String: CloudRate] = [:]
    @Published private(set) var notice: String?
    private let file: URL
    private var readable = true
    private struct Saved: Codable { let entries: [CloudUsageEntry]; let rates: [String: CloudRate] }
    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloudUsage/usage.json")
        guard FileManager.default.fileExists(atPath: self.file.path) else { return }
        do {
            let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: self.file))
            entries = saved.entries; rates = saved.rates
        } catch {
            readable = false
            notice = "Saved cloud usage couldn’t be opened. Its file has been kept; new usage cannot be saved yet."
        }
    }
    func rate(for model: CloudModelUsage) -> CloudRate? { rates[model.id] ?? CloudRate.published(model) }
    func begin(_ model: CloudModelUsage, seconds: Double? = nil) -> UUID {
        let id = UUID()
        entries.append(.init(id: id, date: Date(), model: model, seconds: seconds, rate: rate(for: model)))
        persist()
        return id
    }
    func complete(_ id: UUID, data: Data) {
        guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].confirmed else { return }
        entries[index].confirmed = true
        struct Response: Decodable {
            let usage: Usage?
            struct Usage: Decodable {
                let prompt_tokens: Int?
                let completion_tokens: Int?
                let prompt_tokens_details: Details?
                struct Details: Decodable { let cached_tokens: Int? }
            }
        }
        if let usage = (try? JSONDecoder().decode(Response.self, from: data))?.usage {
            entries[index].inputTokens = usage.prompt_tokens
            entries[index].outputTokens = usage.completion_tokens
            entries[index].cachedTokens = usage.prompt_tokens_details?.cached_tokens ?? 0
        }
        persist()
    }
    func markPurpose(_ id: UUID, _ purpose: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].purpose = purpose; persist()
    }
    func streamAudio(_ id: UUID, seconds: Double) {
        guard seconds.isFinite, seconds >= 0, seconds <= 60,
              let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let previous = entries[index].seconds ?? 0
        entries[index].seconds = max(previous, seconds)
        entries[index].streamed = true
        // Persist each whole second; the final/cancel path always flushes the exact total.
        if previous == 0 || Int(previous) != Int(seconds) { persist() }
    }
    @discardableResult
    func setRate(_ rate: CloudRate, for model: CloudModelUsage) -> Bool {
        guard rate.valid else { notice = "Enter nonnegative rates up to 1,000,000."; return false }
        rates[model.id] = rate
        // Preserve priced history; fill only requests that had no known rate.
        for index in entries.indices where entries[index].model == model && entries[index].rate == nil {
            entries[index].rate = rate
        }
        return persist()
    }
    @discardableResult
    private func persist() -> Bool {
        guard readable else { return false }
        do {
            var directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            try JSONEncoder().encode(Saved(entries: entries, rates: rates)).write(to: file,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            notice = nil
            return true
        } catch { notice = "Cloud usage couldn’t be saved. Check your iPhone’s storage."; return false }
    }
    static func total(_ entries: [CloudUsageEntry]) -> Double { entries.compactMap(\.usd).reduce(0, +) }
    static func money(_ value: Double) -> String { value.formatted(.currency(code: "USD").precision(.fractionLength(2...6))) }
    var models: [CloudModelUsage] {
        var models = Set(entries.map(\.model))
        for provider in CloudProvider.allCases {
            models.insert(.init(provider: provider.rawValue, model: provider.speechModel, writing: false))
            models.insert(.init(provider: provider.rawValue, model: provider.writingModel, writing: true))
        }
        return models.sorted { $0.id < $1.id }
    }
}

struct CloudUsageView: View {
    @ObservedObject private var store = CloudUsageStore.shared
    private var month: [CloudUsageEntry] {
        store.entries.filter { Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .month) }
    }
    var body: some View {
        List {
            Section {
                VStack(spacing: 4) {
                    Text(CloudUsageStore.money(CloudUsageStore.total(store.entries))).font(.largeTitle.bold()).monospacedDigit()
                    Text("Estimated total · USD").font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 5)
                LabeledContent("This month", value: CloudUsageStore.money(CloudUsageStore.total(month)))
                LabeledContent("Requests", value: store.entries.count.formatted())
            } footer: {
                Text("TapType usage on this device. Streaming estimates include sent audio even if cancelled. Cleanup preparation is included. Your provider’s bill may differ.")
            }
            if store.entries.contains(where: { $0.usd == nil }) {
                Section {
                    Text("\(store.entries.filter { $0.usd == nil }.count) requests have no estimate and are excluded from totals.").font(.subheadline)
                }
            }
            Section("Models & rates") {
                ForEach(store.models) { model in
                    NavigationLink { CloudRateView(model: model) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.model).lineLimit(1)
                            Text("\(model.title) · \(model.kind) · \(CloudUsageStore.money(CloudUsageStore.total(store.entries.filter { $0.model == model })))\(store.rate(for: model) == nil ? " · Rate needed" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Link("OpenAI pricing", destination: URL(string: "https://developers.openai.com/api/docs/pricing")!)
                Link("Groq pricing", destination: URL(string: "https://console.groq.com/docs/models")!)
            } footer: { Text("Published rates checked November 8, 2026. Speech uses audio duration; writing uses returned token counts. No audio, text, or keys are stored in usage history.") }
            if let notice = store.notice { Text(notice).foregroundStyle(.secondary) }
        }
        .contentMargins(.top, 8, for: .scrollContent)
        .navigationTitle("Cloud usage").navigationBarTitleDisplayMode(.inline)
    }
}

private struct CloudRateView: View {
    let model: CloudModelUsage
    @ObservedObject private var store = CloudUsageStore.shared
    @State private var input = ""
    @State private var output = ""
    @State private var cached = ""
    @State private var message: String?
    private var entries: [CloudUsageEntry] { store.entries.filter { $0.model == model } }
    var body: some View {
        Form {
            Section {
                Text(model.model).textSelection(.enabled)
                LabeledContent("Estimated total", value: CloudUsageStore.money(CloudUsageStore.total(entries)))
                LabeledContent("Requests", value: entries.count.formatted())
            }
            Section {
                rateField(model.writing ? "Input" : "Audio", text: $input)
                if model.writing {
                    rateField("Output", text: $output)
                    rateField("Cached input", text: $cached)
                }
                Button("Save rate") {
                    let locale = Locale.current
                    func parse(_ text: String) -> Double? {
                        let text = text.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty, text.allSatisfy({ $0.isNumber || String($0) == locale.decimalSeparator }) else { return nil }
                        return Double(text.replacingOccurrences(of: locale.decimalSeparator ?? ".", with: "."))
                    }
                    guard let i = parse(input), let o = model.writing ? parse(output) : 0,
                          let c = model.writing ? parse(cached) : 0,
                          CloudRate(input: i, output: o, cached: c).valid else {
                        message = "Enter valid nonnegative rates for each field."; return
                    }
                    message = store.setRate(.init(input: i, output: o, cached: c), for: model)
                        ? "Rate saved." : store.notice
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            } header: { Text(model.writing ? "USD per million tokens" : "USD per minute") } footer: {
                Text("Use your account’s rates. Changes apply to future requests and requests without a rate. Priced history stays unchanged. Groq speech has a 10-second minimum per request.")
            }
            if !entries.isEmpty {
                Section("Recent requests") {
                    ForEach(Array(entries.suffix(30).reversed())) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                Spacer()
                                Text(entry.usd.map(CloudUsageStore.money) ?? "Unavailable")
                            }
                            Text(details(entry)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("\(model.title) · \(model.kind)").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let rate = store.rate(for: model) {
                let style = FloatingPointFormatStyle<Double>.number.grouping(.never).precision(.fractionLength(0...9))
                input = rate.input.formatted(style); output = rate.output.formatted(style); cached = rate.cached.formatted(style)
            }
        }
    }
    private func rateField(_ name: String, text: Binding<String>) -> some View {
        HStack {
            Text(name)
            TextField("Rate needed", text: text).multilineTextAlignment(.trailing).keyboardType(.decimalPad)
        }
    }
    private func details(_ entry: CloudUsageEntry) -> String {
        if entry.streamed == true {
            return "\((entry.seconds ?? 0).formatted(.number.precision(.fractionLength(1)))) seconds streamed · \(entry.purpose ?? "In progress")"
        }
        guard entry.confirmed else { return "No confirmed response · check provider billing" }
        if let seconds = entry.seconds { return seconds.formatted(.number.precision(.fractionLength(1))) + " seconds" }
        guard let input = entry.inputTokens, let output = entry.outputTokens else { return "Provider did not return token usage" }
        return "\(entry.purpose.map { $0 + " · " } ?? "")\(input) input · \(output) output · \(entry.cachedTokens ?? 0) cached tokens"
    }
}

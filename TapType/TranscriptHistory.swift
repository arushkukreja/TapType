import Foundation
import SwiftUI
import NaturalLanguage

struct TranscriptRecord: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let text: String
    var wordCount: Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if text[range].contains(where: { $0.isLetter || $0.isNumber }) { count += 1 }
            return true
        }
        return count
    }
    var localTimestamp: String {
        createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .standard,
            locale: .autoupdatingCurrent, timeZone: .autoupdatingCurrent))
    }
}

@MainActor
final class TranscriptHistory: ObservableObject {
    static let shared = TranscriptHistory()
    @Published private(set) var entries: [TranscriptRecord] = []
    @Published private(set) var notice: String?
    var totalWords: Int { entries.reduce(0) { $0 + $1.wordCount } }
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranscriptHistory", isDirectory: true)
        guard FileManager.default.fileExists(atPath: self.directory.path) else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                do { entries.append(try JSONDecoder().decode(TranscriptRecord.self, from: Data(contentsOf: file))) }
                catch { notice = "Some saved transcripts couldn’t be opened. Their files have been kept." }
            }
            entries.sort { $0.createdAt > $1.createdAt }
        } catch { notice = "Your transcript history couldn’t be opened. Please reopen TapType." }
    }
    func record(id: UUID, text: String, at date: Date = Date()) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !entries.contains(where: { $0.id == id }) else { return }
        let entry = TranscriptRecord(id: id, createdAt: date, text: text)
        do {
            var directory = directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            try JSONEncoder().encode(entry).write(to: directory.appendingPathComponent(id.uuidString + ".json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            entries.append(entry); entries.sort { $0.createdAt > $1.createdAt }
        } catch { notice = "This transcript couldn’t be saved. Check your iPhone’s storage." }
    }
    func remove(_ id: UUID) {
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json"))
            entries.removeAll { $0.id == id }
        } catch { notice = "This transcript couldn’t be removed. Please try again." }
    }
}

struct TranscriptHistoryView: View {
    @ObservedObject private var history = TranscriptHistory.shared
    var body: some View {
        List {
            Section {
            if history.entries.isEmpty { Text("Completed dictations will appear here.").foregroundStyle(.secondary) }
            ForEach(history.entries) { entry in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 8) {
                        Text("\(entry.localTimestamp) · \(entry.wordCount) words").font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button { UIPasteboard.general.string = entry.text } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.subheadline).foregroundStyle(.gray)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }.buttonStyle(.borderless).tint(.gray).accessibilityLabel("Copy transcript")
                    }
                    Text(entry.text).textSelection(.enabled)
                }.padding(.vertical, 4)
            }
            if let notice = history.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .contentMargins(.top, 8, for: .scrollContent)
        .navigationTitle("Original transcripts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

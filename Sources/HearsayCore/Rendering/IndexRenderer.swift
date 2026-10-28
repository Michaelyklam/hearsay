import Foundation

/// `index.md` (newest first) and `index.jsonl`, regenerated from every meeting folder.
public enum IndexRenderer {
    public struct Entry: Codable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let startedAt: Date
        public let endedAt: Date?
        public let status: MeetingStatus
        public let speakers: [SpeakerSummary]
        public let named: Bool
        public let path: String
    }

    public static func entries(store: MeetingStore) -> [Entry] {
        // With transcript encryption on, the index keeps titles, dates and status only: no speakers.
        let textFree = store.transcriptsEncrypted
        return sorted(store.loadAllMeetings().map { entry(store: store, meeting: $0, textFree: textFree) })
    }

    static func entry(store: MeetingStore, meeting m: Meeting, textFree: Bool) -> Entry {
        let t = textFree ? nil : (try? store.loadTranscript(m.id)) ?? nil
        let speakers = t.map { SpeakerSummary.summarize($0, names: m.speakerNames) } ?? []
        return Entry(
            id: m.id, title: m.title, startedAt: m.startedAt, endedAt: m.endedAt, status: m.status,
            speakers: speakers, named: SpeakerSummary.allNamed(speakers), path: "\(m.id)/transcript.md\(textFree ? ".enc" : "")")
    }

    static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { $0.startedAt != $1.startedAt ? $0.startedAt > $1.startedAt : $0.id > $1.id }
    }

    public static func markdown(_ entries: [Entry]) -> String {
        var out = "# Meetings\n\n| Date | Title | Duration | Speakers named | Status |\n|---|---|---|---|---|\n"
        for e in entries {
            let duration = e.endedAt.map { Format.clock($0.timeIntervalSince(e.startedAt)) } ?? ""
            let main = e.speakers.filter(\.main)
            let named = "\(main.filter { $0.name != nil }.count)/\(main.count)"
            let link = "[\(cell(e.title.isEmpty ? e.id : e.title))](<\(e.path)>)"
            out += "| \(Format.shortDate(e.startedAt)) | \(link) | \(duration) | \(named) | \(e.status.rawValue) |\n"
        }
        return out
    }

    public static func jsonl(_ entries: [Entry]) throws -> String {
        let enc = JSONCoding.encoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try entries.map { String(decoding: try enc.encode($0), as: UTF8.self) + "\n" }.joined()
    }

    private static func cell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    /// After an edit to `ids`: re-renders their Markdown, then rewrites the index reusing `index.jsonl`'s
    /// rows for the other meetings. `reindex` decodes every transcript in the folder to rebuild rows that
    /// have not changed (0.3 s for 35 meetings, on the main thread for every rename in the app).
    /// A row is rebuilt when its meeting is in `ids`, missing from the cache, or its `meeting.json` or
    /// `transcript.json` is newer than `index.jsonl`, so a write that skipped the index still shows up.
    /// Falls back to `reindex` when `index.jsonl` is missing or unreadable, or was written with the
    /// other transcript-encryption setting.
    public static func update(store: MeetingStore, ids: Set<String>) throws {
        let jsonlURL = store.root.appendingPathComponent("index.jsonl")
        let textFree = store.transcriptsEncrypted
        guard let cached = cachedEntries(jsonlURL),
              cached.allSatisfy({ $0.path.hasSuffix(".enc") == textFree }),
              let indexedAt = modified(jsonlURL)
        else { return try reindex(store: store) }
        try store.prepare()
        for id in ids.sorted() {
            do { try TranscriptRenderer.write(store: store, id: id) } catch {
                HearsayCore.logger("index").error("Render failed for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        let byID = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Entry] = []
        for id in store.listMeetingIDs() {
            if !ids.contains(id), let e = byID[id], !changed(store: store, id: id, since: indexedAt) {
                out.append(e)
            } else if let m = try? store.loadMeeting(id) {
                out.append(entry(store: store, meeting: m, textFree: textFree))
            }
        }
        let e = sorted(out)
        try AtomicFile.write(markdown(e), to: store.root.appendingPathComponent("index.md"))
        try AtomicFile.write(jsonl(e), to: jsonlURL)
    }

    static func cachedEntries(_ url: URL) -> [Entry]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let dec = JSONCoding.decoder()
        var out: [Entry] = []
        for line in text.split(separator: "\n") where !line.isEmpty {
            guard let e = try? dec.decode(Entry.self, from: Data(line.utf8)) else { return nil }
            out.append(e)
        }
        return out
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// `meeting.json` or `transcript.json` (plain or sealed) written at or after `date`.
    private static func changed(store: MeetingStore, id: String, since date: Date) -> Bool {
        let folder = store.folder(id)
        for name in [MeetingStore.meetingFile, MeetingStore.transcriptFile] {
            for file in [name, name + "." + EncryptedFile.suffix] {
                if let d = modified(folder.appendingPathComponent(file)), d >= date { return true }
            }
        }
        return false
    }

    /// Regenerates every meeting's Markdown, then the index.
    public static func reindex(store: MeetingStore) throws {
        try store.prepare()
        for id in store.listMeetingIDs() {
            do { try TranscriptRenderer.write(store: store, id: id) } catch {
                HearsayCore.logger("index").error("Render failed for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        let e = entries(store: store)
        try AtomicFile.write(markdown(e), to: store.root.appendingPathComponent("index.md"))
        try AtomicFile.write(jsonl(e), to: store.root.appendingPathComponent("index.jsonl"))
    }
}

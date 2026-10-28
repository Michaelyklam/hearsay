import Foundation
import Testing
@testable import HearsayCore

@Suite struct IndexTests {
    @Test func indexListsNewestFirst() throws {
        let store = try TestSupport.rootWithFixture()
        let (m, t) = TestSupport.smallMeeting()
        try store.saveMeeting(m)
        try store.saveTranscript(t, id: m.id)
        var bare = Meeting(id: "2026-09-01 0800 Recording", title: "", startedAt: TestSupport.date("2026-09-01T08:00:00.000Z"))
        bare.status = .recording
        try store.saveMeeting(bare)

        try IndexRenderer.reindex(store: store)

        let md = try String(contentsOf: store.root.appendingPathComponent("index.md"), encoding: .utf8)
        let rows = md.split(separator: "\n").filter { $0.hasPrefix("| 2026") }
        #expect(rows.count == 3)
        #expect(rows[0].contains("Small: sync") && rows[0].contains("02:05") && rows[0].contains("1/2") && rows[0].contains("done"))
        #expect(rows[1].contains("Fixture standup") && rows[1].contains("2/2"))
        #expect(rows[2].contains("2026-09-01 0800 Recording") && rows[2].contains("recording"))

        let lines = try String(contentsOf: store.root.appendingPathComponent("index.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 3)
        let first = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(first["id"] as? String == m.id)
        #expect(first["named"] as? Bool == false)
        #expect(first["path"] as? String == "\(m.id)/transcript.md")
        #expect((first["speakers"] as? [Any])?.count == 2)
        for key in ["title", "startedAt", "endedAt", "status"] { #expect(first[key] != nil) }

        // Markdown was regenerated for every meeting with a transcript
        #expect(FileManager.default.fileExists(atPath: store.folder(m.id).appendingPathComponent("transcript.md").path))
        #expect(!FileManager.default.fileExists(atPath: store.folder(bare.id).appendingPathComponent("transcript.md").path))
    }

    private func indexFiles(_ store: MeetingStore) throws -> (String, String) {
        (try String(contentsOf: store.root.appendingPathComponent("index.md"), encoding: .utf8),
         try String(contentsOf: store.root.appendingPathComponent("index.jsonl"), encoding: .utf8))
    }

    private func touch(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// Two meetings indexed, the files dated an hour ago so later writes are newer than the index.
    private func indexedStore() throws -> (MeetingStore, Meeting) {
        let store = try TestSupport.rootWithFixture()
        let (m, t) = TestSupport.smallMeeting()
        try store.saveMeeting(m)
        try store.saveTranscript(t, id: m.id)
        try IndexRenderer.reindex(store: store)
        let past = Date().addingTimeInterval(-3600)
        for id in store.listMeetingIDs() {
            for name in ["meeting.json", "transcript.json"] { try touch(store.folder(id).appendingPathComponent(name), past) }
        }
        try touch(store.root.appendingPathComponent("index.jsonl"), past.addingTimeInterval(1))
        return (store, m)
    }

    @Test func renameUpdatesTheIndexLikeAFullReindex() throws {
        let (store, m) = try indexedStore()
        try MeetingEdits.rename(id: m.id, speaker: "sys-1", name: "Reese", store: store)
        let updated = try indexFiles(store)
        #expect(updated.0.contains("2/2"))
        let md = try String(contentsOf: store.folder(m.id).appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(md.contains("Reese"))

        try IndexRenderer.reindex(store: store)
        let full = try indexFiles(store)
        #expect(updated.0 == full.0)
        #expect(updated.1 == full.1)
    }

    @Test func updateRebuildsRowsWrittenAfterTheIndex() throws {
        let (store, m) = try indexedStore()
        // The fixture's title changes without going through the index (as a recording's writes do).
        var other = try store.loadMeeting(TestSupport.fixtureID)
        other.title = "Renamed elsewhere"
        try store.saveMeeting(other)

        try IndexRenderer.update(store: store, ids: [m.id])
        #expect(try indexFiles(store).0.contains("Renamed elsewhere"))
    }

    @Test func updateKeepsCachedRowsAndDropsDeletedMeetings() throws {
        let (store, m) = try indexedStore()
        // A row older than the index is reused as is: prove it by editing the cache, not the meeting.
        let jsonl = store.root.appendingPathComponent("index.jsonl")
        let cached = try String(contentsOf: jsonl, encoding: .utf8).replacingOccurrences(of: "\"title\":\"Fixture standup\"", with: "\"title\":\"From the cache\"")
        try cached.write(to: jsonl, atomically: true, encoding: .utf8)
        try touch(jsonl, Date().addingTimeInterval(-1800))
        try IndexRenderer.update(store: store, ids: [m.id])
        #expect(try indexFiles(store).0.contains("From the cache"))

        try FileManager.default.removeItem(at: store.folder(TestSupport.fixtureID))
        try IndexRenderer.update(store: store, ids: [m.id])
        let (md, lines) = try indexFiles(store)
        #expect(!md.contains("From the cache"))
        #expect(lines.split(separator: "\n").count == 1)
    }

    @Test func updateWithoutAnIndexDoesAFullReindex() throws {
        let store = try TestSupport.rootWithFixture()
        let (m, t) = TestSupport.smallMeeting()
        try store.saveMeeting(m)
        try store.saveTranscript(t, id: m.id)
        try IndexRenderer.update(store: store, ids: [m.id])
        #expect(try indexFiles(store).1.split(separator: "\n").count == 2)
        // The fixture's Markdown was rendered too, not only the edited meeting's.
        #expect(FileManager.default.fileExists(atPath: store.folder(TestSupport.fixtureID).appendingPathComponent("transcript.md").path))
    }
}

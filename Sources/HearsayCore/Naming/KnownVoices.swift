import Foundation

/// People you have named before, recognised by voice in a new meeting. Every speaker with a voice and
/// a typed name in another meeting is a sample for that name on that stream (a call codec changes a
/// voice, so room samples only match room voices and call samples call voices).
public enum KnownVoices {
    /// Stricter than your own voiceprint (0.6): a wrong name on someone else reads as fact. Your voice
    /// measured 0.70 to 0.90 against itself and other voices 0.54 or less; not yet measured for call audio.
    public static let threshold: Float = 0.65
    /// The best name must beat the next name by this much, and the next voice in the meeting by this much.
    public static let margin: Float = 0.15

    public struct Sample: Sendable, Equatable {
        public var name: String
        public var stream: StreamKind
        public var voice: [Float]
        public init(name: String, stream: StreamKind, voice: [Float]) { self.name = name; self.stream = stream; self.voice = voice }
    }

    /// One sample per named speaker with a voice in every other meeting.
    public static func samples(store: MeetingStore, excluding id: String) -> [Sample] {
        store.listMeetingIDs().filter { $0 != id }.flatMap { other -> [Sample] in
            guard let m = try? store.loadMeeting(other), let t = try? store.loadTranscript(other) else { return [] }
            return t.speakers.compactMap { s in
                guard let v = s.voice, let n = m.speakerNames[s.id]?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return nil }
                return Sample(name: n, stream: s.stream, voice: v)
            }
        }
    }

    /// Speaker id to name for unnamed speakers whose voice clearly matches one known name. `taken` are
    /// names already used in this meeting (case-insensitive); each name goes to at most one speaker.
    public static func match(speakers: [Speaker], samples: [Sample], taken: Set<String>) -> [String: String] {
        let takenKeys = Set(taken.map { $0.lowercased() })
        // Best score per (speaker, name), names grouped case-insensitively under the most used spelling.
        var spelling: [String: [String: Int]] = [:]
        for s in samples { spelling[s.name.lowercased(), default: [:]][s.name, default: 0] += 1 }
        var candidates: [(id: String, key: String, score: Float)] = []
        var bestPerSpeaker: [String: [Float]] = [:]
        for sp in speakers {
            guard let v = sp.voice else { continue }
            var byName: [String: Float] = [:]
            for s in samples where s.stream == sp.stream {
                let c = VoiceEmbedder.cosine(v, s.voice)
                byName[s.name.lowercased()] = max(byName[s.name.lowercased()] ?? -1, c)
            }
            let ranked = byName.sorted { $0.value > $1.value }
            bestPerSpeaker[sp.id] = ranked.map(\.value)
            guard let top = ranked.first, top.value >= threshold, !takenKeys.contains(top.key) else { continue }
            if ranked.count > 1, top.value - ranked[1].value < margin { continue }
            candidates.append((sp.id, top.key, top.value))
        }
        // Another voice in this meeting scoring close to the same name makes it ambiguous.
        var out: [String: String] = [:]
        var used = Set<String>()
        let grouped = Dictionary(grouping: candidates, by: \.key)
        for (key, cs) in grouped {
            let sorted = cs.sorted { $0.score > $1.score }
            if sorted.count > 1, sorted[0].score - sorted[1].score < margin { continue }
            guard !used.contains(key) else { continue }
            used.insert(key)
            let name = spelling[key]?.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? key
            out[sorted[0].id] = name
        }
        return out
    }
}

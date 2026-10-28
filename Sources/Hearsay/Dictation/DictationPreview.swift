import AppKit
import Foundation

/// Debug launch: `--preview-dictation [TEXT] [--preview-snapshot PNG]` shows the dictation bubble
/// with TEXT as the streamed words (none: "Listening…"), so its size can be looked at. With
/// `--preview-snapshot` it renders the bubble to a PNG after 1 s and quits.
@MainActor
enum DictationPreview {
    static func startIfRequested(_ args: [String] = CommandLine.arguments) {
        guard let i = args.firstIndex(of: "--preview-dictation") else { return }
        let text = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : ""
        DictationBubble.shared.show()
        if !text.isEmpty { DictationBubble.shared.update(text) }
        if let s = args.firstIndex(of: "--preview-snapshot"), s + 1 < args.count {
            let url = URL(fileURLWithPath: args[s + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { DictationBubble.shared.snapshot(to: url) }
                NSApp.terminate(nil)
            }
        }
    }
}

import SwiftUI
import SwiftPJSUA

/// C1 debug surface: the engine's event stream verbatim, plus a live view of the PJMEDIA
/// conference bridge as reported by `callMediaState` events.
///
/// Both lists are fed by the router's event tap (`PhoneModel.events` / `.mediaByCall`) —
/// nothing here touches the engine, so the view can be opened and closed freely.
struct DiagnosticsView: View {
    let model: PhoneModel

    var body: some View {
        Form {
            Section("Conference slots") {
                if model.mediaByCall.isEmpty {
                    Text("No active media.").foregroundStyle(.secondary)
                } else {
                    // Sorted by call id for a stable row order across media updates.
                    ForEach(model.mediaByCall.sorted(by: { $0.key.raw < $1.key.raw }), id: \.key) { call, media in
                        ForEach(media, id: \.index) { m in
                            LabeledContent(String(describing: call) + " · \(m.kind) #\(m.index)") {
                                Text(describe(m))
                                    .font(.caption.monospaced())
                            }
                        }
                    }
                }
            }
            Section("Event stream") {
                if model.events.isEmpty {
                    Text("No events yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.events.reversed()) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.text)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Text(row.timestamp, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func describe(_ media: CallMediaInfo) -> String {
        var parts = ["\(media.status)", "\(media.direction)"]
        if let slot = media.audioConfSlot { parts.append("conf \(slot)") }
        if let window = media.videoWindow { parts.append("win \(window)") }
        return parts.joined(separator: " · ")
    }
}

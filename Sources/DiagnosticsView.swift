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
                            Text(row.event.diagnosticSummary)
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

extension PJSUAEvent {
    /// Compact one-line rendering for Diagnostics and the shared log — every field that
    /// identifies a SIP leg or media stream survives (SIP Call-IDs, lastStatus, per-stream
    /// counters); only formatting is dropped.
    var diagnosticSummary: String {
        switch self {
        case .registrationState(let account, let active, let code, let expiration):
            return "reg acc=\(account.raw) active=\(active) \(code) exp=\(expiration)s"
        case .incomingCall(let account, let call, let sipCallID, let from, let offeredVideo):
            return "invite \(call) acc=\(account.raw) callid=\(sipCallID ?? "?") from=\(from ?? "?") video=\(offeredVideo)"
        case .callState(let call, let state, let sipCallID, let lastStatus):
            return "\(call) \(state) last=\(lastStatus) callid=\(sipCallID ?? "?")"
        case .callMediaState(let call, let media):
            let streams = media.map { m in
                let slot = m.audioConfSlot.map { " conf=\($0)" } ?? ""
                let win = m.videoWindow.map { " win=\($0)" } ?? ""
                return "\(m.index):\(m.kind) \(m.status) \(m.direction)\(slot)\(win)"
            }.joined(separator: " ")
            return "media \(call) [\(streams)]"
        case .streamDestroyed(let call, let mediaIndex, let stats):
            return "stream- \(call) idx=\(mediaIndex) \(stats.codec) "
                + "tx=\(stats.transmit.packets) rx=\(stats.receive.packets) lost=\(stats.receive.lost) "
                + "jit=\(Int(stats.receive.jitter.lastMs))ms rtt=\(Int(stats.roundTrip.lastMs))ms"
        case .callMediaEvent(let call, let mediaIndex, let mediaEvent):
            switch mediaEvent {
            case .mediaTransportError(let status, let isRTP):
                return "mediaerr \(call) idx=\(mediaIndex) \(isRTP ? "rtp" : "rtcp") status=\(status)"
            case .audioDeviceError(let status):
                return "auderr \(call) idx=\(mediaIndex) status=\(status)"
            case .other(let fourCC):
                return "pjevent \(call) idx=\(mediaIndex) \(fourCC)"
            }
        }
    }
}

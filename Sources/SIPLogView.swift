import SwiftUI

/// C1 debug surface: the raw pjsip log as delivered by the engine's `logSink` — SIP
/// messages, transport errors, media traces — with a verbosity ceiling filter so a busy
/// level-5 trace doesn't bury the level-1 error you're hunting.
struct SIPLogView: View {
    let model: PhoneModel
    /// Highest PJSIP level shown (0 fatal … 6 trace). Defaults to everything.
    @State private var maxLevel: Int32 = 6

    var body: some View {
        Form {
            Section {
                Stepper("Show level ≤ \(maxLevel)", value: $maxLevel, in: 0...6)
            }
            Section("SIP log") {
                if model.sipLog.isEmpty {
                    Text("Nothing logged yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.sipLog.reversed().filter { $0.level <= maxLevel }) { row in
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
        .navigationTitle("SIP log")
        .navigationBarTitleDisplayMode(.inline)
    }
}

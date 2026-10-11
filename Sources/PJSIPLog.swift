import Foundation
import os

/// pjsip's own log, from the engine's `logSink` to the unified log and, in debug builds, to a SIP
/// log file. Runs on whichever pjsip thread logged the line, so nothing here touches the main actor.
enum PJSIPLog {
    /// Scrub the line once, then hand it to every sink. Returns it scrubbed, for the in-app SIP log.
    static func record(level: Int32, text: String) -> String {
        let line = scrub(text).trimmingCharacters(in: .newlines)
        let type = OSLogType(pjsipLevel: level)
        #if DEBUG
        // Debug builds log public, so collected logs read whole (docs/Design.md, "Logging").
        Logger.pjsip.log(level: type, "\(line, privacy: .public)")
        file?.append(line, level: level)
        #else
        Logger.pjsip.log(level: type, "\(line)")
        #endif
        return line
    }

    /// SIP traffic carries credentials: digest `response` values, Basic payloads, and the push
    /// token in every REGISTER's Contact (`pn-prid`, kept to its first 8 hex digits). Header and
    /// parameter names stay — auth and push debugging read them — the material goes.
    /// Case-insensitive with optional LWS: `RESPONSE = "…"` and `response="…"` are the same header
    /// to a SIP parser. The digest `response` is scrubbed unquoted too: RFC 7616 quotes it, but a
    /// non-conforming peer's line must not reach the log whole.
    private static let scrubbers: [(pattern: String, template: String)] = [
        (#"(?i)(\bresponse\s*=\s*)(?:"[^"]*"|[^\s,;"]+)"#, #"$1"•••""#),
        (#"(?i)((?:Proxy-)?Authorization\s*:\s*Basic\s+)\S+"#, #"$1<redacted>"#),
        (#"(?i)(pn-prid\s*=\s*[0-9a-f]{8})[0-9a-f]+"#, #"$1…"#),
    ]

    private static func scrub(_ line: String) -> String {
        scrubbers.reduce(line) {
            $0.replacingOccurrences(of: $1.pattern, with: $1.template, options: .regularExpression)
        }
    }

    #if DEBUG
    private static let file = SIPLogFile()
    #endif
}

private extension OSLogType {
    /// pjsip's verbosity, 0 (fatal) … 6 (detailed trace), onto the unified log's types. Level 4 is
    /// where pjsua dumps whole SIP messages: `.info` keeps them in memory, where `log collect`
    /// still finds the recent ones. 5–6 are `.debug`, which the unified log does not keep; the
    /// debug build's SIP file has them.
    init(pjsipLevel level: Int32) {
        switch level {
        case ...0: self = .fault
        case 1: self = .error
        case 2: self = .default
        case 3, 4: self = .info
        default: self = .debug
        }
    }
}

/// The debug build's SIP log on disk: one file per launch in `Library/Caches/Logs/`, the newest
/// five kept, read from the Mac with `devicectl device copy from` (docs/Testing-Playbook.md §9).
///
/// Not pjsua's own `log_filename`: pjsua writes that through stdio and never flushes it, so the
/// buffered tail — the lines just before iOS kills a suspended app, which is the push case — is
/// lost. Here each line is one `write(2)` on an `O_APPEND` descriptor: in the kernel when the call
/// returns, and whole even when two pjsip threads log at once (`pj_log` takes no lock). The
/// descriptor lives as long as the process.
private struct SIPLogFile: Sendable {
    private let descriptor: Int32

    init?() {
        let files = FileManager.default
        guard let caches = files.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = caches.appending(path: "Logs", directoryHint: .isDirectory)
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        // UTC timestamps sort by name, so pruning needs no file dates.
        let previous = ((try? files.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("sip-") && $0.hasSuffix(".log") }
            .sorted()
        for name in previous.dropLast(4) {
            try? files.removeItem(at: directory.appending(path: name))
        }
        let stamp = Date.now.formatted(Date.ISO8601FormatStyle(timeSeparator: .omitted))
        let path = directory.appending(path: "sip-\(stamp).log").path
        descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return nil }
    }

    /// The pjsip level leads the line, so `grep '^[0-2] '` finds warnings and worse.
    func append(_ line: String, level: Int32) {
        var entry = "\(level) \(line)\n"
        entry.withUTF8 { _ = write(descriptor, $0.baseAddress, $0.count) }
    }
}

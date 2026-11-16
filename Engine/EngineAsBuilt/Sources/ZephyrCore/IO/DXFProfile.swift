import Foundation

// =========================================================================
// MARK: - DXF import profiling (TEMPORARY)
// =========================================================================
//
// Kept deliberately: it is how the 1.3 s per-entity string format was found, and the
// remaining hotspot (parseSections) is next. Enable with `ZEPHYR_DXF_PROFILE=1`; when
// enabled it prints to stderr, when disabled the cost is one cached-Bool check per
// phase. Delete it and the `DXFProfile.` call sites once DXF import work is finished.
//
// Deliberately dumb: env-gated timestamps that print to stderr, so a normal build
// pays one cached-Bool check per phase and produces no output. Phase marks report
// time since the previous mark, so inserting/removing marks is a one-line edit.
enum DXFProfile {

    static let enabled = ProcessInfo.processInfo.environment["ZEPHYR_DXF_PROFILE"] == "1"

    /// Guarded by `lock`: background loads parse off the main thread, and two
    /// queued loads must not interleave marks/accumulators.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastMark: UInt64 = DispatchTime.now().uptimeNanoseconds
    nonisolated(unsafe) private static var accumulators: [String: (ns: UInt64, calls: Int)] = [:]

    private static func milliseconds(_ ns: UInt64) -> String {
        String(format: "%9.1f ms", Double(ns) / 1_000_000)
    }

    static func reset(_ label: String) {
        guard enabled else { return }
        lock.withLock {
            accumulators.removeAll(keepingCapacity: true)
            lastMark = DispatchTime.now().uptimeNanoseconds
        }
        write("[dxf-profile] === " + label + " ===")
    }

    /// Prints the time elapsed since the previous `mark`/`reset`.
    static func mark(_ label: String) {
        guard enabled else { return }
        let line: String = lock.withLock {
            let now = DispatchTime.now().uptimeNanoseconds
            let text = "[dxf-profile] " + pad(label, 44) + milliseconds(now &- lastMark)
            lastMark = now
            return text
        }
        write(line)
    }

    /// Prints accumulated `tic`/`toc` totals, call counts and the mark totals.
    static func dump(_ label: String) {
        guard enabled else { return }
        let lines: [String] = lock.withLock {
            var out: [String] = []
            for key in accumulators.keys.sorted() {
                guard let entry = accumulators[key] else { continue }
                let perCall = entry.calls > 0 ? Double(entry.ns) / Double(entry.calls) / 1000 : 0
                out.append("[dxf-profile] " + pad(key, 44) + milliseconds(entry.ns)
                      + String(format: "  x%d  (%.2f us/call)", entry.calls, perCall))
            }
            out.append("[dxf-profile] --- " + label + " ---")
            accumulators.removeAll(keepingCapacity: true)
            return out
        }
        for line in lines { write(line) }
    }

    static func tic() -> UInt64 {
        enabled ? DispatchTime.now().uptimeNanoseconds : 0
    }

    static func toc(_ start: UInt64, _ label: String) {
        guard enabled, start != 0 else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- start
        lock.withLock {
            var entry = accumulators[label] ?? (0, 0)
            entry.ns &+= elapsed
            entry.calls += 1
            accumulators[label] = entry
        }
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func write(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

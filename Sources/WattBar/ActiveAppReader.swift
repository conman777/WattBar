import Cocoa

final class ActiveAppReader {
    func topApps(limit: Int = 5) -> [ActiveApp] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,pcpu=,rss=,comm="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else { return [] }
        return Self.parse(output, limit: limit,
            excludingPID: ProcessInfo.processInfo.processIdentifier, displayName: displayName)
    }

    static func parse(_ output: String, limit: Int = 5, excludingPID: pid_t,
                      displayName: (pid_t, String) -> String) -> [ActiveApp] {
        guard limit > 0 else { return [] }
        var totals: [String: (cpu: Double, memoryKB: Int)] = [:]

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = pid_t(parts[0]),
                  pid != excludingPID,
                  let cpu = Double(parts[1]),
                  let memoryKB = Int(parts[2]),
                  cpu.isFinite, cpu >= 0, memoryKB >= 0 else {
                continue
            }

            let command = String(parts[3])
            let appName = displayName(pid, command)
            let existing = totals[appName] ?? (0, 0)
            totals[appName] = (existing.cpu + cpu, existing.memoryKB + memoryKB)
        }

        // Rank busy apps only after adding RAM from all of their processes.
        return totals
            .filter { $0.value.cpu >= 0.1 }
            .map { ActiveApp(name: $0.key, cpu: $0.value.cpu, memoryMB: max(1, $0.value.memoryKB / 1_024)) }
            .sorted { lhs, rhs in
                if lhs.cpu == rhs.cpu {
                    return lhs.memoryMB > rhs.memoryMB
                }
                return lhs.cpu > rhs.cpu
            }
            .prefix(limit)
            .map { $0 }
    }

    private func displayName(for pid: pid_t, command: String) -> String {
        if let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName,
           !name.isEmpty {
            return name
        }

        let lastPathComponent = URL(fileURLWithPath: command).lastPathComponent
        return lastPathComponent.isEmpty ? command : lastPathComponent
    }
}


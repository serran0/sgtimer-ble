import Foundation

class SessionsStore {
    let dataDir: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dataDir = docs.appendingPathComponent("data")
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }

    // MARK: - Session listing

    func listSessions(offset: Int, limit: Int) -> [[String: Any]] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dataDir, includingPropertiesForKeys: nil
        ) else { return [] }

        let csvFiles = files
            .filter { $0.pathExtension == "csv" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        return Array(csvFiles.dropFirst(offset).prefix(limit))
            .compactMap { parseSession(at: $0) }
    }

    private func parseSession(at url: URL) -> [String: Any]? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let sessId = url.deletingPathExtension().lastPathComponent

        var totalShots = 0
        var bestSplit = 0.0
        var totalTime = 0.0
        var lastTs: Int?
        var firstTs: Int?
        var lastShotTs: Int?

        let lines = content.components(separatedBy: "\n").dropFirst()
        for line in lines {
            let cols = line.components(separatedBy: ",")
            guard cols.count >= 5, cols[0] == "SHOT_DETECTED" else { continue }
            totalShots += 1
            if let t = Double(cols[2]) { totalTime = t }
            if let ts = Int(cols[4].trimmingCharacters(in: .whitespacesAndNewlines)) {
                if firstTs == nil { firstTs = ts }
                lastTs = ts
                if let prev = lastShotTs {
                    let split = Double(ts - prev) / 1000.0
                    if split > 0 && (bestSplit == 0 || split < bestSplit) { bestSplit = split }
                }
                lastShotTs = ts
            }
        }

        let duration: Double
        if let f = firstTs, let l = lastTs { duration = Double(l - f) / 1000.0 } else { duration = 0 }

        return [
            "sess_id": sessId,
            "total_shots": totalShots,
            "best_split": round(bestSplit * 100) / 100,
            "total_time": round(totalTime * 100) / 100,
            "duration": round(duration * 100) / 100,
            "file": url.lastPathComponent
        ]
    }

    // MARK: - CSV writes

    func createSession(sessId: String) {
        let url = dataDir.appendingPathComponent("\(sessId).csv")
        let header = "event,shot_num,shot_time,split,ts_device\n"
        try? header.write(to: url, atomically: true, encoding: .utf8)
    }

    func appendShot(sessId: String, shotNum: Int, shotTime: Double, split: Double?, tsDevice: Int) {
        let url = dataDir.appendingPathComponent("\(sessId).csv")
        let splitStr = split.map { String(format: "%.3f", $0) } ?? ""
        let line = "SHOT_DETECTED,\(shotNum),\(String(format: "%.3f", shotTime)),\(splitStr),\(tsDevice)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        }
    }

    // MARK: - CSV download

    func csvData(sessId: String) -> Data? {
        let url = dataDir.appendingPathComponent("\(sessId).csv")
        return try? Data(contentsOf: url)
    }

    // MARK: - Delete all sessions

    @discardableResult
    func clearSessions() -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dataDir, includingPropertiesForKeys: nil
        ) else { return 0 }

        var deleted = 0
        for file in files where file.pathExtension == "csv" {
            if (try? FileManager.default.removeItem(at: file)) != nil { deleted += 1 }
        }
        return deleted
    }
}

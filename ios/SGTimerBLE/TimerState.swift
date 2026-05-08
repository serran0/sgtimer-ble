import Foundation

struct Shot {
    let num: Int
    let time: Double
}

class TimerState {
    var active = false
    var status = "STOPPED"
    var shots: [Shot] = []
    var firstShot: Double = 0
    var bestSplit: Double = 0
    var totalTime: Double = 0
    var sessId: Int? = nil

    func toDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "active": active,
            "status": status,
            "shots": shots.map { ["num": $0.num, "time": $0.time] },
            "first_shot": firstShot,
            "best_split": bestSplit,
            "total_time": totalTime
        ]
        if let id = sessId { d["sess_id"] = id } else { d["sess_id"] = NSNull() }
        return d
    }

    func reset() {
        shots = []
        firstShot = 0
        bestSplit = 0
        totalTime = 0
    }
}

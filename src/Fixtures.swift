#if DEBUG
import Cocoa

/* 夹具：同一份代码在重构前后各编一次，跑同一组场景，输出规范化 JSON 做字节比对。
   只使用重构前后都存在的接口（readStore / writeStore / wipeAllData / storeStatus），
   输出里不含文件名、时间戳、路径 —— 只报状态、条数与冲突结果。 */
extension AppDelegate {

    func runFixture(_ name: String) -> String {
        var steps: [[String: Any]] = []

        func record(_ step: String, _ extra: [String: Any] = [:]) {
            var d = extra
            d["s"] = step
            steps.append(d)
        }

        func shape(_ json: String) -> [String: Any] {
            guard let d = json.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                return ["parsed": false]
            }
            return ["parsed": true,
                    "v": (o["v"] as? NSNumber)?.intValue ?? -1,
                    "nodes": (o["nodes"] as? [Any])?.count ?? -1,
                    "tasks": (o["tasks"] as? [Any])?.count ?? -1,
                    "daily": (o["daily"] as? [String: Any])?.count ?? -1]
        }

        func loadStep() {
            let json = readStore()
            var d = shape(json)
            d["s"] = "load"
            d["kind"] = storeStatus.kind.rawValue
            d["kept"] = storeStatus.kept.count
            steps.append(d)
        }

        func saveStep(_ json: String) {
            let out: String
            switch writeStore(json) {
            case .ok: out = "ok"
            case .rejected: out = "rejected"
            case .conflict: out = "conflict"
            }
            record("save", ["out": out])
        }

        func snapshotCount() -> Int {
            ((try? FileManager.default.contentsOfDirectory(atPath: snapshotDir.path)) ?? [])
                .filter { $0.hasSuffix(".json") }.count
        }

        func externalWrite(_ s: String) {
            try? Data(s.utf8).write(to: storeURL)
        }

        func wipe() {
            let failed = wipeAllData()
            record("wipe", ["failed": failed.count])
        }

        let one = "{\"v\":2,\"nodes\":[{\"id\":1,\"type\":\"task\",\"text\":\"a\"}],\"daily\":{\"2026-11-11\":1}}"
        let two = "{\"v\":2,\"nodes\":[{\"id\":1,\"type\":\"task\",\"text\":\"b\"}],\"daily\":{\"2026-11-10\":1,\"2026-11-11\":2}}"
        let month = "{\"v\":2,\"nodes\":[],\"daily\":{\"2026-10-31\":1,\"2026-11-01\":3}}"
        let external = "{\"v\":2,\"nodes\":[{\"id\":9,\"type\":\"task\",\"text\":\"other\"}]}"
        let legacy = "{\"v\":1,\"tasks\":[{\"id\":1,\"text\":\"old\"}]}"
        let truncated = "{\"v\":2,\"nodes\":[{\"text\":\"半截"

        switch name {
        case "empty":
            loadStep()
            saveStep(one)
            loadStep()
        case "single-day":
            saveStep(one)
            loadStep()
            record("snapshots", ["count": snapshotCount()])
        case "multi-day":
            saveStep(two)
            loadStep()
        case "cross-month":
            saveStep(month)
            loadStep()
        case "concurrent":
            saveStep(one)
            externalWrite(two)
            saveStep(one)
            loadStep()
        case "snapshot":
            saveStep(one)
            saveStep(two)
            record("snapshots", ["count": snapshotCount()])
            saveStep(one)
            record("snapshots", ["count": snapshotCount()])
        case "conflict":
            saveStep(one)
            externalWrite(external)
            saveStep(two)
            loadStep()
        case "clear-rebuild":
            saveStep(one)
            wipe()
            loadStep()
            saveStep(one)
            loadStep()
        case "legacy-format":
            externalWrite(legacy)
            loadStep()
        case "truncated":
            saveStep(one)
            saveStep(two)
            externalWrite(truncated)
            loadStep()
        default:
            record("unknown")
        }

        let obj: [String: Any] = ["fixture": name, "steps": steps]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let out = String(data: data, encoding: .utf8) else { return "{}" }
        return out
    }
}

#endif

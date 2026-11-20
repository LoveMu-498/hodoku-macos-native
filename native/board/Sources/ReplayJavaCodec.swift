// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum ReplayJavaCodec {
    static let maxBytes = 128*1024*1024
    static func validID(_ id: String) -> Bool {
        (1...80).contains(id.utf8.count) && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
        }
    }

    static func decode(_ data: Data) throws -> NativeReplayDocument {
        guard data.count <= maxBytes else { throw ReplayJavaError.invalid }
        var r = ReplayJavaInput(data: data)
        guard try r.int() == 0x4852504c else { throw ReplayJavaError.invalid }
        guard try r.int() == 3 else { throw ReplayJavaError.version }
        let id = try r.utf(), start = try r.long(), elapsed = try r.long(), end = try r.long()
        let completed = try r.boolean(), count = try r.count(100000)
        guard validID(id), elapsed >= 0, count > 0, count <= r.remaining / 515 else { throw ReplayJavaError.invalid }
        var doc = NativeReplayDocument(id: id, startedAt: start, frames: [])
        doc.format = .javaV3; doc.endedAt = end; doc.completed = completed; doc.elapsedMillis = elapsed
        var overlays = [String](), methods = [Bool]()
        var lastID: Int64 = 0, lastTime: Int64 = 0
        for index in 0..<count {
            let op = try r.long(), wall = try r.long(), time = try r.long()
            let label = try r.utf(), overlay = try r.utf(), method = try r.boolean()
            guard op >= lastID, time >= lastTime else { throw ReplayJavaError.invalid }
            lastID = op; lastTime = time
            var board = NativeBoardSnapshot(values: [], fixed: [], candidates: [], userCandidates: [])
            for _ in 0..<81 {
                let digit = try r.byte(), fixed = try r.boolean(), normal = UInt16(try r.number(2)), user = UInt16(try r.number(2))
                guard digit <= 9, !fixed || digit != 0, normal <= 511, user <= 511, digit == 0 || normal == 0 else { throw ReplayJavaError.invalid }
                board.values.append(digit); board.fixed.append(fixed); board.candidates.append(normal); board.userCandidates.append(user)
            }
            var page = BoardPage()
            page.board = board
            var frame = NativeReplayFrame(operationID: op, wallTimeMillis: wall, elapsedMillis: time,
                                          kind: method ? "foreign-method" : "foreign-action", label: label, page: page)
            frame.id = "\(id):\(index)"; frame.operationGroup = "operation:\(op)"
            doc.frames.append(frame)
            overlays.append(overlay); methods.append(method)
        }
        var foreign = true
        var evidence = [Data]()
        var version = 0
        if r.remaining > 0 {
            guard try r.int() == 0x484d5831 else { throw ReplayJavaError.version }
            version = try r.int()
            guard (1...6).contains(version) else { throw ReplayJavaError.version }
            foreign = try r.boolean(); doc.retained = try r.boolean(); doc.pinned = try r.boolean()
            _ = try r.utf(version == 6)
            guard try r.int() == count else { throw ReplayJavaError.invalid }
        } else { doc.elapsedMillis = max(elapsed, lastTime) }

        var latestProof: (operation: Int64, placement: ReplayJavaProof.Placement?)?
        let partialProof = "部分观看。完整的 Java 证明保存在原回放中。"
        for i in 0..<count {
            var f = doc.frames[i], annotations = ReplayJavaAnnotations(board: doc.frames[i].page.board)
            var raw = Data()
            if version != 0 {
                f.kind = try r.utf()
                if version == 6 { f.label = try r.utf(true); overlays[i] = try r.utf(true) }
                raw = try r.blob()
                try annotations.tail(&r, version: version, overlay: overlays[i])
                if !raw.isEmpty {
                    if raw.starts(with: [0x48,0x52,0x41,0x57]) {
                        let (boxes, chains) = try ReplayJavaAnnotations.geometry(raw, pending: false)
                        annotations.editable.boxes = boxes; annotations.editable.chains = chains
                        if f.kind == "authored-input" || f.kind == "authored-result" {
                            annotations.shown.boxes = boxes; annotations.shown.chains = chains
                        }
                        annotations.notices.insert(partialProof)
                    } else {
                        latestProof = (f.operationID, try ReplayJavaProof.validate(raw))
                    }
                }
                let method = ["proof","authored-input","authored-result","foreign-method"].contains(f.kind) ||
                  (annotations.hasDoodleStep && ["doodle-conclusion-input","doodle-or-input"].contains(f.kind))
                guard method == methods[i] else { throw ReplayJavaError.invalid }
            } else { try annotations.overlay(overlays[i], nativeTail: false) }
            if ["proof","apply"].contains(f.kind), let current = latestProof, current.operation == f.operationID {
                if let placement = current.placement {
                    placement.display(in: &annotations.shown, applied: f.kind == "apply")
                    if annotations.descriptions.isEmpty { annotations.descriptions.append(placement.description) }
                } else { annotations.notices.insert(partialProof) }
            }
            if f.kind == "evidence-unavailable" { annotations.notices.insert("部分观看。录制时未保存此步的证明。") }
            if f.kind == "doodle-conclusion-result" || f.kind == "doodle-or-result" {
                annotations.notices.insert("部分观看。此步的历史笔迹与推理详见原回放。")
            }
            f.page = annotations.shown
            f.branchPage = annotations.editable
            f.text = annotations.descriptions.joined(separator: "\n")
            if f.kind.hasSuffix("input") { f.phase = "input" }
            else if f.kind.hasSuffix("result") { f.phase = "result" }
            else if f.kind == "proof" { f.phase = "evidence" }
            else if f.kind.hasSuffix("apply") || ["manual","restore-savepoint"].contains(f.kind) { f.phase = "applied" }
            else { f.phase = "other" }
            f.notices = annotations.notices.sorted()
            f.incompleteDisplay = !annotations.notices.isEmpty
            f.exchangeBlockReason = annotations.exchangeBlockReason
            evidence.append(raw)
            doc.frames[i] = f
        }
        if version != 0 {
            for _ in 0..<(try r.count(10000)) {
                let index = try r.int(), name = try r.utf(version == 6)
                _ = try r.long()
                let time = try r.long()
                guard (0..<count).contains(index), name.utf16.count <= 1000, (0...doc.elapsedMillis).contains(time) else { throw ReplayJavaError.invalid }
                doc.bookmarks.append(NativeReplayBookmark(name: name, frameIndex: index))
            }
            let source = try r.utf(), origin = try r.int(), initial = try r.blob()
            if !source.isEmpty {
                guard validID(source), (0..<100000).contains(origin) else { throw ReplayJavaError.invalid }
                doc.sourceReplayID = source; doc.sourceFrameIndex = origin
            } else if origin != -1 || !initial.isEmpty { throw ReplayJavaError.invalid }
            if !initial.isEmpty {
                let (boxes, chains) = try ReplayJavaAnnotations.geometry(initial, pending: true)
                if evidence[0].isEmpty {
                    doc.frames[0].page.boxes = boxes; doc.frames[0].page.chains = chains
                    doc.frames[0].branchPage?.boxes = boxes; doc.frames[0].branchPage?.chains = chains
                }
            }
        }
        guard r.remaining == 0 else { throw ReplayJavaError.invalid }
        try validate(doc, foreign: foreign, evidence: evidence)
        for index in doc.frames.indices where doc.frames[index].incompleteDisplay == true {
            do { doc.frames[index].displayJSON = try ReplayJavaDisplay.encode(doc.frames[index].page) }
            catch ReplayJavaError.conversion {
                doc.frames[index].exchangeBlockReason = "此帧的标记数量或坐标超出 FRAME 范围。"
            }
        }
        doc.originalBytes = data
        return doc
    }

    static func validate(_ doc: NativeReplayDocument, foreign: Bool, evidence: [Data]) throws {
        guard let first = doc.frames.first, let last = doc.frames.last,
              first.operationID >= 0, first.elapsedMillis >= 0, last.elapsedMillis <= doc.elapsedMillis else { throw ReplayJavaError.invalid }
        let initial = first.page.board
        for f in doc.frames {
            let b = f.page.board
            for i in 0..<81 where initial.fixed[i] {
                guard b.fixed[i], b.values[i] == initial.values[i] else { throw ReplayJavaError.invalid }
            }
            if foreign {
                guard ["foreign-method","foreign-action"].contains(f.kind) else { throw ReplayJavaError.invalid }
            } else if b.fixed != initial.fixed { throw ReplayJavaError.invalid }
        }
        if doc.completed {
            let digits = Set(UInt8(1)...UInt8(9)), b = last.page.board.values
            for n in 0..<9 {
                guard Set((0..<9).map { b[n*9+$0] }) == digits, Set((0..<9).map { b[$0*9+n] }) == digits,
                      Set((0..<9).map { b[(n/3*3+$0/3)*9+n%3*3+$0%3] }) == digits else { throw ReplayJavaError.invalid }
            }
        }
        guard !foreign else { return }
        guard first.kind == "initial", first.operationID == 0, first.elapsedMillis == 0, evidence[0].isEmpty else { throw ReplayJavaError.invalid }
        var cursor = 1, op: Int64 = 0, prior = initial
        while cursor < doc.frames.count {
            op += 1
            let begin = cursor
            guard doc.frames[cursor].operationID == op else { throw ReplayJavaError.invalid }
            var end = cursor + 1
            while end < doc.frames.count && doc.frames[end].operationID == op { end += 1 }
            while cursor < end {
                let f = doc.frames[cursor]
                switch f.kind {
                case "proof":
                    guard cursor+1 < end, doc.frames[cursor+1].kind == "apply",
                          evidence[cursor].starts(with: [0x48,0x52,0x50,0x46]), evidence[cursor+1].isEmpty, f.page.board == prior else { throw ReplayJavaError.invalid }
                    cursor += 2
                case "authored-input":
                    guard cursor+2 < end, doc.frames[cursor+1].kind == "authored-result", doc.frames[cursor+2].kind == "authored-apply",
                          evidence[cursor].starts(with: [0x48,0x52,0x41,0x57]), evidence[cursor+1] == evidence[cursor], evidence[cursor+2] == evidence[cursor],
                          f.page.board == prior, doc.frames[cursor+1].page.board == prior else { throw ReplayJavaError.invalid }
                    cursor += 3
                case "doodle-conclusion-input","doodle-or-input":
                    let expected = f.kind == "doodle-or-input" ? "doodle-or-result" : "doodle-conclusion-result"
                    guard end-begin == 2, cursor+1 < end, doc.frames[cursor+1].kind == expected, f.page.board == prior,
                          evidence[cursor].isEmpty, evidence[cursor+1].isEmpty else { throw ReplayJavaError.invalid }
                    cursor += 2
                case "manual","restore-savepoint","evidence-unavailable":
                    guard evidence[cursor].isEmpty, f.kind == "evidence-unavailable" || end-begin == 1 else { throw ReplayJavaError.invalid }
                    cursor += 1
                default: throw ReplayJavaError.invalid
                }
                let after = doc.frames[cursor-1].page.board
                guard after != prior || f.kind == "doodle-or-input" else { throw ReplayJavaError.invalid }
                if f.kind == "doodle-or-input" && after != prior { throw ReplayJavaError.invalid }
                prior = after
            }
        }
    }
}

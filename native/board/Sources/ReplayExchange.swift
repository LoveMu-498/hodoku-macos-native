// Copyright (C) 2026 HoDoKu contributors. GPL-3.0-or-later.
import CryptoKit
import Foundation

enum ReplayExchange {
    static let maximumBytes = 128 * 1024 * 1024
    static let partialNotice = "部分观看：此帧缺少重要显示内容。"
    static let previewNotice = "使用已冻结的完整画面。"
    static let optionalNotice = "已保留未识别的可选数据。"
    static let known = ["mark", "highlight", "line", "region", "text"]
    private static let times = 0...FrameJSON.safeInteger
    private static let header = Data([72, 82, 80, 76, 0, 0, 0, 4])
    private static let contentKeys = [
        "id", "operationGroup", "phase", "phaseLabel", "wallTimeMs", "elapsedMs", "board", "display",
    ]

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func binding(_ frame: FrameJSON) -> String {
        hash(FrameJSON.record(Dictionary(uniqueKeysWithValues: contentKeys.map { ($0, frame[$0]) })).canonical())
    }
    private static func digest(_ value: FrameJSON) throws -> String {
        let s = try value.text(64)
        try exchangeRequire(
            s.utf8.count == 64
                && s.utf8.allSatisfy {
                    (48...57).contains($0) || (97...102).contains($0)
                }, "SHA-256 错误")
        return s
    }
    private static func blob(_ value: FrameJSON) throws -> Data {
        let limit = ReplayExchangePNG.byteLimit
        let s = try value.text((limit + 2) / 3 * 4)
        let bytes = s.utf8
        let padding = s.hasSuffix("==") ? 2 : (s.hasSuffix("=") ? 1 : 0)
        guard bytes.count % 4 == 0,
            bytes.dropLast(padding).allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 43 || $0 == 47
            }), let data = Data(base64Encoded: s), data.count <= limit
        else { throw ReplayExchangeError("Base64 数据无效") }
        return data
    }

    static func decode(_ data: Data) throws -> NativeReplayDocument {
        try exchangeRequire(
            (12...maximumBytes).contains(data.count) && data.starts(with: header)
                && ReplayExchangePNG.word(data, data.startIndex + 8) == data.count - 12, "FRAME 容器无效")
        var reader = FrameJSONReader(data.dropFirst(12))
        let root = try reader.read()
        try root.exact("format session frames source losses")
        let profile = try root["format"].choice("HRPL-FRAME/0.1 HRPL-FRAME/0.2")
        let extended = profile.hasSuffix("0.2")
        let meta = root["session"]
        try meta.exact("id startedAtMs endedAtMs elapsedMs completed")
        var result = NativeReplayDocument(
            id: try meta["id"].identifier(), startedAt: Int64(try meta["startedAtMs"].number(times)), frames: [])
        result.endedAt = Int64(try meta["endedAtMs"].number(times))
        result.elapsedMillis = Int64(try meta["elapsedMs"].number(times))
        result.completed = try meta["completed"].flag()
        result.format = extended ? .frame02 : .frame01
        var ids = Set<String>()
        var groups = Set<String>()
        var previousGroup: String?
        var previousTime: Int64 = -1
        for item in try root["frames"].list(1...100_000) {
            try item.exact("id operationGroup phase phaseLabel wallTimeMs elapsedMs board display native preview")
            let id = try item["id"].identifier()
            let group = try item["operationGroup"].identifier()
            try exchangeRequire(ids.insert(id).inserted, "重复帧标识")
            if previousGroup != group {
                try exchangeRequire(groups.insert(group).inserted, "操作组不连续")
                previousGroup = group
            }
            let phase = try item["phase"].choice("input evidence result applied other")
            let label = try item["phaseLabel"].text(extended ? 16 * 1024 * 1024 : 65_535)
            let elapsed = Int64(try item["elapsedMs"].number(times))
            try exchangeRequire(elapsed >= previousTime && elapsed <= result.elapsedMillis, "回放时间顺序错误")
            previousTime = elapsed
            let board = try readBoard(item["board"])
            var frame = NativeReplayFrame(
                operationID: Int64(groups.count - 1), wallTimeMillis: Int64(try item["wallTimeMs"].number(times)),
                elapsedMillis: elapsed,
                kind: ["input", "evidence", "result"].contains(phase) ? "foreign-method" : "foreign-action",
                label: label, page: BoardPage(board: board))
            frame.id = id
            frame.operationGroup = group
            frame.phase = phase
            frame.text = label
            let objects = try item["display"].list(0...10_000)
            var objectIDs = Set<String>()
            var unknown = false
            var partial = false
            for object in objects {
                let objectID = try object["id"].identifier()
                let type = try object["type"].identifier()
                try exchangeRequire(objectIDs.insert(objectID).inserted, "重复显示对象")
                let required = try object["required"].flag()
                let important = try object["important"].flag()
                _ = try object["z"].number(-32_768...32_767)
                if known.contains(type) {
                    try validateDisplay(object, type: type)
                } else {
                    try exchangeRequire(!required, "含无法识别的必需显示对象")
                    try object.boundedStrings()
                    unknown = true
                    partial = partial || important
                }
            }
            frame.displayJSON = item["display"].canonical()
            let records = try item["native"].list(0...256)
            let preview = item["preview"]
            if !records.isEmpty || !preview.isNull {
                let expected = binding(item)
                var namespaces = Set<String>()
                for record in records {
                    try record.exact("namespace version binding data")
                    try exchangeRequire(namespaces.insert(try record["namespace"].identifier()).inserted, "原生数据命名重复")
                    _ = try record["version"].number(1...65535)
                    try exchangeRequire(expected == digest(record["binding"]), "原生数据绑定失效")
                    _ = try blob(record["data"])
                }
                if !preview.isNull {
                    try preview.exact("mime coverage binding data")
                    _ = try preview["mime"].choice("image/png")
                    _ = try preview["coverage"].choice("full-frame")
                    try exchangeRequire(expected == digest(preview["binding"]), "预览绑定失效")
                    let png = try blob(preview["data"])
                    try ReplayExchangePNG.validate(png)
                    if partial { frame.previewPNG = png }
                }
            }
            if partial {
                frame.notices = [preview.isNull ? partialNotice : previewNotice]
                frame.incompleteDisplay = preview.isNull
            } else if unknown {
                frame.notices = [optionalNotice]
            }
            result.frames.append(frame)
        }
        if !root["source"].isNull {
            let source = root["source"]
            try source.exact("fileSha256 frameIds")
            _ = try digest(source["fileSha256"])
            for id in try source["frameIds"].list(1...100_000) { _ = try id.identifier() }
        }
        for loss in try root["losses"].list(0...100_000) {
            try loss.exact("frameId namespace reason")
            _ = try loss["frameId"].identifier()
            _ = try loss["namespace"].identifier()
            _ = try loss["reason"].text()
        }
        result.originalBytes = data
        return result
    }

    private static func readBoard(_ object: FrameJSON) throws -> NativeBoardSnapshot {
        try object.exact("values fixed candidates userCandidates")
        let board = NativeBoardSnapshot(
            values: try object["values"].list(81...81).map { UInt8(try $0.number(0...9)) },
            fixed: try object["fixed"].list(81...81).map { try $0.flag() },
            candidates: try object["candidates"].list(81...81).map { UInt16(try $0.number(0...511)) },
            userCandidates: try object["userCandidates"].list(81...81).map { UInt16(try $0.number(0...511)) })
        try board.validate()
        return board
    }

    private static func validateDisplay(_ o: FrameJSON, type: String) throws {
        let additional: String
        switch type {
        case "mark": additional = "shape bounds anchor color width initial conclusion outline"
        case "highlight": additional = "bounds anchor fill"
        case "line": additional = "points color width dash arrow"
        case "region": additional = "points fill stroke width"
        default: additional = "at text color fontSize align"
        }
        try o.exact("id type required important z group " + additional)
        if !o["group"].isNull { _ = try o["group"].identifier() }
        let fields = try o.fields
        func has(_ name: String) -> Bool { fields[Data(name.utf8)] != nil }
        func coords(_ value: FrameJSON, count: Int) throws -> [Int] {
            try value.list(count...count).map { try $0.number(-500_000...1_500_000) }
        }
        func color(_ value: FrameJSON) throws {
            let s = try value.text(9)
            try exchangeRequire(
                s.utf8.count == 9 && s.first == "#"
                    && s.utf8.dropFirst().allSatisfy {
                        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                    }, "颜色无效")
        }
        if has("bounds") {
            let box = try coords(o["bounds"], count: 4)
            try exchangeRequire(box[0] < box[2] && box[1] < box[3], "图形边界错误")
        }
        if !o["anchor"].isNull {
            try o["anchor"].exact("cell digit")
            _ = try o["anchor"]["cell"].number(0...80)
            _ = try o["anchor"]["digit"].number(0...9)
        }
        for name in ["color", "fill", "stroke"] where has(name) { try color(o[name]) }
        if has("width") { _ = try o["width"].number(1...100_000) }
        if has("points") {
            let points = try o["points"].list((type == "region" ? 3 : 2)...4096).map { try coords($0, count: 2) }
            if type == "line" { try exchangeRequire(points.dropFirst().contains { $0 != points[0] }, "线段长度为零") }
        }
        switch type {
        case "mark":
            _ = try o["shape"].choice("circle cross")
            _ = try o["initial"].flag()
            _ = try o["conclusion"].flag()
            if !o["outline"].isNull {
                let outline = o["outline"]
                try outline.exact("color width gap")
                try color(outline["color"])
                _ = try outline["width"].number(1...100_000)
                _ = try outline["gap"].number(0...100_000)
            }
        case "line":
            _ = try o["dash"].choice("solid dashed")
            _ = try o["arrow"].choice("none start end both")
        case "text":
            _ = try coords(o["at"], count: 2)
            _ = try o["text"].text()
            _ = try o["fontSize"].number(1000...500_000)
            _ = try o["align"].choice("left center right")
        default: break
        }
    }

    static func encode(_ document: NativeReplayDocument) throws -> Data {
        if document.format == .frame01 || document.format == .frame02 {
            guard let original = document.originalBytes else { throw ReplayExchangeError("缺少导入原件") }
            let source = try decode(original)
            try exchangeRequire(
                source.frames == document.frames && source.id == document.id && source.startedAt == document.startedAt
                    && source.endedAt == document.endedAt && source.elapsedMillis == document.elapsedMillis
                    && source.completed == document.completed, "历史帧已改变，请从棋盘开新局")
            return original
        }
        try exchangeRequire((1...100_000).contains(document.frames.count), "帧数错误")
        // Emit frames incrementally to keep a second, base64-expanded copy of
        // the entire recording out of memory. Sorting below follows scalar order.
        var payload = Data("{\"format\":\"HRPL-FRAME/0.2\",\"frames\":[".utf8)
        for (index, frame) in document.frames.enumerated() {
            if let reason = frame.exchangeBlockReason { throw ReplayExchangeError("第 \(index+1) 帧：\(reason)") }
            let encoded = try exportFrame(frame).canonical()
            try exchangeRequire(payload.count + encoded.count + 2 <= maximumBytes - 12, "回放超过 128 MiB")
            if index > 0 { payload.append(44) }
            payload.append(encoded)
        }
        let meta = FrameJSON.record([
            "id": .string(document.id), "startedAtMs": .int(Int(document.startedAt)),
            "endedAtMs": .int(Int(document.endedAt)), "elapsedMs": .int(Int(document.elapsedMillis)),
            "completed": .bool(document.completed),
        ])
        let provenance: FrameJSON
        var losses = [FrameJSON]()
        if document.format == .javaV3, let original = document.originalBytes {
            provenance = .record([
                "fileSha256": .string(hash(original)), "frameIds": .array(document.frames.map { .string($0.id) }),
            ])
            for frame in document.frames where frame.incompleteDisplay == true {
                losses.append(
                    .record([
                        "frameId": .string(frame.id), "namespace": .string("org.hodoku.mac.v3"),
                        "reason": .string(frame.notices.joined(separator: "\n")),
                    ]))
            }
        } else {
            provenance = .null
        }
        payload.append(contentsOf: "],\"losses\":".utf8)
        payload.append(FrameJSON.array(losses).canonical())
        payload.append(contentsOf: ",\"session\":".utf8)
        payload.append(meta.canonical())
        payload.append(contentsOf: ",\"source\":".utf8)
        payload.append(provenance.canonical())
        payload.append(125)
        try exchangeRequire(payload.count <= maximumBytes - 12, "回放超过 128 MiB")
        let output = header + ReplayExchangePNG.wordBytes(payload.count) + payload
        _ = try decode(output)
        return output
    }

    private static func exportFrame(_ frame: NativeReplayFrame) throws -> FrameJSON {
        let board = frame.board
        try board.validate()
        let b = FrameJSON.record([
            "values": .array(board.values.map { .int(Int($0)) }), "fixed": .array(board.fixed.map(FrameJSON.bool)),
            "candidates": .array(board.candidates.map { .int(Int($0)) }),
            "userCandidates": .array(board.userCandidates.map { .int(Int($0)) }),
        ])
        var paragraphs = [frame.label]
        if frame.text != frame.label { paragraphs.append(frame.text) }
        if frame.incompleteDisplay == true { paragraphs += frame.notices }
        let description = paragraphs.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let phases = ["input", "evidence", "result", "applied", "other"]
        let phase =
            phases.contains(frame.phase)
            ? frame.phase : (frame.kind.hasSuffix("apply") || frame.kind == "manual" ? "applied" : "other")
        let unavailable = frame.incompleteDisplay == true
        let hasAnnotations =
            !frame.page.marks.isEmpty || !frame.page.ink.strokes.isEmpty
            || !frame.page.chains.paths.isEmpty || !frame.page.boxes.footprint.isEmpty
        var display = [FrameJSON]()
        if let geometry = frame.displayJSON {
            var reader = FrameJSONReader(geometry)
            display = try reader.read().list(0...10_000)
        }
        if unavailable && hasAnnotations && display.isEmpty {
            throw ReplayExchangeError("此帧保留的标记无法完整转换，请使用原样另存")
        }
        var marker: [String: FrameJSON] = [
            "id": .string("mac-native-view"), "type": .string("hodoku-native-view"),
            "required": .bool(false), "important": .bool(true), "z": .int(0),
        ]
        var png: Data?
        if !unavailable, let frozen = frame.previewPNG {
            png = try ReplayExchangePNG.carrier(from: frozen)
        } else if !unavailable && display.isEmpty && hasAnnotations {
            let view = BoardFrame(page: frame.page, selected: nil, reference: nil)
            png = try ReplayExchangePNG.carrier(from: BoardPainter.png(view))
        }
        if let png { marker["imageSha256"] = .string(hash(png)) }
        if png != nil || unavailable { display.append(.record(marker)) }
        var fields: [String: FrameJSON] = [
            "id": .string(frame.id), "operationGroup": .string(frame.operationGroup),
            "phase": .string(phase), "phaseLabel": .string(description), "wallTimeMs": .int(Int(frame.wallTimeMillis)),
            "elapsedMs": .int(Int(frame.elapsedMillis)), "board": b, "display": .array(display),
            "native": .array([]), "preview": .null,
        ]
        if let png {
            fields["preview"] = .record([
                "mime": .string("image/png"), "coverage": .string("full-frame"),
                "binding": .string(binding(.record(fields))), "data": .string(png.base64EncodedString()),
            ])
        }
        return .record(fields)
    }
}

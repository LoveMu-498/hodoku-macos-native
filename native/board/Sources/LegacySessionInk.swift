// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum LegacySessionInk {
    static func factory(_ method: String?, _ args: [LegacyBean]) throws -> LegacyBean {
        guard let text = args.first?.scalar, let raw = Data(base64Encoded: text) else {
            throw LegacySessionError.invalid("笔迹载荷无效。")
        }
        var input = ReplayJavaInput(data: raw)
        guard try input.byte() == 1 else { throw LegacySessionError.invalid("笔迹版本不受支持。") }
        if method == "coordinates", args.count == 1 {
            let count = try input.int()
            guard count >= 0, count == input.remaining / 16, input.remaining % 16 == 0 else {
                throw LegacySessionError.invalid("笔迹坐标长度不符。")
            }
            let points = LegacyBean("sudoku.DoodleCoordinates")
            points.compact = raw
            return points
        }
        guard method == "decode", args.count == 2, args[1].className == "sudoku.DoodleCoordinates" else {
            throw LegacySessionError.invalid("笔迹描述不受支持。")
        }
        let stroke = LegacyBean("sudoku.DoodleStroke")
        if try input.boolean() {
            stroke.fields["rgb"] = LegacyBean("int", String(try input.int()))
        }
        stroke.fields["widthFactor"] = LegacyBean("float", String(Float(bitPattern: UInt32(try input.number(4)))))
        func integer(_ name: String) throws { stroke.fields[name] = LegacyBean("int", String(try input.int())) }
        func flag(_ name: String) throws { stroke.fields[name] = LegacyBean("boolean", String(try input.boolean())) }
        try integer("anchorCell"); try integer("anchorDigit"); try integer("candidateMarkKind"); try integer("thoughtGroup")
        try flag("conclusionOutlined"); try flag("hypothesisStart")
        try integer("hypothesisConditionId"); try integer("hypothesisGroupKind"); try integer("conclusionSourceMask")
        try flag("proofOnly"); try integer("derivedSourceId"); try flag("contradictionWitness"); try flag("refutationResult")
        guard input.remaining == 0 else { throw LegacySessionError.invalid("笔迹载荷有多余数据。") }
        stroke.fields["points"] = args[1]
        return stroke
    }

    static func rgb(_ v: LegacyBean?) throws -> Int {
        guard let v = v, v.className != "null" else { return 0 }
        guard v.className == "java.awt.Color" else { throw LegacySessionError.invalid("颜色对象无效。") }
        if v.arguments.count == 1 { return try v.arguments[0].int() & 0xffffff }
        if v.arguments.count == 2 { return try v.arguments[0].int() & 0xffffff }
        let colors = ["red":0xff0000, "blue":0xff, "green":0xff00, "black":0, "white":0xffffff, "yellow":0xffff00,
                      "orange":0xffc800, "gray":0x808080, "pink":0xffafaf, "cyan":0xffff, "magenta":0xff00ff,
                      "lightgray":0xc0c0c0, "darkgray":0x404040]
        if let field = v.scalar?.lowercased(), let color = colors[field] { return color }
        guard v.arguments.count == 3 || v.arguments.count == 4 else { throw LegacySessionError.invalid("颜色值无效。") }
        let parts = try v.arguments.prefix(3).map { try $0.int() }
        guard parts.allSatisfy((0...255).contains) else { throw LegacySessionError.invalid("颜色分量无效。") }
        return parts[0] << 16 | parts[1] << 8 | parts[2]
    }

    static func state(_ values: [LegacyBean], mask: Int, restoringCurrent: Bool = false) throws -> InkToolState {
        guard (0...63).contains(mask) else { throw LegacySessionError.invalid("涂鸦分组无效。") }
        var result = InkToolState()
        result.consumedGroups = Set((0..<6).filter { mask & (1 << $0) != 0 })
        for v in values {
            guard v.className == "sudoku.DoodleStroke" else { throw LegacySessionError.invalid("笔迹对象无效。") }
            let group = try v.number("thoughtGroup", -1)
            let argb = try v["rgb"]?.int() ?? rgb(v["color"] ?? v.arguments.first)
            let drawnGroup = group == -1 ? ReplayJavaAnnotations.group(argb) : group
            guard (0..<6).contains(drawnGroup) else { throw LegacySessionError.invalid("笔迹色组无效。") }
            let cell = try v.number("anchorCell", -1), digit = try v.number("anchorDigit")
            let anchored = (0..<81).contains(cell) && (1...9).contains(digit)
            let factor = v["widthFactor"]?.scalar ?? v.arguments.dropFirst().first?.scalar ?? "0"
            guard let w = Float(factor), w.isFinite, w >= 0 else { throw LegacySessionError.invalid("笔宽无效。") }
            let width = CGFloat(w) / (anchored ? 9 : 1)
            let coords = v["points"]
            var points = [CGPoint]()
            if !anchored, let compact = coords?.compact {
                var input = ReplayJavaInput(data: compact); input.offset = 5
                while input.remaining > 0 {
                    points.append(CGPoint(x: Double(bitPattern: try input.number(8)), y: Double(bitPattern: try input.number(8))))
                }
            } else if !anchored {
                for p in coords?.elements ?? [] {
                    let x = p["x"]?.scalar ?? p.arguments.first?.scalar ?? "0"
                    let y = p["y"]?.scalar ?? p.arguments.dropFirst().first?.scalar ?? "0"
                    guard let a = Double(x), let b = Double(y) else { throw LegacySessionError.invalid("笔迹点无效。") }
                    points.append(CGPoint(x:a, y:b))
                }
            }
            // A single free-hand point is painted as a dot in Java.
            if points.count == 1 { points.append(points[0]) }
            if !anchored && points.isEmpty { continue }
            let kind = try v.number("candidateMarkKind")
            var ink = InkStroke(kind: anchored ? (kind == 2 ? .cross : .circle) : .line,
                                group: drawnGroup, width: width, points: points,
                                cell: anchored ? cell : nil, digit: anchored ? digit : nil)
            ink.witness = try v.flag("contradictionWitness")
            ink.light = ReplayJavaAnnotations.light(argb)
            ink.start = try v.flag("hypothesisStart")
            ink.outlined = try v.flag("conclusionOutlined")
            let sources = try v.number("conclusionSourceMask")
            ink.outlineSources = Set((0..<6).filter { sources & (1 << $0) != 0 })
            if try v.flag("proofOnly") { result.proofs[drawnGroup, default: []].append(ink) }
            else if try !v.flag("refutationResult") {
                result.strokes.append(ink)
                let rgb = argb & 0xffffff
                let exact = group >= 0 || AnnotationPalette.dark.contains(rgb) || AnnotationPalette.light.contains(rgb)
                if restoringCurrent && anchored && exact { result.consumedGroups.insert(drawnGroup) }
            }
        }
        try result.validate()
        return result
    }
}

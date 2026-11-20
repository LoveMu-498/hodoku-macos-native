// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Projection of a Java viewing frame. The branch is assembled separately from
/// authored geometry, never by copying technique highlights or historical ink.
struct ReplayJavaAnnotations {
    var shown: BoardPage
    var editable: BoardPage
    var descriptions = [String]()
    var notices = Set<String>()
    var hasDoodleStep = false
    var exchangeBlockReason: String?
    static let palette = [0xFFC059, 0xF7DE8F, 0xB1A5F3, 0xDCD4FC, 0xF7A5A7,
                          0xFFD2D2, 0x86E8D0, 0xCEFBED, 0x86F280, 0xD7FFD7]
    static func group(_ argb: Int) -> Int {
        let rgb = argb & 0xFFFFFF
        for i in AnnotationPalette.dark.indices {
            if rgb == AnnotationPalette.dark[i] || rgb == AnnotationPalette.light[i] { return i }
        }
        let colors = palette + [0x33CCFF, 0xB8E3FF]
        func distance(_ other: Int) -> Int {
            [0, 8, 16].reduce(0) { n, shift in
                let d = ((rgb >> shift) & 255) - ((other >> shift) & 255)
                return n + d*d
            }
        }
        return colors.indices.min { distance(colors[$0]) < distance(colors[$1]) }! / 2
    }

    static func light(_ argb: Int) -> Bool? {
        let rgb = argb & 0xFFFFFF
        let java = palette + [0x33CCFF, 0xB8E3FF]
        return AnnotationPalette.light.contains(rgb) || java.enumerated().contains { $0.offset % 2 == 1 && $0.element == rgb } ? true : nil
    }

    static func validAtom(_ value: Int) -> Bool {
        (1...809).contains(value) && (1...9).contains(value % 10)
    }
    init(board: NativeBoardSnapshot) {
        var page = BoardPage()
        page.board = board
        shown = page
        editable = page
    }
    static func mark(_ page: inout BoardPage, cell: Int, digit: Int, group: Int, light: Bool? = nil) {
        page.marks.removeAll { $0.cell == cell && $0.digit == digit }
        page.marks.append(BoardMark(cell: cell, digit: digit, color: group, light: light))
    }

    /// Prefix-only records use Windows K/M for authored color and G/R/C for
    /// viewing evidence. Unknown tags survive in originalBytes.
    mutating func overlay(_ source: String, nativeTail: Bool) throws {
        let lines = source.split(separator: "\n")
        guard lines.count <= 4096 else { throw ReplayJavaError.invalid }
        var activeNodes = [ChainToolNode](), activeEdges = [ChainToolEdge]()
        var completeNodes = [ChainToolNode](), fallback = [ChainToolNode](), completeEdges = [ChainToolEdge]()
        func node(_ a: ArraySlice<Substring>) throws -> ChainToolNode {
            let atoms = try a.map { token -> Int in
                guard let i = Int(token), Self.validAtom(i) else { throw ReplayJavaError.invalid }
                return i
            }
            guard !atoms.isEmpty, atoms.count <= 729 else { throw ReplayJavaError.invalid }
            return ChainToolNode(atoms: Array(Set(atoms)).sorted(), color: 5)
        }
        func path(_ raw: [ChainToolNode], _ edges: [ChainToolEdge]) -> ChainToolPath? {
            var nodes = raw
            if nodes.count > 2 && nodes.first == nodes.last { nodes.removeLast() }
            let p = ChainToolPath(nodes: nodes, edges: edges, closed: nodes.count > 2 && nodes.count == edges.count)
            return p.valid ? p : nil
        }
        var paths = [ChainToolPath]()
        var unboundPixelPaths = 0, projectedPaths = 0
        var multi = false, hasFrozenColors = false
        for line in lines {
            let words = line.split(whereSeparator: { $0.isWhitespace })
            guard let tag = words.first else { continue }
            func num(_ i: Int, _ range: ClosedRange<Int>) throws -> Int {
                guard i < words.count, let n = Int(words[i]), range.contains(n) else { throw ReplayJavaError.invalid }
                return n
            }
            switch tag {
            case "CD":
                descriptions.append(String(line.dropFirst(3)))
            case "K", "M":
                let isCell = tag == "K", n = try num(1, 0...809), slot = try num(2, 0...9)
                guard isCell ? n < 81 : Self.validAtom(n) else { throw ReplayJavaError.invalid }
                Self.mark(&shown, cell: isCell ? n : n/10, digit: isCell ? 0 : n%10, group: slot / 2, light: slot % 2 == 1 ? true : nil)
                Self.mark(&editable, cell: isCell ? n : n/10, digit: isCell ? 0 : n%10, group: slot / 2, light: slot % 2 == 1 ? true : nil)
            case "G", "R", "C":
                hasFrozenColors = hasFrozenColors || words.count >= 3
                let cell = try num(1, 0...80)
                for i in 2..<words.count {
                    Self.mark(&shown, cell: cell, digit: try num(i, 1...9), group: tag == "G" ? 4 : tag == "R" ? 2 : 3)
                }
            case "B":
                let group = try num(5, 0...9)/2
                for i in 6..<words.count {
                    let cell = try num(i, 0...80)
                    shown.boxes.groups[group].insert(cell)
                    editable.boxes.groups[group].insert(cell)
                }
            case "CG": activeNodes.append(try node(words.dropFirst()))
            case "CS": activeEdges.append(ChainToolEdge(strong: try num(1, 0...1) == 1, color: 5))
            case "UC":
                if let p = path(completeNodes.isEmpty ? fallback : completeNodes, completeEdges) { paths.append(p) }
                completeNodes = []; fallback = []; completeEdges = []
            case "UN":
                fallback = try words.dropFirst().map { try node([$0][...]) }
            case "UG": completeNodes.append(try node(words.dropFirst()))
            case "UL": completeEdges = try (1..<words.count).map { ChainToolEdge(strong: try num($0, 0...1) == 1, color: 5) }
            case "CH": break // next draft digit
            case "MT":
                multi = try num(1, 0...1) == 1
            case "P": unboundPixelPaths += 1
            case "DM1":
                guard !nativeTail else { continue }
                let cell = try num(1, 0...80), digit = try num(2, 1...9), kind = try num(3, 1...2)
                let group = try num(4, -1...5), rgb = try num(5, Int(Int32.min)...Int(Int32.max))
                guard words.count == 13, let width = Double(words[6]), width.isFinite, width > 0, width <= 10,
                      let radius = Double(words[7]), radius.isFinite, radius > 0, radius <= 100 else { throw ReplayJavaError.invalid }
                let flags = try num(8, 0...15)
                _ = try num(9, 0...Int(Int32.max)); _ = try num(10, 0...2); _ = try num(11, -1...5)
                projectedPaths += try num(12, 0...3)
                var ink = InkStroke(kind: kind == 2 ? .cross : .circle, group: group < 0 ? Self.group(rgb) : group,
                                    width: min(0.2, width / 9), cell: cell, digit: digit)
                ink.light = Self.light(rgb); ink.start = flags & 2 != 0; ink.outlined = flags & 1 != 0; ink.witness = flags & 4 != 0
                addObserved(ink)
            case "O":
                guard !nativeTail else { continue }
                if words.count == 6 {
                    for i in 1...5 { _ = try num(i, Int(Int32.min)...Int(Int32.max)) }
                    notices.insert("部分观看。此笔迹缺少画布坐标。")
                    exchangeBlockReason = "此帧的像素笔迹缺少画布坐标，无法转换为 FRAME。"
                    continue
                }
                guard words.count == 10 || words.count == 11 else { throw ReplayJavaError.invalid }
                let relative = words.count == 11
                let rgb = try num(1, Int(Int32.min)...Int(Int32.max)), kind = try num(2, 0...2)
                let cell = try num(3, -1...80), digit = try num(4, -1...9)
                let outlined = try num(5, 0...1) == 1, start = relative ? try num(6, 0...1) == 1 : false
                let coords = try words.suffix(4).map { word -> Double in
                    guard let n = Double(word), n.isFinite, relative ? abs(n) <= 100000 : (0...1).contains(n) else { throw ReplayJavaError.invalid }
                    return n
                }
                if kind == 0 {
                    guard cell == -1 && digit == -1 else { throw ReplayJavaError.invalid }
                    if relative && coords.allSatisfy({ abs($0) < 1024 }) {
                        let points = [CGPoint(x:coords[0],y:coords[1]),CGPoint(x:coords[2],y:coords[3])]
                        shown.ink.strokes.append(InkStroke(kind:.ellipse,group:Self.group(rgb),width:0.035/9,points:points,light:Self.light(rgb)))
                    } else {
                        notices.insert("部分观看。此笔迹缺少可用的棋盘坐标。")
                        exchangeBlockReason = "此帧的自由笔迹缺少可用的棋盘坐标，无法转换为 FRAME。"
                    }
                } else {
                    guard cell >= 0, digit >= 1 else { throw ReplayJavaError.invalid }
                    var ink = InkStroke(kind:kind == 2 ? .cross : .circle,group:Self.group(rgb),width:0.035/9,cell:cell,digit:digit,light:Self.light(rgb))
                    ink.outlined = outlined; ink.start = start
                    addObserved(ink)
                }
            default:
                notices.insert("部分观看。部分历史标记仅保存在原回放中。")
            }
        }
        if !nativeTail && unboundPixelPaths > projectedPaths {
            notices.insert("部分观看。未记录画布尺寸的像素笔迹仅保存在原回放中。")
            exchangeBlockReason = "此帧的像素笔迹缺少画布坐标，无法转换为 FRAME。"
        }
        if !nativeTail && multi && !hasFrozenColors {
            notices.insert("部分观看。此帧缺少多组推理的着色结果。")
            exchangeBlockReason = "此帧缺少多组推理的着色结果，无法转换为 FRAME。"
        }
        if let p = path(activeNodes, activeEdges) { paths.append(p) }
        else if !activeNodes.isEmpty { notices.insert("部分观看。此链的部分连线未记录。") }
        if let p = path(completeNodes.isEmpty ? fallback : completeNodes, completeEdges) { paths.append(p) }
        if !paths.isEmpty { shown.chains.paths = paths; editable.chains.paths = paths }
    }

    private mutating func addObserved(_ ink: InkStroke) {
        if shown.ink.strokes.contains(where: { $0.cell == ink.cell && $0.digit == ink.digit && $0.kind == ink.kind && $0.group == ink.group }) { return }
        shown.ink.strokes.append(ink)
        if ink.start || ink.outlined || ink.witness || ink.cell.map({ shown.board.values[$0] != 0 || (shown.board.candidates[$0] & NativeBoardSnapshot.bit(UInt8(ink.digit!))) == 0 }) == true {
            notices.insert("部分观看。此历史候选标记的轮廓或背景详见原回放。")
        }
    }

    static func geometry(_ bytes: Data, pending: Bool) throws -> (BoxToolState, ChainToolState) {
        var r = ReplayJavaInput(data: bytes)
        guard try r.int() == 0x48524157 else { throw ReplayJavaError.invalid }
        let version = try r.int(), source = try r.utf(), status = try r.utf(), problem = try r.utf()
        let edge = try r.int(), proof = try r.blob()
        guard (1...2).contains(version), ["BOX","FREE_CHAIN"].contains(source), (-1...4096).contains(edge),
              ["PENDING","NATIVE_MATCH","INCOMPLETE","INVALID","NO_CONCLUSION","PROVEN","ASSUMED"].contains(status),
              ["NONE","MISSING_CANDIDATE","DUPLICATE_NODE","RELATION_COUNT","INVALID_WEAK","INVALID_STRONG","DISCONNECTED_INPUT","BRANCHED_INPUT","CONFLICTING_EDGE","INVALID_GROUP"].contains(problem),
              !pending || (status == "PENDING" && proof.isEmpty) else { throw ReplayJavaError.invalid }
        if !proof.isEmpty { try ReplayJavaProof.validate(proof) }
        var boxes = BoxToolState(), chains = ChainToolState()
        for group in 0..<(try r.count(6)) {
            for _ in 0..<(try r.count(4096)) { boxes.groups[group].insert(try r.count(80)) }
        }
        for _ in 0..<(try r.count(4096)) {
            _ = try r.long()
            let closed = try r.boolean(), active = try r.boolean(), strong = try r.boolean()
            _ = try r.utf()
            var nodes = [ChainToolNode](), edges = [ChainToolEdge]()
            for _ in 0..<(try r.count(4096)) {
                let cell = try r.count(80), digit = try r.int()
                guard (1...9).contains(digit) else { throw ReplayJavaError.invalid }
                let color = try r.boolean() ? Self.group(try r.int()) : 5
                var atoms = [Int]()
                for _ in 0..<(try r.count(version == 1 ? 3 : 729)) {
                    let atom = version == 1 ? try r.count(80)*10 + digit : try r.int()
                    guard validAtom(atom) else { throw ReplayJavaError.invalid }
                    atoms.append(atom)
                }
                nodes.append(ChainToolNode(atoms: atoms.isEmpty ? [cell*10+digit] : Array(Set(atoms)).sorted(), color: color))
            }
            for i in 0..<(try r.count(4096)) {
                let value = try r.byte()
                guard value <= 1 else { throw ReplayJavaError.invalid }
                edges.append(ChainToolEdge(strong: value == 1, color: i < nodes.count ? nodes[i].color : 5))
            }
            for i in 0..<(try r.count(4096)) {
                let color = try r.boolean() ? Self.group(try r.int()) : 5
                if i < edges.count { edges[i].color = color }
            }
            let path = ChainToolPath(nodes: nodes, edges: edges, closed: closed)
            if path.valid {
                if active { chains.active = chains.paths.count; chains.nextStrong = strong }
                chains.paths.append(path)
            }
        }
        for _ in 0..<(try r.count(4096)) { _ = try r.utf() }
        guard r.remaining == 0 else { throw ReplayJavaError.invalid }
        return (boxes, chains)
    }

    mutating func tail(_ r: inout ReplayJavaInput, version: Int, overlay text: String) throws {
        let native = try r.boolean(), bytes = try r.blob()
        try overlay(text, nativeTail: native)
        if !bytes.isEmpty {
            let (boxes, chains) = try Self.geometry(bytes, pending: true)
            shown.boxes = boxes; shown.chains = chains
            editable.boxes = boxes; editable.chains = chains
        }
        for isCandidate in [false, true] {
            for _ in 0..<(try r.count(729)) {
                let key = try r.int(), rgb = try r.int(), group = Self.group(rgb)
                guard isCandidate ? Self.validAtom(key) : (0..<81).contains(key) else { throw ReplayJavaError.invalid }
                let cell = isCandidate ? key/10 : key, digit = isCandidate ? key%10 : 0
                Self.mark(&shown, cell: cell, digit: digit, group: group, light: Self.light(rgb))
                if native { Self.mark(&editable, cell: cell, digit: digit, group: group, light: Self.light(rgb)) }
            }
        }
        if version >= 3 { guard try (-1...5).contains(r.int()) else { throw ReplayJavaError.invalid } }
        for _ in 0..<(try r.count(4096)) {
            let rgb = try r.int(), width = CGFloat(Float(bitPattern: UInt32(try r.number(4))))
            let cell = try r.int(), digit = try r.int()
            let kind = version >= 2 ? try r.byte() : 0
            let group = version >= 2 ? try r.int() : -1
            let outlined = version >= 3 ? try r.boolean() : false
            let start = version >= 4 ? try r.boolean() : false
            let condition = version >= 4 ? try r.int() : 0
            let groupKind = version >= 4 ? try r.byte() : 0
            let witness = version >= 4 ? try r.boolean() : false
            let refutation = version >= 4 ? try r.boolean() : false
            let anchored = (0..<81).contains(cell) && (1...9).contains(digit)
            guard width.isFinite, width > 0, width <= 10, kind <= 2, (-1...5).contains(group),
                  condition >= 0, groupKind <= 2, (cell == -1 || anchored), (kind == 0 || anchored),
                  (!(start || witness || refutation) || (group >= 0 && anchored)),
                  !refutation || (!start && outlined) else { throw ReplayJavaError.invalid }
            let n = try r.count(100000)
            guard kind != 2 || n == 4 else { throw ReplayJavaError.invalid }
            var points = [CGPoint]()
            for _ in 0..<n {
                let x = Double(bitPattern: try r.number(8)), y = Double(bitPattern: try r.number(8))
                guard x.isFinite, y.isFinite, abs(x)<=100000, abs(y)<=100000 else { throw ReplayJavaError.invalid }
                if !anchored { points.append(CGPoint(x: x, y: y)) }
            }
            let nativeWidth = anchored ? width / 9 : width
            guard nativeWidth <= 0.2, points.allSatisfy({ abs($0.x)<1024 && abs($0.y)<1024 }), anchored || points.count >= 2 else {
                notices.insert("部分观看。部分历史笔迹仅保存在原回放中。"); continue
            }
            var ink = InkStroke(kind: anchored ? (kind == 2 ? .cross : .circle) : .line,
                                group: group < 0 ? Self.group(rgb) : group, width: nativeWidth, points: points,
                                cell: anchored ? cell : nil, digit: anchored ? digit : nil)
            ink.light = Self.light(rgb); ink.witness = witness; ink.start = start; ink.outlined = outlined
            if native || !anchored { shown.ink.strokes.append(ink) } else { addObserved(ink) }
            if start || witness || outlined || refutation {
                notices.insert("部分观看。历史笔迹的分组推理与轮廓详见原回放。")
            }
            if native {
                // Inverse results, witnesses and grouped prerequisites are frozen
                // facts. A fresh Swift board cannot adopt Java's solver capsule.
                if witness || refutation || groupKind != 0 || condition != 0 || (anchored && group < 0) { continue }
                ink.outlined = false; ink.start = false
                editable.ink.strokes.append(ink)
            }
        }
        if version >= 5 {
            let step = try r.blob()
            if !step.isEmpty {
                var capsule = ReplayJavaInput(data: step)
                guard try capsule.int() == 0x48445331, try (1...2).contains(capsule.int()) else { throw ReplayJavaError.invalid }
                hasDoodleStep = true
                notices.insert("部分观看。此历史推理的详细证明仅保存在原回放中。")
            }
            _ = try r.utf(version >= 6)
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension ReplayJavaCodec {
    /// Java's explicit Windows copy still has a complete HMX tail. The legacy
    /// viewer stops at the shared prefix. Preserve unknown evidence verbatim.
    static func encodeWindows(_ doc: NativeReplayDocument) throws -> Data {
        guard doc.format == .javaV3 || doc.format == .native else { throw ReplayJavaError.windows }
        let original = Data(try encode(doc)) // offsets below are relative to the file header
        var r = ReplayJavaInput(data:original), w = ReplayJavaOutput()
        _ = try r.bytes(8); _ = try r.utf(); _ = try r.bytes(25)
        let n = try r.count(100000)
        w.data.append(original.prefix(r.offset))
        var common = [String](), slices = [(Range<Int>,Range<Int>)]()
        for _ in 0..<n {
            let begin = r.offset
            _ = try r.bytes(24); _ = try r.utf()
            let labelEnd = r.offset
            common.append(try r.utf())
            let boardStart = r.offset; _ = try r.bytes(487)
            slices.append((begin..<labelEnd,boardStart..<r.offset))
        }
        guard r.remaining != 0 else { return original } // already a standalone Windows prefix
        _ = try r.int()
        let version = try r.int(), foreign = try r.boolean()
        _ = try r.boolean(); _ = try r.boolean()
        let interruption = try r.utf(version == 6)
        _ = try r.int()
        var tail = ReplayJavaOutput()
        tail.int(0x484d5831); tail.int(max(5,version)); tail.boolean(foreign)
        tail.boolean(false); tail.boolean(false)
        try tail.utf(interruption.isEmpty ? "" : "异常中断",long:version==6)
        tail.int(n)
        for i in 0..<n {
            let kind = try r.utf()
            let label = version == 6 ? try r.utf(true) : doc.frames[i].label
            let overlay = version == 6 ? try r.utf(true) : common[i]
            let evidence = try r.blob()
            let annot = try WindowsV3Annotations(&r,version:version,overlay:overlay)
            let projected = try annot.project(overlay)
            // Windows DataInputStream only reads the shared modified UTF field.
            // A placeholder there would hide the recording from the chosen reader.
            var checked = ReplayJavaOutput()
            do { try checked.utf(label); try checked.utf(projected) } catch { throw ReplayJavaError.windows }
            let prefix = slices[i].0
            w.data.append(original[prefix.lowerBound..<prefix.lowerBound+24])
            w.data.append(checked.data); w.data.append(original[slices[i].1])
            try tail.utf(kind)
            if version == 6 { try tail.utf(label,long:true); try tail.utf(projected,long:true) }
            tail.int(evidence.count); tail.data.append(evidence)
            tail.data.append(annot.tail.data)
            guard w.data.count + tail.data.count <= maxBytes else { throw ReplayJavaError.windows }
        }
        w.data.append(tail.data)
        w.data.append(try r.bytes(r.remaining))
        guard w.data.count <= maxBytes else { throw ReplayJavaError.windows }
        return w.data
    }
}

private struct WindowsV3Annotations {
    struct Mark {
        var cell:Int, digit:Int, kind:Int, group:Int, rgb:Int
        var width:Float, radius:Double, flags:Int, condition:Int, groupKind:Int
        var key:String { "\(cell):\(digit):\(kind):\(rgb)" }
        var eligible:Bool { cell >= 0 && digit >= 1 && kind > 0 && groupKind == 0 && flags & 12 == 0 }
        func structured(visible:Int) -> String {
            "DM1 \(cell) \(digit) \(kind) \(group) \(rgb) \(width) \(radius) \(flags) \(condition) \(groupKind) \(visible) 0\n"
        }
        func observed(visible:Int) -> String {
            let x = (Double(cell%9)+(Double((digit-1)%3)+0.5)/3)/9
            let y = (Double(cell/9)+(Double((digit-1)/3)+0.5)/3)/9, r = 0.1/9
            let outline = flags & 1 != 0 && visible == group ? 1 : 0
            return "O \(rgb) \(kind) \(cell) \(digit) \(outline) \(x-r) \(y-r) \(x+r) \(y+r)\n"
        }
    }
    let native:Bool, visible:Int
    var marks = [Mark]()
    var tail = ReplayJavaOutput()

    init(_ r:inout ReplayJavaInput,version:Int,overlay:String) throws {
        let header = r.offset
        native = try r.boolean()
        _ = try r.blob()
        for _ in 0..<2 { _ = try r.bytes(r.count(729)*8) }
        let headerEnd = r.offset
        tail.data.append(r.data[header..<headerEnd])
        visible = version >= 3 ? try r.int() : -1
        tail.int(visible)
        let count = try r.count(4096); tail.int(count)
        for _ in 0..<count {
            let rgb = try r.int(), widthBits = UInt32(try r.number(4)), width = Float(bitPattern:widthBits)
            let cell = try r.int(), digit = try r.int()
            let storedKind = version >= 2 ? Int(try r.byte()) : 0
            let kind = storedKind == 0 && cell >= 0 ? 1 : storedKind
            let group = version >= 2 ? try r.int() : -1
            let outlined = version >= 3 ? try r.boolean() : false
            let start = version >= 4 ? try r.boolean() : false
            let condition = version >= 4 ? try r.int() : 0
            let groupKind = version >= 4 ? Int(try r.byte()) : 0
            let witness = version >= 4 ? try r.boolean() : false, inverse = version >= 4 ? try r.boolean() : false
            let flags = (outlined ? 1:0) | (start ? 2:0) | (witness ? 4:0) | (inverse ? 8:0)
            tail.int(rgb); tail.number(widthBits); tail.int(cell); tail.int(digit); tail.byte(UInt8(kind))
            tail.int(group); tail.boolean(outlined); tail.boolean(start && (native || group >= 0))
            tail.int(condition); tail.byte(UInt8(groupKind)); tail.boolean(witness); tail.boolean(inverse)
            let points = try r.count(100000); tail.int(points)
            let begin = r.offset
            var radius = 0.0
            for _ in 0..<points {
                let x = try r.number(8), y = try r.number(8)
                radius = max(radius,abs(Double(bitPattern:x)),abs(Double(bitPattern:y)))
            }
            tail.data.append(r.data[begin..<r.offset])
            if kind != 0 {
                marks.append(Mark(cell:cell,digit:digit,kind:kind,group:group,rgb:rgb,width:width,radius:radius,
                                  flags:flags,condition:condition,groupKind:groupKind))
            }
        }
        if version >= 5 {
            let begin = r.offset
            _ = try r.blob(); _ = try r.utf(version == 6)
            tail.data.append(r.data[begin..<r.offset])
        } else {
            tail.int(0); try tail.utf(overlay)
        }
    }

    func project(_ overlay:String) throws -> String {
        guard native else { return overlay }
        let lines = overlay.components(separatedBy:"\n")
        var existing = Set<String>(), represented = Set<String>(), skip = Set<Int>()
        var additions = [Int:String](), removed = [Int:Int](), metadata = [Int:[String]]()
        var contours = [Int](), lastMark = -1
        for line in lines {
            let t = line.split(whereSeparator:{ $0.isWhitespace })
            if t.first == "O", (10...11).contains(t.count), t[2] != "0" {
                existing.insert("\(t[3]):\(t[4]):\(t[2]):\(t[1])")
            }
        }
        for (i,line) in lines.enumerated() {
            let t = line.split(whereSeparator:{ $0.isWhitespace }).map(String.init)
            guard t.first == "DM1" else { continue }
            guard t.count==13, let cell=Int(t[1]), let digit=Int(t[2]), let kind=Int(t[3]),
                  let group=Int(t[4]), let rgb=Int(t[5]), let width=Float(t[6]),let radius=Double(t[7]),
                  let flags=Int(t[8]),let condition=Int(t[9]),let groupKind=Int(t[10]),let paths=Int(t[12]),
                  (0...3).contains(paths), (0..<81).contains(cell), (1...9).contains(digit) else { throw ReplayJavaError.windows }
            let mark = Mark(cell:cell,digit:digit,kind:kind,group:group,rgb:rgb,width:width,radius:radius,flags:flags,condition:condition,groupKind:groupKind)
            represented.insert(mark.key); lastMark=i
            let base = paths == 0 ? 0 : kind == 2 ? 2 : 1
            if paths > base { contours.append(i) }
            guard mark.eligible else { continue }
            metadata[i]=t; removed[i]=0
            if existing.insert(mark.key).inserted { additions[i]=mark.observed(visible:visible) }
            let end = i+base+1
            if paths >= base && end <= lines.count && lines[i+1..<end].allSatisfy({ $0.hasPrefix("P ") }) {
                skip.formUnion(i+1..<end); removed[i]=base
            }
        }
        let missing = marks.filter { $0.eligible && represented.insert($0.key).inserted }
        guard !metadata.isEmpty || !missing.isEmpty else { return overlay }
        let pixels = lines.indices.filter { $0 > lastMark && lines[$0].hasPrefix("P ") }
        if pixels.count >= contours.count {
            let suffix = pixels.suffix(contours.count)
            if suffix.allSatisfy({ lines[$0].hasPrefix("P -15242753 ") }) {
                for (mark,pixel) in zip(contours,suffix) where metadata[mark] != nil {
                    skip.insert(pixel); removed[mark, default:0] += 1
                }
            }
        }
        var output = ""
        for i in lines.indices where !skip.contains(i) {
            if var words = metadata[i], let n=removed[i], n > 0 {
                words[12]=String(Int(words[12])!-n); output += words.joined(separator:" ")
            } else { output += lines[i] }
            if i < lines.count-1 || additions[i] != nil { output += "\n" }
            if let addition = additions[i] { output += addition }
        }
        for mark in missing {
            guard mark.radius > 0 else { throw ReplayJavaError.windows }
            if !output.isEmpty && !output.hasSuffix("\n") { output += "\n" }
            output += mark.structured(visible:visible)
            if existing.insert(mark.key).inserted { output += mark.observed(visible:visible) }
        }
        return output
    }
}

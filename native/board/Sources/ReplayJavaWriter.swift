// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension ReplayJavaCodec {
    /// V3 has no frozen image or general native frame capsule. For a new file
    /// write only representable histories. FRAME is the full recording export.
    static func encode(_ doc: NativeReplayDocument) throws -> Data {
        if let bytes = doc.originalBytes {
            guard doc.format == .javaV3, try decode(bytes) == doc else { throw ReplayJavaError.conversion }
            return bytes
        }
        guard validID(doc.id), (1...100000).contains(doc.frames.count), doc.bookmarks.count <= 10000,
              doc.elapsedMillis >= 0 else { throw ReplayJavaError.invalid }
        let origin = doc.sourceReplayID ?? ""
        let originIndex = doc.sourceFrameIndex ?? -1
        guard (origin.isEmpty && originIndex == -1) || (validID(origin) && (0..<100000).contains(originIndex)) else { throw ReplayJavaError.invalid }
        for marker in doc.bookmarks where !doc.frames.indices.contains(marker.frameIndex) || marker.name.utf16.count > 1000 { throw ReplayJavaError.invalid }
        let foreign = doc.frames.allSatisfy { ["foreign-action","foreign-method"].contains($0.kind) }
        var overlays = [String]()
        let empty = Data()
        for f in doc.frames {
            try f.page.board.validate()
            guard f.previewPNG == nil, f.displayJSON == nil, f.notices.isEmpty,
                  f.branchPage == nil || f.branchPage == f.page,
                  f.page.ink == InkToolState(), f.page.chains == ChainToolState(),
                  !f.text.contains("\r"), f.text.utf8.count <= 4*1024*1024 else { throw ReplayJavaError.conversion }
            var lines = [String]()
            for mark in f.page.marks {
                guard (0..<81).contains(mark.cell), (0...9).contains(mark.digit), (0..<5).contains(mark.color) else { throw ReplayJavaError.conversion }
                lines.append(mark.digit == 0 ? "K \(mark.cell) \(mark.swatch)" : "M \(mark.cell*10+mark.digit) \(mark.swatch)")
            }
            try f.page.boxes.validate()
            for (group, cells) in f.page.boxes.groups.enumerated() where !cells.isEmpty {
                guard group < 5 else { throw ReplayJavaError.conversion }
                lines.append("B 0 0 0 0 \(group*2) " + cells.sorted().map(String.init).joined(separator: " "))
            }
            if !f.text.isEmpty { lines += f.text.components(separatedBy: "\n").map { "CD " + $0 } }
            overlays.append(lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")
        }
        try validate(doc, foreign: foreign, evidence: Array(repeating: empty, count: doc.frames.count))
        for (a,b) in zip(doc.frames, doc.frames.dropFirst()) {
            guard b.operationID >= a.operationID && b.elapsedMillis >= a.elapsedMillis else { throw ReplayJavaError.invalid }
        }
        func modifiedLength(_ s: String) -> Int { s.utf16.reduce(0) { $0 + ((1...127).contains($1) ? 1 : $1 < 2048 ? 2 : 3) } }
        let useLong = (doc.frames.map(\.label) + overlays + doc.bookmarks.map(\.name)).contains { modifiedLength($0) > 65535 }
        var w = ReplayJavaOutput()
        w.int(0x4852504c); w.int(3); try w.utf(doc.id)
        w.number(doc.startedAt); w.number(doc.elapsedMillis); w.number(doc.endedAt); w.boolean(doc.completed); w.int(doc.frames.count)
        for (f, overlay) in zip(doc.frames, overlays) {
            w.number(f.operationID); w.number(f.wallTimeMillis); w.number(f.elapsedMillis)
            try w.utf(modifiedLength(f.label) <= 65535 ? f.label : "[Full explanation is stored in the HoDoKu Mac extension; this reader cannot display it.]")
            try w.utf(modifiedLength(overlay) <= 65535 ? overlay : "[Full annotations is stored in the HoDoKu Mac extension; this reader cannot display it.]")
            w.boolean(f.kind == "foreign-method")
            let b = f.page.board
            for i in 0..<81 { w.byte(b.values[i]); w.boolean(b.fixed[i]); w.number(b.candidates[i]); w.number(b.userCandidates[i]) }
            guard w.data.count <= maxBytes else { throw ReplayJavaError.invalid }
        }
        w.int(0x484d5831); w.int(useLong ? 6 : 5); w.boolean(foreign); w.boolean(doc.retained); w.boolean(doc.pinned)
        try w.utf("", long: useLong); w.int(doc.frames.count)
        for (f, overlay) in zip(doc.frames, overlays) {
            try w.utf(f.kind)
            if useLong { try w.utf(f.label, long: true); try w.utf(overlay, long: true) }
            w.int(0) // frame evidence
            w.boolean(true)
            var geometry = ReplayJavaOutput()
            if !f.page.boxes.footprint.isEmpty {
                geometry.int(0x48524157); geometry.int(2)
                try geometry.utf("BOX"); try geometry.utf("PENDING"); try geometry.utf("NONE")
                geometry.int(-1); geometry.int(0); geometry.int(6)
                for cells in f.page.boxes.groups {
                    geometry.int(cells.count)
                    for cell in cells.sorted() { geometry.int(cell) }
                }
                geometry.int(0); geometry.int(0)
            }
            w.int(geometry.data.count); w.data.append(geometry.data)
            for candidate in [false, true] {
                let marks = f.page.marks.filter { ($0.digit != 0) == candidate }
                w.int(marks.count)
                for m in marks {
                    w.int(candidate ? m.cell*10+m.digit : m.cell)
                    w.number(UInt32(0xff000000) | UInt32((m.light == true ? AnnotationPalette.light : AnnotationPalette.dark)[m.color]))
                }
            }
            w.int(-1); w.int(0); w.int(0) // outline group, strokes, doodle capsule
            try w.utf(overlay, long: useLong)
            guard w.data.count <= maxBytes else { throw ReplayJavaError.invalid }
        }
        w.int(doc.bookmarks.count)
        for b in doc.bookmarks {
            let f = doc.frames[b.frameIndex]
            w.int(b.frameIndex); try w.utf(b.name, long: useLong); w.number(f.wallTimeMillis); w.number(f.elapsedMillis)
        }
        try w.utf(origin); w.int(originIndex); w.int(0)
        guard w.data.count <= maxBytes else { throw ReplayJavaError.invalid }
        return w.data
    }
}

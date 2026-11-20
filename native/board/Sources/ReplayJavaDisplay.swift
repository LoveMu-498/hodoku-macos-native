// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Keeps the supported layer of a partial V3 frame visible in a FRAME export.
/// Bounds and points are in FRAME's millionth-of-board units. These are catalogued
/// display objects only. Annotations that can be edited are carried by branchPage.
enum ReplayJavaDisplay {
    static func encode(_ page: BoardPage) throws -> Data? {
        var objects = [[String:Any]]()
        var exceedsLimits = false
        func bounds(_ cell: Int, _ digit: Int) -> [Int] {
            let row = cell / 9, col = cell % 9
            if digit == 0 { return [col*1_000_000/9, row*1_000_000/9, (col+1)*1_000_000/9, (row+1)*1_000_000/9] }
            let x = col*3+(digit-1)%3, y = row*3+(digit-1)/3
            return [x*1_000_000/27, y*1_000_000/27, (x+1)*1_000_000/27, (y+1)*1_000_000/27]
        }
        func color(_ group: Int, light: Bool? = nil, alpha: UInt32 = 255) -> String {
            String(format:"#%08X", (alpha << 24) | UInt32((light == true ? AnnotationPalette.light : AnnotationPalette.dark)[group]))
        }
        func add(_ type: String, _ fields: [String:Any], _ group: Int) {
            // Leave one of the 10,000 object slots for the partial-view marker.
            guard objects.count < 9999 else { exceedsLimits = true; return }
            var o: [String:Any] = ["id":"java-\(objects.count)", "type":type, "required":false,
                                  "important":true, "z":objects.count,"group":"color-\(group)"]
            for (key,value) in fields { o[key] = value }
            objects.append(o)
        }
        func line(_ points: [[Int]], _ group: Int, width: Int, dash: String = "solid", light: Bool? = nil) {
            guard let first = points.first, points.dropFirst().contains(where:{ $0 != first }) else { return }
            guard points.allSatisfy({ $0.allSatisfy((-500000...1500000).contains) }), (1...100000).contains(width) else {
                exceedsLimits = true
                return
            }
            add("line",["points":points,"color":color(group,light:light),"width":max(1,min(100000,width)),
                        "dash":dash,"arrow":"none"],group)
        }
        for (group,cells) in page.boxes.groups.enumerated() {
            for c in cells.sorted() {
                let b = bounds(c,0), corners = [[b[0],b[1]],[b[2],b[1]],[b[2],b[3]],[b[0],b[3]]]
                add("region",["points":corners,"fill":color(group,alpha:32),"stroke":color(group),"width":1800],group)
            }
        }
        for m in page.marks {
            add("highlight",["bounds":bounds(m.cell,m.digit),"anchor":["cell":m.cell,"digit":m.digit],
                             "fill":color(m.color,light:m.light,alpha:100)],m.color)
        }
        for path in page.chains.paths {
            var centers = [[Int]]()
            for node in path.nodes {
                var x = 0, y = 0
                for atom in node.atoms {
                    let b = bounds(atom/10,atom%10)
                    x += (b[0]+b[2])/2; y += (b[1]+b[3])/2
                    add("mark",["shape":"circle","bounds":b,"anchor":["cell":atom/10,"digit":atom%10],
                                "color":color(node.color),"width":1600,"initial":false,
                                "conclusion":false,"outline":NSNull()],node.color)
                }
                centers.append([x/node.atoms.count,y/node.atoms.count])
            }
            for (i,e) in path.edges.enumerated() {
                line([centers[i],centers[(i+1)%centers.count]],e.color,width:2200,dash:e.strong ? "solid" : "dashed")
            }
        }
        func projected(_ point: CGPoint) -> [Int] { [Int((point.x*1_000_000).rounded()),Int((point.y*1_000_000).rounded())] }
        for ink in page.ink.strokes {
            let width = max(1,Int((ink.width*1_000_000).rounded()))
            guard width <= 100000 else { exceedsLimits = true; continue }
            if let cell = ink.cell, let digit = ink.digit {
                let rim: Any = ink.outlined || ink.start
                    ? ["color":ink.outlined ? "#FF1769FF":"#FF00D72D","width":1400,"gap":800] as [String:Any] : NSNull()
                add("mark",["shape":ink.kind == .cross ? "cross":"circle","bounds":bounds(cell,digit),
                            "anchor":["cell":cell,"digit":digit],"color":ink.witness ? "#FFC52024":color(ink.group,light:ink.light),
                            "width":width,"initial":ink.start,"conclusion":ink.outlined,"outline":rim],ink.group)
            } else if ink.kind == .ellipse && ink.points.count == 2 {
                let a = projected(ink.points[0]), b = projected(ink.points[1])
                let box = [min(a[0],b[0]),min(a[1],b[1]),max(a[0],b[0]),max(a[1],b[1])]
                guard box.allSatisfy((-500000...1500000).contains), box[0]<box[2], box[1]<box[3] else {
                    exceedsLimits = true
                    continue
                }
                add("mark",["shape":"circle","bounds":box,"anchor":NSNull(),"color":color(ink.group,light:ink.light),"width":width,
                            "initial":false,"conclusion":false,"outline":NSNull()],ink.group)
            } else {
                let points = ink.points.map(projected)
                for i in stride(from:0,to:max(0,points.count-1),by:4095) {
                    line(Array(points[i..<min(points.count,i+4096)]),ink.group,width:width,light:ink.light)
                }
            }
        }
        guard !exceedsLimits else { throw ReplayJavaError.conversion }
        guard !objects.isEmpty else { return nil }
        return try JSONSerialization.data(withJSONObject:objects,options:.sortedKeys)
    }
}

import Foundation

/// Identity used to order authored annotations around the currently reviewed proof.
enum AnnotationObject: Hashable {
    case mark(Int, Int)
    case box(Int, Int)
    case chainNode([Int])
    case chainEdge([Int], [Int])
    case inkPath(InkStroke.Kind, Int, CGFloat, Int?, Int?, [CGFloat])

    static func ink(_ stroke: InkStroke) -> Self {
        .inkPath(
            stroke.kind, stroke.group, stroke.cell == nil ? stroke.width : 0, stroke.cell, stroke.digit,
            stroke.points.flatMap { [$0.x, $0.y] })
    }
}

struct AnnotationTimeline {
    private var proof: UUID?
    private var previous: [AnnotationObject: [Int]] = [:]
    private(set) var later: Set<AnnotationObject> = []

    mutating func observe(_ page: BoardPage, proof id: UUID?) {
        guard let id = id else {
            self = Self()
            return
        }
        var values: [AnnotationObject: [Int]] = [:]
        for mark in page.marks { values[.mark(mark.cell, mark.digit)] = [mark.swatch] }
        for (group, cells) in page.boxes.groups.enumerated() {
            for cell in cells { values[.box(group, cell)] = [group] }
        }
        for ink in page.ink.strokes { values[.ink(ink)] = [ink.light == true ? 1 : 0] }
        for path in page.chains.paths {
            for node in path.nodes { values[.chainNode(node.atoms)] = [node.color] }
            for (i, edge) in path.edges.enumerated() {
                let (a, b) = path.endpoints(i)
                values[.chainEdge(a.atoms, b.atoms), default: []].append(edge.color * 2 + (edge.strong ? 1 : 0))
            }
        }
        if proof == id {
            later.formIntersection(values.keys)
            for (key, value) in values where previous[key] != value { later.insert(key) }
        } else {
            later.removeAll()
            proof = id
        }
        previous = values
    }
}

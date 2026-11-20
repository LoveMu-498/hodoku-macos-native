// SPDX-License-Identifier: GPL-3.0-or-later
// Native coordinate adaptation of ChainRouteGeometry.createLaneZero/boundedLaneOffset.
import CoreGraphics
import Foundation

struct ChainToolRoute {
  let start, end: CGPoint
  let controls: (CGPoint, CGPoint)?
  var path: CGPath {
    let result = CGMutablePath()
    result.move(to: start)
    if let controls = controls {
      result.addCurve(to: end, control1: controls.0, control2: controls.1)
    } else {
      result.addLine(to: end)
    }
    return result
  }
  func point(_ t: CGFloat) -> CGPoint {
    let s = 1 - t
    guard let (a, b) = controls else {
      return CGPoint(x: s * start.x + t * end.x, y: s * start.y + t * end.y)
    }
    let u = s * s * s
    let v = 3 * s * s * t
    let w = 3 * s * t * t
    let z = t * t * t
    return CGPoint(
      x: u * start.x + v * a.x + w * b.x + z * end.x, y: u * start.y + v * a.y + w * b.y + z * end.y
    )
  }
  var length: CGFloat {
    if controls == nil { return hypot(end.x - start.x, end.y - start.y) }
    let points = samples(count: 12)
    return zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
  }

  func samples(count: Int) -> [CGPoint] {
    (0...count).map { point(CGFloat($0) / CGFloat(count)) }
  }

  private func tangent(_ t: CGFloat) -> CGPoint {
    guard let (a, b) = controls else { return CGPoint(x: end.x - start.x, y: end.y - start.y) }
    let u = 1 - t
    return CGPoint(x: 3 * (u * u * (a.x - start.x) + 2 * u * t * (b.x - a.x) + t * t * (end.x - b.x)),
                   y: 3 * (u * u * (a.y - start.y) + 2 * u * t * (b.y - a.y) + t * t * (end.y - b.y)))
  }

  func trimmed(clearance: CGFloat) -> Self? {
    func distance(from center: CGPoint, to point: CGPoint) -> CGFloat {
      hypot(point.x - center.x, point.y - center.y)
    }
    let midpoint = point(0.5)
    guard distance(from: start, to: midpoint) > clearance, distance(from: end, to: midpoint) > clearance
    else { return nil }
    func exitParameter(atStart: Bool) -> CGFloat {
      var inside: CGFloat = 0
      var outside: CGFloat = 0.5
      let center = atStart ? start : end
      for _ in 0..<14 {
        let t = (inside + outside) / 2
        if distance(from: center, to: point(atStart ? t : 1 - t)) < clearance { inside = t }
        else { outside = t }
      }
      return atStart ? outside : 1 - outside
    }
    let first = exitParameter(atStart: true), last = exitParameter(atStart: false)
    let a = point(first), b = point(last)
    guard controls != nil else { return Self(start: a, end: b, controls: nil) }
    let da = tangent(first), db = tangent(last), scale = (last - first) / 3
    return Self(start: a, end: b, controls: (
      CGPoint(x: a.x + da.x * scale, y: a.y + da.y * scale),
      CGPoint(x: b.x - db.x * scale, y: b.y - db.y * scale)
    ))
  }
  func hits(_ r: CGRect, width: CGFloat) -> Bool {
    let outline = path.copy(
      strokingWithWidth: width, lineCap: .square, lineJoin: .round, miterLimit: 1)
    guard r.intersects(outline.boundingBoxOfPath) else { return false }
    let rect = r.insetBy(dx: -width / 2, dy: -width / 2)
    let count =
      controls == nil ? 1 : max(12, Int(ceil(hypot(end.x - start.x, end.y - start.y) / 3)))
    var a = start
    for i in 1...count {
      let b = point(CGFloat(i) / CGFloat(count))
      var low: CGFloat = 0
      var high: CGFloat = 1
      var valid = true
      for (p, q) in [
        (a.x - b.x, a.x - rect.minX), (b.x - a.x, rect.maxX - a.x), (a.y - b.y, a.y - rect.minY),
        (b.y - a.y, rect.maxY - a.y),
      ] {
        if p == 0 {
          if q < 0 {
            valid = false
            break
          }
        } else if p < 0 {
          low = max(low, q / p)
        } else {
          high = min(high, q / p)
        }
      }
      if valid && low <= high { return true }
      a = b
    }
    return false
  }
  func arrow(size: CGFloat, closed: Bool = true) -> CGPath {
    let previous = controls?.1 ?? start
    let angle = atan2(end.y - previous.y, end.x - previous.x)
    let result = CGMutablePath()
    func wing(_ side: CGFloat) -> CGPoint {
      CGPoint(x: end.x - size * cos(angle + side * 0.45), y: end.y - size * sin(angle + side * 0.45))
    }
    result.move(to: wing(-1))
    result.addLine(to: end)
    result.addLine(to: wing(1))
    if closed { result.closeSubpath() }
    return result
  }
}

extension ChainToolNode {
  func groupBands(in geometry: BoardGeometry) -> CGPath {
    let path = CGMutablePath()
    guard atoms.count > 1 else { return path }
    let points = atoms.map { Self.point($0, geometry) }
    let radius = geometry.unit * 0.128
    var unconnected = Array(points.indices.dropFirst())
    var nearest = Array(repeating: 0, count: points.count)
    var distance = points.map { hypot($0.x - points[0].x, $0.y - points[0].y) }
    // Constant-width capsules meet at the member centers. A straight group forms one track.
    while let next = unconnected.min(by: { distance[$0] < distance[$1] }) {
      let from = points[nearest[next]], to = points[next]
      let transform = CGAffineTransform(translationX: from.x, y: from.y)
        .rotated(by: atan2(to.y - from.y, to.x - from.x))
      path.addRoundedRect(in: CGRect(x: -radius, y: -radius, width: distance[next] + 2 * radius,
                                      height: 2 * radius),
                          cornerWidth: radius, cornerHeight: radius, transform: transform)
      unconnected.removeAll { $0 == next }
      for index in unconnected {
        let length = hypot(points[index].x - to.x, points[index].y - to.y)
        if length < distance[index] {
          distance[index] = length
          nearest[index] = next
        }
      }
    }
    return path
  }

  func backed(by board: NativeBoardSnapshot?) -> Bool {
    guard let board = board else { return true }
    return atoms.allSatisfy {
      board.values[$0 / 10] == 0
        && (board.candidates[$0 / 10] | board.userCandidates[$0 / 10])
          & NativeBoardSnapshot.bit(UInt8($0 % 10)) != 0
    }
  }
}

private struct ChainRouteObstacle {
  let center: CGPoint
  let radius: CGFloat
  let weight: Int

  func intersects(_ a: CGPoint, _ b: CGPoint) -> Bool {
    let dx = b.x - a.x, dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    let x = center.x - a.x, y = center.y - a.y
    let t = lengthSquared == 0 ? 0 : min(1, max(0, (x * dx + y * dy) / lengthSquared))
    let nearestX = x - t * dx, nearestY = y - t * dy
    return nearestX * nearestX + nearestY * nearestY < radius * radius
  }
}

extension ChainToolState {
  func routes(_ g: BoardGeometry, board: NativeBoardSnapshot?) -> [[ChainToolRoute?]] {
    guard g.unit > 0, paths.contains(where: { !$0.edges.isEmpty }) else {
      return paths.map { Array(repeating: nil, count: $0.edges.count) }
    }
    let unit = g.unit
    let marked = Set(paths.flatMap(\.nodes).filter { $0.backed(by: board) }.flatMap(\.atoms))
    var obstacles = marked.sorted().map {
      ChainRouteObstacle(center: ChainToolNode.point($0, g), radius: unit * 0.211, weight: 6)
    }
    if let board {
      for cell in board.values.indices {
        if board.values[cell] != 0 {
          let rect = g.rect(cell)
          obstacles.append(ChainRouteObstacle(center: CGPoint(x: rect.midX, y: rect.midY),
                                              radius: unit * 0.31, weight: 8))
          continue
        }
        let mask = board.candidates[cell] | board.userCandidates[cell]
        for digit in 1...9 where mask & NativeBoardSnapshot.bit(UInt8(digit)) != 0 {
          let atom = cell * 10 + digit
          if !marked.contains(atom) {
            obstacles.append(ChainRouteObstacle(center: ChainToolNode.point(atom, g),
                                                radius: unit * 0.121, weight: 1))
          }
        }
      }
    }
    var counts: [[[Int]]: Int] = [:]
    var ordinals: [[[Int]]: Int] = [:]
    func key(_ a: ChainToolNode, _ b: ChainToolNode) -> [[Int]] {
      a.atoms.description < b.atoms.description ? [a.atoms, b.atoms] : [b.atoms, a.atoms]
    }
    for path in paths {
      for i in path.edges.indices {
        let (a, b) = path.endpoints(i)
        if a.backed(by: board) && b.backed(by: board) { counts[key(a, b), default: 0] += 1 }
      }
    }
    return paths.map { path in
      path.edges.indices.map { i -> ChainToolRoute? in
        let (a, b) = path.endpoints(i)
        guard a.backed(by: board), b.backed(by: board) else { return nil }
        let pair = key(a, b)
        let forward = pair[0] == a.atoms
        let ends = path.rawEndpoints(i, in: g)
        let (start, end) = forward ? ends : (ends.1, ends.0)
        let ordinal = ordinals[pair, default: 0]
        ordinals[pair] = ordinal + 1
        let span = CGFloat(counts[pair, default: 1] - 1) / 2
        let lane = (CGFloat(ordinal) - span) * min(0.24, 0.52 / max(1, span))
        guard let route = Self.route(from: start, to: end, lane: lane, geometry: g, obstacles: obstacles)
        else { return nil }
        return forward ? route :
          ChainToolRoute(start: route.end, end: route.start, controls: route.controls.map { ($0.1, $0.0) })
      }
    }
  }

  private static func route(from start: CGPoint, to end: CGPoint, lane: CGFloat, geometry: BoardGeometry,
                            obstacles: [ChainRouteObstacle]) -> ChainToolRoute? {
    let unit = geometry.unit
    let dx = end.x - start.x, dy = end.y - start.y
    let distance = hypot(dx, dy)
    guard distance > 0 else { return nil }
    let vx = dx / distance, vy = dy / distance
    let lead = min(distance / 3, unit * 0.65)
    let clearance = (geometry.candidateChainRing(1, scale: 1.08).width / 2) + unit * 0.036
    let short = distance < unit * 0.59
    let side: CGFloat = lane < 0 ? -1 : 1
    let firstBend = short ? lane + side * 0.32 : lane
    let near = obstacles.filter { obstacle in
      let q = obstacle.center
      guard q != start, q != end else { return false }
      let x = q.x - start.x, y = q.y - start.y
      let along = x * vx + y * vy
      return along > -obstacle.radius && along < distance + obstacle.radius
        && abs(-x * vy + y * vx) < unit * 1.15 + obstacle.radius
    }

    var best: (route: ChainToolRoute, cost: Int)?
    let interior = geometry.bounds.insetBy(dx: unit * 0.03, dy: unit * 0.03)
    let bends = [firstBend] + [0.22, 0.32, 0.55, 0.80, 1.05].flatMap { [lane + side * $0, lane - side * $0] }
    for bend in bends {
      let offset = bend * unit
      let controls: (CGPoint, CGPoint)? = bend == 0 ? nil : (
        CGPoint(x: start.x + vx * lead - vy * offset, y: start.y + vy * lead + vx * offset),
        CGPoint(x: end.x - vx * lead - vy * offset, y: end.y - vy * lead + vx * offset)
      )
      guard let route = ChainToolRoute(start: start, end: end, controls: controls).trimmed(clearance: clearance)
      else { continue }
      let samples = route.samples(count: route.controls == nil ? 1 : max(12, Int(ceil(distance / (unit * 0.14)))))
      var cost = samples.allSatisfy { interior.contains($0) } ? 0 : 24
      if let best, cost >= best.cost { continue }
      let segments = Array(zip(samples, samples.dropFirst()))
      let extent = route.path.boundingBoxOfPath.insetBy(dx: -unit * 0.31, dy: -unit * 0.31)
      for obstacle in near where extent.contains(obstacle.center) {
        if segments.contains(where: { obstacle.intersects($0.0, $0.1) }) { cost += obstacle.weight }
        if let best, cost >= best.cost { break }
      }
      if cost == 0 { return route }
      if best == nil || cost < best!.cost { best = (route, cost) }
    }
    return best?.route
  }
}

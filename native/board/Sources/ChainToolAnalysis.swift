// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HodokuEngine

enum ChainToolStatus: String {
  case incomplete = "INCOMPLETE"
  case invalid = "INVALID"
  case noConclusion = "NO_CONCLUSION"
  case proven = "PROVEN"
  case assumed = "ASSUMED"
}

struct ChainToolAnalysis {
  var status: ChainToolStatus
  var step: NativeHintStep?
  var stages: [NativeHintStage] = []
  var message: String {
    switch status {
    case .incomplete: return "先连起两个候选节点"
    case .invalid: return "检查链的端点和强弱关系"
    case .noConclusion: return "这条链没有得出填数或删候选的结论"
    case .proven: return "链的结论已证实。"
    case .assumed: return "结论依赖尚未证实的关系。"
    }
  }
}

private final class ChainToolProofs {
  var paths: [(Int, [Int])] = []
}

extension ChainToolPath {
  func analyze(board: NativeBoardSnapshot) throws -> ChainToolAnalysis {
    let atoms = nodes.flatMap { $0.atoms.map(UInt16.init) }
    var offsets = [0]
    for node in nodes { offsets.append(offsets.last! + node.atoms.count) }
    let relations = edges.map { UInt8($0.strong ? 1 : 0) }
    let proofs = ChainToolProofs()
    let collected = Unmanaged.passUnretained(proofs).toOpaque()
    var out = HodokuChainResult()
    var batch = HodokuChainConclusions()
    let status = hodoku_analyze_chain_v2(
      board.values, board.values.count, board.candidates, board.candidates.count,
      atoms, atoms.count, offsets, offsets.count, relations, relations.count, closed ? 1 : 0,
      { opaque, target, literals, count in
        guard let opaque = opaque, let literals = literals else { return }
        let state = Unmanaged<ChainToolProofs>.fromOpaque(opaque).takeUnretainedValue()
        state.paths.append((Int(target), Array(UnsafeBufferPointer(start: literals, count: count))))
      }, collected, &out, &batch)
    guard status == 0 else {
      throw status == 1 ? NativeHintError.contradiction : NativeHintError.engine
    }
    let names: [ChainToolStatus] = [.incomplete, .invalid, .noConclusion, .proven, .assumed]
    guard names.indices.contains(Int(out.status)) else { throw NativeHintError.engine }
    let kind = names[Int(out.status)]
    var result = ChainToolAnalysis(status: kind)
    guard kind == .proven || kind == .assumed else { return result }
    guard !proofs.paths.isEmpty else { throw NativeHintError.engine }
    let placements = out.placement_cell < 81
    let deletions = withUnsafeBytes(of: out.deletions) { Array($0.bindMemory(to: UInt16.self)) }
    var references: [NativeHintReference] = []
    for (target, _) in proofs.paths {
      references.append(
        .cell(
          target / 10, digits: NativeBoardSnapshot.bit(UInt8(target % 10)), removal: !placements))
    }
    let mask = references.reduce(UInt16(0)) { $0 | $1.digits }
    result.step = NativeHintStep(
      technique: .userChain, house: nil, digits: mask,
      premises: Set(nodes.flatMap { $0.atoms.map { $0 / 10 } }).sorted(),
      placementCell: placements ? Int(out.placement_cell) : nil,
      placementDigit: out.placement_digit, deletions: deletions)
    result.step?.authoredConclusions = ChainConclusions(
      truths: withUnsafeBytes(of: batch.truths) { Array($0.bindMemory(to: UInt16.self)) },
      falses: withUnsafeBytes(of: batch.falses) { Array($0.bindMemory(to: UInt16.self)) })
    let proofHeading = kind == .assumed ? "结论依赖未证实的关系" : "链上推理"
    for (target, path) in proofs.paths {
      var text: [String] = []
      var refs: [NativeHintReference] = []
      for literal in path {
        let index = literal / 2
        let members = nodes.indices.contains(index) ? nodes[index].atoms : [target]
        let node = ChainToolNode(atoms: members, color: 0)
        let truth = literal % 2 == 1 ? "成立" : "不成立"
        let label = members.count == 1 ? node.label : "（\(node.label) 至少一个成立）"
        text.append(label + truth)
        refs.append(
          contentsOf: members.map {
            .cell($0 / 10, digits: NativeBoardSnapshot.bit(UInt8($0 % 10)))
          })
      }
      result.stages.append(
        NativeHintStage(
          title: proofHeading, text: text.joined(separator: " → ") + "。", references: refs))
    }
    let entries = proofs.paths.map { target, _ in
      NativeHintReference.cell(target / 10).label + (placements ? " 填入 " : " 排除 ")
        + String(target % 10)
    }
    result.stages.append(
      NativeHintStage(
        title: kind == .assumed ? "条件结论" : "结论", text: entries.joined(separator: "；") + "。",
        references: references))
    return result
  }
}

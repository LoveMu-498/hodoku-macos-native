import Foundation

struct NativeReplayPlayer {
    let document: NativeReplayDocument
    private(set) var index = 0
    private(set) var cursorMillis: Int64
    private(set) var playing = false
    let durationMillis: Int64
    private var segmentNanos: UInt64 = 0
    private var segmentStart: Int64 = 0

    init(document: NativeReplayDocument) {
        self.document = document
        cursorMillis = document.frames.first?.elapsedMillis ?? 0
        durationMillis = max(document.elapsedMillis, document.frames.last?.elapsedMillis ?? 0)
    }

    var frame: NativeReplayFrame? { document.frames.indices.contains(index) ? document.frames[index] : nil }

    private mutating func display(_ position: Int) {
        guard !document.frames.isEmpty else { return }
        index = min(max(position, 0), document.frames.count - 1)
        cursorMillis = document.frames[index].elapsedMillis
    }

    mutating func showFrame(_ position: Int) {
        playing = false
        display(position)
    }

    mutating func stepFrame(_ direction: Int) { showFrame(index + direction.signum()) }

    mutating func stepOperation(_ direction: Int) {
        guard let frame = frame, direction != 0 else { return }
        let frames = document.frames
        var target = index
        if direction > 0 {
            while target < frames.count && frames[target].operationGroup == frame.operationGroup { target += 1 }
            guard target < frames.count else { return }
        } else {
            while target > 0 && frames[target - 1].operationGroup == frame.operationGroup { target -= 1 }
            if target > 0 {
                target -= 1
                let previous = frames[target].operationGroup
                while target > 0 && frames[target - 1].operationGroup == previous { target -= 1 }
            }
        }
        showFrame(target)
    }

    mutating func seek(_ millis: Int64) {
        let target = max(0, min(durationMillis, millis))
        guard let nearest = document.frames.indices.min(by: {
            abs(document.frames[$0].elapsedMillis - target) < abs(document.frames[$1].elapsedMillis - target)
        }) else { return }
        showFrame(nearest)
    }

    mutating func setPlaying(_ value: Bool, nowNanos: UInt64) {
        if !value && playing { tick(nowNanos: nowNanos) }
        if value && !playing && index == document.frames.count - 1 && cursorMillis >= durationMillis { display(0) }
        playing = value && frame != nil && (index < document.frames.count - 1 || cursorMillis < durationMillis)
        if playing { segmentNanos = nowNanos; segmentStart = cursorMillis }
    }

    mutating func tick(nowNanos: UInt64) {
        guard playing else { return }
        let elapsed = Int64((max(segmentNanos, nowNanos) - segmentNanos) / 1_000_000)
        let next = index + 1
        let another = next < document.frames.count
        let target = another ? document.frames[next].elapsedMillis : durationMillis
        let span = max(0, target - segmentStart)
        if another && span == 0 {
            // ReplayViewer grants each equal-time proof/result 700 ms on screen without adding solve time.
            guard elapsed >= 700 else { return }
        } else {
            cursorMillis = segmentStart + min(span, elapsed)
            guard elapsed >= span else { return }
        }
        if another {
            display(next)
            segmentNanos = nowNanos
            segmentStart = cursorMillis
        }
        if index == document.frames.count - 1 && cursorMillis >= durationMillis { playing = false }
    }
}

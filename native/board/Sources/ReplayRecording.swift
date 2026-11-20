import Foundation

enum NativeReplayFormat: String, Codable {
    case native, javaV3, frame01, frame02
}

struct NativeReplayBookmark: Codable, Equatable {
    var name: String
    var frameIndex: Int
}

struct NativeReplayFrame: Codable, Equatable {
    var id = UUID().uuidString
    var operationGroup: String
    var operationID: Int64
    var wallTimeMillis: Int64
    var elapsedMillis: Int64
    var kind: String
    var label: String
    var phase = "snapshot"
    var text = ""
    var page: BoardPage
    var previewPNG: Data?
    var displayJSON: Data?
    var exchangeBlockReason: String?
    var incompleteDisplay: Bool?
    var notices: [String] = []
    var branchPage: BoardPage?
    var board: NativeBoardSnapshot { page.board }

    init(operationID: Int64, wallTimeMillis: Int64, elapsedMillis: Int64,
         kind: String, label: String, page: BoardPage) {
        self.operationID = operationID
        self.operationGroup = String(operationID)
        self.wallTimeMillis = wallTimeMillis
        self.elapsedMillis = elapsedMillis
        self.kind = kind
        self.label = label
        self.page = page
    }

    // The PNG freezes proof references at the original position. Only editable page data
    // may be handed to a new attempt; transient selection, proof and clock are view state.
    static func capture(_ frame: BoardFrame, kind: String, label: String,
                        text: String = "", freeze: Bool = false) throws -> Self {
        var result = Self(operationID: 0, wallTimeMillis: 0, elapsedMillis: 0,
                          kind: kind, label: label, page: frame.page)
        result.branchPage = frame.page
        result.text = text
        if freeze { result.previewPNG = try BoardPainter.png(frame) }
        return result
    }
}

struct NativeReplayDocument: Codable, Equatable {
    var id: String
    var startedAt: Int64
    var frames: [NativeReplayFrame]
    var elapsedMillis: Int64 = 0
    var endedAt: Int64 = 0
    var completed = false
    var retained = false
    var pinned = false
    var bookmarks: [NativeReplayBookmark] = []
    var sourceArchiveSHA256: String?
    var sourceReplayID: String?
    var sourceFrameIndex: Int?
    var originalBytes: Data?
    var format: NativeReplayFormat = .native

    init(id: String, startedAt: Int64, frames: [NativeReplayFrame]) {
        self.id = id
        self.startedAt = startedAt
        self.frames = frames
    }
}

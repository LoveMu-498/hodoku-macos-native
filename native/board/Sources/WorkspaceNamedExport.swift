// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

enum WorkspaceNamedExport {
    /// Only update files created by Save As in this game. A later external edit wins.
    static func replace(_ url: URL, expected: Data, with bytes: Data) throws {
        let fd = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN) }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else { throw BoardFileError.unsafeLocation }
        guard try Data(contentsOf: url) == expected else { throw BoardFileError.concurrentChange }
        if bytes != expected { try bytes.write(to: url, options: .atomic) }
    }
}

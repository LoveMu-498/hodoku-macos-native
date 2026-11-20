// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation

enum NativeOperationSound: String, CaseIterable {
    case copy = "Tink", paste = "Pop", unavailable = "Purr", failure = "Basso", noResults = "Ping"
    case clear = "Funk", edit = "Bottle", eraseInk = "Blow", eraseInkBatch
    case save = "Glass", share = "Mail Sent"

    var volume: Float {
        switch self {
        case .copy: return 0.44
        case .paste: return 0.52
        case .unavailable: return 0.53
        case .failure: return 0.64
        case .noResults: return 0.23
        case .clear, .edit: return 0.32
        case .eraseInk: return 0.24
        case .eraseInkBatch: return 0.36
        case .save: return 0.28
        case .share: return 0.32
        }
    }

    var fileURL: URL {
        if self == .share {
            let sent = URL(fileURLWithPath: "/System/Applications/Mail.app/Contents/Resources/Mail Sent.aiff")
            if FileManager.default.isReadableFile(atPath: sent.path) { return sent }
            return URL(fileURLWithPath: "/System/Library/Sounds/Morse.aiff")
        }
        let name = self == .eraseInkBatch ? Self.eraseInk.rawValue : rawValue
        return URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
    }

    var followupDelay: TimeInterval? { self == .eraseInkBatch ? 0.20 : nil }
}

/// File I/O, decoder setup and audio output are owned by the serial playback queue.
final class NativeOperationSounds {
    private let queue = DispatchQueue(label: "org.hodoku.nativecandidate.operation-sounds", qos: .userInitiated)
    private var samples: [NativeOperationSound: AVAudioPlayer] = [:]
    private var lastPlayed: [NativeOperationSound: TimeInterval] = [:]
    private var playing: AVAudioPlayer?
    private var followup: DispatchWorkItem?
    private var prepared = false

    func prepare() {
        queue.async {
            guard !self.prepared else { return }
            self.prepared = true
            for kind in NativeOperationSound.allCases { _ = self.sample(kind)?.prepareToPlay() }
        }
    }

    func play(_ kind: NativeOperationSound) {
        let time = ProcessInfo.processInfo.systemUptime
        queue.async { self.play(kind, at: time) }
    }

    private func sample(_ kind: NativeOperationSound) -> AVAudioPlayer? {
        if let sound = samples[kind] { return sound }
        guard let sound = try? AVAudioPlayer(contentsOf: kind.fileURL) else { return nil }
        sound.volume = kind.volume
        samples[kind] = sound
        return sound
    }

    private func play(_ kind: NativeOperationSound, at now: TimeInterval) {
        guard now - (lastPlayed[kind] ?? -.infinity) >= 0.15 else { return }
        lastPlayed[kind] = now
        if let sound = sample(kind) {
            start(sound)
            if let delay = kind.followupDelay, playing != nil {
                let next = DispatchWorkItem { [weak self, weak sound] in
                    guard let sound else { return }
                    self?.start(sound)
                }
                followup = next
                queue.asyncAfter(deadline: .now() + delay, execute: next)
            }
        } else if kind == .unavailable || kind == .failure {
            stopPlaying()
            let alert = DispatchWorkItem { NSSound.beep() }
            followup = alert
            DispatchQueue.main.async(execute: alert)
        }
    }

    private func start(_ sound: AVAudioPlayer) {
        stopPlaying()
        sound.currentTime = 0
        if sound.play() { playing = sound }
    }

    func stop() {
        queue.async { self.stopPlaying() }
    }

    private func stopPlaying() {
        followup?.cancel()
        followup = nil
        playing?.stop()
        playing = nil
    }
}

enum NativeClipboardError: LocalizedError {
    case write
    var errorDescription: String? { "无法写入剪贴板，请重试。" }
}

extension NativeBoardModel {
    func copyPuzzle(_ format: NativePuzzleFormat, to pasteboard: NSPasteboard = .general) throws {
        let data = try NativePuzzleFiles.encode(progress, as: format, step: reading, useZero: solverConfig.useZero)
        pasteboard.clearContents()
        guard pasteboard.setString(String(decoding: data, as: UTF8.self), forType: .string) else {
            throw NativeClipboardError.write
        }
        playOperationSound(.copy)
    }
}

struct BoardPointerFeedback {
    let button: BoardButton
    let isDouble: Bool
    let isDrag: Bool
}

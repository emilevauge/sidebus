import Foundation
import SidebusCore

/// Writes a raw Annex B stream to a file. Temporary phase 2 output, played back with
/// `ffplay`. Goes away in phase 3, when frames leave over the socket.
actor H264FileWriter {
    private let handle: FileHandle
    private var buffer = Data()
    /// One write per frame means two syscalls at 60 Hz for nothing. Batch them.
    private static let flushThreshold = 256 * 1024

    init(path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    }

    func write(_ frame: EncodedFrame) {
        // SPS/PPS come before the first frame, and before any frame following a change
        // de configuration de l'encodeur.
        if let parameterSets = frame.parameterSets {
            buffer.append(parameterSets)
        }
        buffer.append(frame.data)

        if buffer.count >= Self.flushThreshold {
            flush()
        }
    }

    func close() {
        flush()
        try? handle.close()
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        try? handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}

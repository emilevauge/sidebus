import Foundation
import SidebusCore

/// Écrit un flux Annex B brut dans un fichier. Sortie temporaire de la phase 2, relue
/// avec `ffplay`. Disparaît en phase 3, quand les frames partent sur le socket.
actor H264FileWriter {
    private let handle: FileHandle
    private var buffer = Data()
    /// Un write par frame fait deux appels système à 60 Hz pour rien. On groupe.
    private static let flushThreshold = 256 * 1024

    init(path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    }

    func write(_ frame: EncodedFrame) {
        // Les SPS/PPS précèdent la première frame, et toute frame qui suit un changement
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

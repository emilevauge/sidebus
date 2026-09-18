import CryptoKit
import Foundation
import Network
import os

/// Client TCP au dessus de `NWConnection`. Le Mac se connecte toujours, en USB comme en
/// Wi-Fi : seule l'adresse change.
public actor TransportClient: Transport {
    public nonisolated let kind: TransportKind
    public nonisolated let messages: AsyncStream<Message>

    private let connection: NWConnection
    private let continuation: AsyncStream<Message>.Continuation
    private let queue = DispatchQueue(label: "app.sidebus.transport")
    private var decoder = MessageDecoder()
    private var isClosed = false

    /// - Parameters:
    ///   - validator: décide d'accepter le certificat de la tablette. `nil` désactive TLS,
    ///     ce qui ne sert qu'aux tests.
    ///   - expectedDeviceID: identifiant attendu, connu d'avance en Wi-Fi seulement.
    public init(
        host: String,
        port: UInt16,
        kind: TransportKind,
        validator: (any CertificateValidator)? = nil,
        expectedDeviceID: String? = nil
    ) {
        self.init(
            endpoint: .hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!
            ),
            kind: kind,
            validator: validator,
            expectedDeviceID: expectedDeviceID
        )
    }

    public init(
        endpoint: NWEndpoint,
        kind: TransportKind,
        validator: (any CertificateValidator)? = nil,
        expectedDeviceID: String? = nil
    ) {
        self.kind = kind

        let tcp = NWProtocolTCP.Options()
        // Nagle retarderait les petits messages, donc les entrées et les PING.
        tcp.noDelay = true
        tcp.connectionTimeout = 5

        let parameters: NWParameters
        if let validator {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(
                tls.securityProtocolOptions,
                .TLSv13
            )
            let verify: sec_protocol_verify_t = { _, trust, complete in
                tlsLog.debug("vérification du certificat demandée")
                // `complete` est une closure C que Swift ne sait pas déclarer sûre entre
                // tâches. Elle n'est appelée qu'une fois, depuis la tâche ci dessous.
                let completion = VerifyCompletion(complete)
                guard let fingerprint = leafFingerprint(of: trust) else {
                    tlsLog.error("aucun certificat exploitable dans la chaîne présentée")
                    completion.call(false)
                    return
                }
                Task {
                    let accepted = await validator.shouldAccept(
                        fingerprint: fingerprint,
                        expectedDeviceID: expectedDeviceID
                    )
                    tlsLog.debug("certificat \(accepted ? "accepté" : "refusé", privacy: .public)")
                    completion.call(accepted)
                }
            }
            sec_protocol_options_set_verify_block(
                tls.securityProtocolOptions,
                verify,
                verifyQueue
            )
            parameters = NWParameters(tls: tls, tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }

        connection = NWConnection(to: endpoint, using: parameters)

        (messages, continuation) = AsyncStream<Message>.makeStream(bufferingPolicy: .unbounded)
    }

    /// Ouvre la connexion et rend la main quand le socket est prêt.
    ///
    /// Annulable : sans cela, une adresse qui ne répond jamais, cas d'un réseau qui isole
    /// ses clients, laisse la tâche suspendue pour toujours et bloque même le groupe de
    /// tâches censé lui imposer un délai.
    public func connect() async throws {
        let handle = ConnectionHandle(connection)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            let hasResumed = Resumed()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if hasResumed.claim() { resume.resume() }
                case let .failed(error):
                    tlsLog.error("connexion en échec : \(String(describing: error), privacy: .public)")
                    if hasResumed.claim() { resume.resume(throwing: TransportError.connectionFailed("\(error)")) }
                case .cancelled:
                    if hasResumed.claim() { resume.resume(throwing: TransportError.closed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            }
        } onCancel: {
            handle.cancel()
        }

        Task { await receiveLoop() }
    }

    public func send(_ message: Message) async throws {
        guard !isClosed else { throw TransportError.closed }
        let data = MessageCodec.encode(message)

        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        resume.resume(throwing: TransportError.connectionFailed("\(error)"))
                    } else {
                        resume.resume()
                    }
                }
            )
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        continuation.finish()
    }

    private func receiveLoop() async {
        while !isClosed {
            do {
                let data = try await receiveChunk()
                guard !data.isEmpty else { continue }
                decoder.append(data)
                while let message = try decoder.next() {
                    continuation.yield(message)
                }
            } catch {
                tlsLog.debug("boucle de réception arrêtée : \(String(describing: error), privacy: .public)")
                await close()
                return
            }
        }
    }

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
                data, _, isComplete, error in
                if let error {
                    resume.resume(throwing: TransportError.connectionFailed("\(error)"))
                } else if isComplete {
                    resume.resume(throwing: TransportError.closed)
                } else {
                    resume.resume(returning: data ?? Data())
                }
            }
        }
    }
}

/// SHA-256 du certificat feuille présenté, au format DER.
func leafFingerprint(of trust: sec_trust_t) -> Data? {
    let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
    guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
        let leaf = chain.first
    else { return nil }
    return PairingCode.fingerprint(ofDER: SecCertificateCopyData(leaf) as Data)
}

/// Permet d'annuler la connexion depuis un contexte non isolé.
private final class ConnectionHandle: @unchecked Sendable {
    private let connection: NWConnection

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func cancel() {
        connection.cancel()
    }
}

/// Emballe la closure de fin de vérification, que Swift 6 refuse de laisser traverser
/// une frontière de tâche.
private final class VerifyCompletion: @unchecked Sendable {
    private let complete: sec_protocol_verify_complete_t

    init(_ complete: @escaping sec_protocol_verify_complete_t) {
        self.complete = complete
    }

    func call(_ accepted: Bool) {
        complete(accepted)
    }
}

let tlsLog = Logger(subsystem: "app.sidebus", category: "tls")

/// File dédiée à la vérification du certificat, pour ne pas bloquer celle du transport.
private let verifyQueue = DispatchQueue(label: "app.sidebus.tls-verify")

/// Garde qu'une continuation n'est reprise qu'une fois, les états de `NWConnection`
/// pouvant se succéder.
private final class Resumed: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

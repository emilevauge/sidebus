import CryptoKit
import Foundation
import Network
import os

/// TCP client on top of `NWConnection`. The Mac always connects, on USB as on Wi-Fi: only
/// the address changes.
public actor TransportClient: Transport {
    public nonisolated let kind: TransportKind
    public nonisolated let messages: AsyncStream<Message>

    private let connection: NWConnection
    private let continuation: AsyncStream<Message>.Continuation
    private let queue = DispatchQueue(label: "app.sidebus.transport")
    private var decoder = MessageDecoder()
    private var isClosed = false

    /// - Parameters:
    ///   - validator: decides whether to accept the tablet's certificate. `nil` disables
    ///     TLS, which only serves the tests.
    ///   - expectedDeviceID: expected identifier, known in advance on Wi-Fi only.
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
        // Nagle would delay small messages, so input events and PINGs.
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
                tlsLog.debug("certificate verification requested")
                // `complete` is a C closure Swift cannot declare safe across tasks. It is
                // called exactly once, from the task below.
                let completion = VerifyCompletion(complete)
                guard let fingerprint = leafFingerprint(of: trust) else {
                    tlsLog.error("no usable certificate in the presented chain")
                    completion.call(false)
                    return
                }
                Task {
                    let accepted = await validator.shouldAccept(
                        fingerprint: fingerprint,
                        expectedDeviceID: expectedDeviceID
                    )
                    tlsLog.debug("certificate \(accepted ? "accepted" : "refused", privacy: .public)")
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

    /// Opens the connection and returns once the socket is ready.
    ///
    /// Cancellable: without that, an address that never answers, the case of a network
    /// isolating its clients, leaves the task suspended forever and blocks even the task
    /// group meant to impose a deadline on it.
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
                    tlsLog.error("connection failed: \(String(describing: error), privacy: .public)")
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
                tlsLog.debug("receive loop stopped: \(String(describing: error), privacy: .public)")
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

/// SHA-256 of the presented leaf certificate, in DER form.
func leafFingerprint(of trust: sec_trust_t) -> Data? {
    let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
    guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
        let leaf = chain.first
    else { return nil }
    return PairingCode.fingerprint(ofDER: SecCertificateCopyData(leaf) as Data)
}

/// Lets the connection be cancelled from a non isolated context.
private final class ConnectionHandle: @unchecked Sendable {
    private let connection: NWConnection

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func cancel() {
        connection.cancel()
    }
}

/// Wraps the verification completion closure, which Swift 6 refuses to let cross a task
/// boundary.
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

/// A queue of its own for certificate verification, so the transport queue stays free.
private let verifyQueue = DispatchQueue(label: "app.sidebus.tls-verify")

/// Guards that a continuation is resumed only once, since `NWConnection` states can
/// follow one another.
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

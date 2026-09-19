import Foundation
import XCTest

@testable import SidebusCore

final class TimeoutTests: XCTestCase {

    func testReturnsTheResultWhenItIsFast() async throws {
        let value = try await withTimeout(.seconds(5)) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testThrowsWhenItDrags() async {
        do {
            _ = try await withTimeout(.milliseconds(200)) {
                try await Task.sleep(for: .seconds(10))
                return 1
            }
            XCTFail("a timeout was expected")
        } catch let error as TransportError {
            guard case .timedOut = error else { return XCTFail("unexpected error: \(error)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// An address that never answers: no acceptance, no refusal. That is how a network
    /// isolating its clients behaves.
    func testConnectingIntoABlackHole() async {
        let started = Date()
        let client = TransportClient(host: "10.255.255.1", port: 27183, kind: .wifi)
        do {
            try await withTimeout(.seconds(2)) { try await client.connect() }
            XCTFail("the connection should not have succeeded")
        } catch {
            await client.close()
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the timeout did not cut in")
    }

    /// The deadline must not run while a dialog waits for a human answer. Without that
    /// pause, pairing fails as soon as comparing the two codes takes more than eight
    /// seconds.
    func testDeadlinePausesDuringAQuestion() async throws {
        let paused = Flag()
        await paused.raise()

        let value = try await withTimeout(
            .milliseconds(300),
            suspendedWhile: { await paused.isRaised() }
        ) {
            // Twice the deadline, but all of it happens during the pause.
            try await Task.sleep(for: .milliseconds(600))
            await paused.lower()
            return 42
        }

        XCTAssertEqual(value, 42)
    }

    /// The pause must not disarm the deadline forever.
    func testDeadlineResumesAfterTheQuestion() async {
        let paused = Flag()
        await paused.raise()
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            await paused.lower()
        }

        do {
            _ = try await withTimeout(
                .milliseconds(300),
                suspendedWhile: { await paused.isRaised() }
            ) {
                try await Task.sleep(for: .seconds(10))
                return 0
            }
            XCTFail("the deadline should have fired")
        } catch TransportError.timedOut {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A question nobody ever answers must not hold the connection open forever.
    func testThePauseIsItselfBounded() async {
        let paused = Flag()
        await paused.raise()
        let started = Date()

        do {
            _ = try await withTimeout(
                .seconds(30),
                suspendedWhile: { await paused.isRaised() },
                maximumPause: .milliseconds(400)
            ) {
                try await Task.sleep(for: .seconds(30))
                return 0
            }
            XCTFail("the bounded pause should have fired")
        } catch TransportError.timedOut {
            XCTAssertLessThan(
                Date().timeIntervalSince(started),
                3,
                "the pause was not bounded"
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

private actor Flag {
    private var raised = false
    func raise() { raised = true }
    func lower() { raised = false }
    func isRaised() -> Bool { raised }
}

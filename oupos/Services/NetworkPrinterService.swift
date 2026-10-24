import Foundation
import Network

protocol ReceiptPrinting {
    func print(data: Data, to target: PrinterTarget) async throws
}

enum NetworkPrinterError: LocalizedError {
    case invalidTarget, connection(String), timeout

    var errorDescription: String? {
        switch self {
        case .invalidTarget: "出單機 IP 或連接埠不正確"
        case .connection(let message): "出單失敗：\(message)"
        case .timeout: "出單機連線逾時，請確認電源、IP 與 iPad 的本地網路權限"
        }
    }
}

/// TCP transmission plan: large enough to avoid hundreds of tiny, delayed writes,
/// but still bounded so the system can apply TCP backpressure for slower printers.
enum PrinterTransferPolicy {
    static let chunkBytes = 2048
    static let idleTimeout: TimeInterval = 12
    static let drainDelay: TimeInterval = 0.65

    static func ranges(totalBytes: Int) -> [Range<Int>] {
        guard totalBytes > 0 else { return [] }
        return stride(from: 0, to: totalBytes, by: chunkBytes).map {
            $0..<min($0 + chunkBytes, totalBytes)
        }
    }
}

final class NetworkReceiptPrinter: ReceiptPrinting {
    func print(data: Data, to target: PrinterTarget) async throws {
        guard !data.isEmpty, !target.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let port = NWEndpoint.Port(rawValue: target.port) else {
            throw NetworkPrinterError.invalidTarget
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "org.oupos.local.printer")
            let connection = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: .tcp)
            let connectionState = PrinterConnectionState()

            func finish(_ result: Result<Void, Error>) {
                queue.async {
                    guard !connectionState.finished else { return }
                    connectionState.finished = true
                    connectionState.watchdog?.cancel()
                    connection.cancel()
                    continuation.resume(with: result)
                }
            }

            // A stall timeout, not a fixed five-second deadline for the ENTIRE
            // receipt: a long raster print may legitimately transfer for longer.
            func armStallWatchdog() {
                connectionState.watchdog?.cancel()
                let watchdog = DispatchWorkItem { finish(.failure(NetworkPrinterError.timeout)) }
                connectionState.watchdog = watchdog
                queue.asyncAfter(deadline: .now() + PrinterTransferPolicy.idleTimeout, execute: watchdog)
            }

            func sendChunk(_ offset: Int) {
                guard !connectionState.finished else { return }
                guard offset < data.count else {
                    // All writes have reached Network.framework. Allow the TCP
                    // stack time to flush before closing the connection. This
                    // does NOT mean the printer has physically finished printing.
                    queue.asyncAfter(deadline: .now() + PrinterTransferPolicy.drainDelay) {
                        finish(.success(()))
                    }
                    return
                }
                let end = min(offset + PrinterTransferPolicy.chunkBytes, data.count)
                connection.send(content: data.subdata(in: offset..<end),
                                contentContext: .defaultMessage, isComplete: end == data.count,
                                completion: .contentProcessed { error in
                    if let error {
                        finish(.failure(NetworkPrinterError.connection(error.localizedDescription)))
                    } else {
                        armStallWatchdog()
                        // Do not sleep after every 384 bytes. TCP flow control
                        // handles the printer's buffer without artificial gaps.
                        sendChunk(end)
                    }
                })
            }

            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    guard !connectionState.started else { return }
                    connectionState.started = true
                    armStallWatchdog()
                    sendChunk(0)
                case .waiting(let error), .failed(let error):
                    finish(.failure(NetworkPrinterError.connection(error.localizedDescription)))
                default: break
                }
            }
            armStallWatchdog()
            connection.start(queue: queue)
        }
    }
}

private final class PrinterConnectionState: @unchecked Sendable {
    // Accessed only on the NWConnection serial queue.
    var finished = false
    var started = false
    var watchdog: DispatchWorkItem?
}

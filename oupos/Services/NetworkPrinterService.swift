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
                    connection.cancel()
                    continuation.resume(with: result)
                }
            }

            func sendChunk(_ offset: Int) {
                guard !connectionState.finished else { return }
                guard offset < data.count else {
                    queue.asyncAfter(deadline: .now() + 0.4) { finish(.success(())) }
                    return
                }
                let end = min(offset + 384, data.count)
                connection.send(content: data.subdata(in: offset..<end), completion: .contentProcessed { error in
                    if let error {
                        finish(.failure(NetworkPrinterError.connection(error.localizedDescription)))
                    } else {
                        queue.asyncAfter(deadline: .now() + 0.025) { sendChunk(end) }
                    }
                })
            }

            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    guard !connectionState.started else { return }
                    connectionState.started = true
                    sendChunk(0)
                case .waiting(let error), .failed(let error):
                    finish(.failure(NetworkPrinterError.connection(error.localizedDescription)))
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + 5) { finish(.failure(NetworkPrinterError.timeout)) }
            connection.start(queue: queue)
        }
    }
}

private final class PrinterConnectionState: @unchecked Sendable {
    var finished = false
    var started = false
}

import Foundation
import Network

final class BridgeClient: @unchecked Sendable {
    let connection: NWConnection
    var authenticated = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }
}

/// Server WebSocket yang hanya mendengarkan di 127.0.0.1.
///
/// Extension → app:  {"type":"hello","token":…} lalu {"type":"state",…} / {"type":"idle"}
/// App → extension:  {"type":"command","action":"togglePlay" | "next" | "previous"}
@MainActor
final class BridgeServer {
    static let port: NWEndpoint.Port = 38765
    /// Harus sama dengan TOKEN di background.js. Ganti keduanya kalau mau.
    static let token = "lyrichud-dev-token"

    private let model: PlayerModel
    private var listener: NWListener?
    private var clients: [BridgeClient] = []
    private var idleTask: Task<Void, Never>?

    init(model: PlayerModel) {
        self.model = model
    }

    func start() {
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: Self.port)

        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { state in
                print("[LyricHUD] bridge:", state)
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            print("[LyricHUD] gagal membuka bridge:", error)
        }
    }

    func sendCommand(_ command: PlayerCommand) {
        for client in clients where client.authenticated {
            send(["type": "command", "action": command.rawValue], to: client)
        }
    }

    // MARK: - Koneksi

    private func accept(_ connection: NWConnection) {
        let client = BridgeClient(connection)
        clients.append(client)

        connection.stateUpdateHandler = { [weak self, weak client] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in
                    guard let self, let client else { return }
                    self.remove(client)
                }
            default:
                break
            }
        }
        connection.start(queue: .main)
        receive(from: client)
    }

    private func receive(from client: BridgeClient) {
        client.connection.receiveMessage { [weak self, weak client] data, context, _, error in
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            let opcode = metadata?.opcode

            Task { @MainActor in
                guard let self, let client else { return }
                if error != nil || opcode == .close {
                    self.remove(client)
                    return
                }
                if opcode == .text, let data {
                    self.handle(data, from: client)
                }
                self.receive(from: client)
            }
        }
    }

    private func remove(_ client: BridgeClient) {
        client.connection.cancel()
        clients.removeAll { $0 === client }
        guard !clients.contains(where: { $0.authenticated }) else { return }

        // Jeda singkat: service worker extension bisa restart lalu menyambung lagi.
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if !self.clients.contains(where: { $0.authenticated }) {
                self.model.setIdle()
            }
        }
    }

    // MARK: - Pesan

    private func handle(_ data: Data, from client: BridgeClient) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }

        if type == "hello" {
            if (object["token"] as? String) == Self.token {
                client.authenticated = true
                idleTask?.cancel()
            } else {
                remove(client)
            }
            return
        }
        guard client.authenticated else { return }

        switch type {
        case "state":
            model.apply(BridgeState(
                title: object["title"] as? String ?? "",
                artist: object["artist"] as? String ?? "",
                album: object["album"] as? String ?? "",
                duration: object["duration"] as? Double,
                position: object["position"] as? Double ?? 0,
                playing: object["playing"] as? Bool ?? false
            ))
        case "idle":
            model.setIdle()
        default:
            break   // "ping" dll: cukup untuk menjaga koneksi
        }
    }

    private func send(_ object: [String: Any], to client: BridgeClient) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "lyrichud", metadata: [metadata])
        client.connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }
}

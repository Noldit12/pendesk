import Foundation
import Network

/// Nachrichtentypen. Rahmen: [Typ: 1 Byte][Länge: 4 Byte big endian][Inhalt]
enum MsgType: UInt8 {
    case hello = 1      // PC -> iPad: JSON {mode, mons, def}
    case frame = 2      // PC -> iPad: JPEG
    case pen = 10       // iPad -> PC: JSON-Array mit Stift-Samples
    case request = 11   // iPad -> PC: JSON {m, s, q}  (bitte ein Bild senden)
    case config = 12    // iPad -> PC: JSON {mon}
}

/// Wartet auf die Verbindung vom PC. Der PC verbindet sich über USB (usbmux);
/// solche Verbindungen kommen auf dem iPad als lokale Verbindung (localhost) an.
/// Verbindungen aus dem WLAN werden abgewiesen.
final class Link {
    static let port: UInt16 = 7770

    var onConnected: ((Bool) -> Void)?
    var onHello: (([String: Any]) -> Void)?
    var onFrame: ((Data) -> Void)?
    var onRejected: ((String) -> Void)?

    private let queue = DispatchQueue(label: "pendesk.link", qos: .userInteractive)
    private var listener: NWListener?
    private var listenerReady = false
    private var conn: NWConnection?
    private var connected = false

    // MARK: Listener

    func start() {
        queue.async { self.startListener() }
    }

    /// Nach Rückkehr aus dem Hintergrund aufrufen.
    func ensureListening() {
        queue.async {
            if self.listener == nil || !self.listenerReady { self.startListener() }
        }
    }

    private func startListener() {
        listener?.cancel()
        listener = nil
        listenerReady = false
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: Link.port),
              let l = try? NWListener(using: params, on: port) else {
            queue.asyncAfter(deadline: .now() + 1) { self.startListener() }
            return
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, self.listener === l else { return }
            switch state {
            case .ready:
                self.listenerReady = true
            case .failed, .cancelled:
                self.listenerReady = false
                self.listener = nil
                self.queue.asyncAfter(deadline: .now() + 1) { self.startListener() }
            default:
                break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    // MARK: Verbindung

    private static func isLocal(_ ep: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = ep else { return false }
        switch host {
        case .ipv4(let a):
            return a.isLoopback
        case .ipv6(let a):
            return a.isLoopback || (a.asIPv4?.isLoopback ?? false)
        case .name(let n, _):
            return n == "localhost"
        @unknown default:
            return false
        }
    }

    private func accept(_ c: NWConnection) {
        guard Link.isLocal(c.endpoint) else {
            let who = "\(c.endpoint)"
            c.cancel()
            DispatchQueue.main.async { self.onRejected?(who) }
            return
        }
        conn?.cancel()
        conn = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, self.conn === c else { return }
            switch state {
            case .ready:
                self.setConnected(true)
                self.readHeader(c)
            case .failed, .cancelled:
                self.conn = nil
                self.setConnected(false)
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func setConnected(_ on: Bool) {
        guard connected != on else { return }
        connected = on
        DispatchQueue.main.async { self.onConnected?(on) }
    }

    private func readHeader(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, isDone, error in
            guard let self, self.conn === c else { return }
            guard error == nil, let data, data.count == 5 else {
                if isDone || error != nil { c.cancel() }
                return
            }
            let b = [UInt8](data)
            let type = b[0]
            let len = Int(b[1]) << 24 | Int(b[2]) << 16 | Int(b[3]) << 8 | Int(b[4])
            if len == 0 {
                self.handle(type, Data())
                self.readHeader(c)
                return
            }
            guard len < 64_000_000 else { c.cancel(); return }
            c.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] body, _, _, error in
                guard let self, self.conn === c else { return }
                guard error == nil, let body, body.count == len else { c.cancel(); return }
                self.handle(type, body)
                self.readHeader(c)
            }
        }
    }

    private func handle(_ type: UInt8, _ body: Data) {
        switch MsgType(rawValue: type) {
        case .hello:
            if let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                DispatchQueue.main.async { self.onHello?(obj) }
            }
        case .frame:
            onFrame?(body)
        default:
            break
        }
    }

    // MARK: Senden

    func send(_ type: MsgType, _ payload: Data) {
        queue.async {
            guard self.connected, let c = self.conn else { return }
            var d = Data(capacity: payload.count + 5)
            d.append(type.rawValue)
            let n = UInt32(payload.count)
            d.append(contentsOf: [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
            d.append(payload)
            c.send(content: d, completion: .idempotent)
        }
    }

    func sendJSON(_ type: MsgType, _ obj: Any) {
        if let d = try? JSONSerialization.data(withJSONObject: obj) {
            send(type, d)
        }
    }
}

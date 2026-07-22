import Foundation

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

enum LoopbackHTTPResponse {
    case raw(Data)
    case holdOpen

    static func chunked(status: String = "200 OK", body: Data) -> LoopbackHTTPResponse {
        var response = Data(
            "HTTP/1.1 \(status)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8)
        response.append(Data("\(String(body.count, radix: 16))\r\n".utf8))
        response.append(body)
        response.append(Data("\r\n0\r\n\r\n".utf8))
        return .raw(response)
    }
}

final class LoopbackHTTPServer: @unchecked Sendable {
    let url: URL

    private let response: LoopbackHTTPResponse
    private let condition = NSCondition()
    private var listeningDescriptor: Int32
    private var connectionDescriptor: Int32 = -1
    private var didAcceptConnection = false
    private var didFinish = false
    private var isStopped = false

    init(response: LoopbackHTTPResponse) throws {
        let descriptor = systemSocket()
        guard descriptor >= 0 else { throw LoopbackHTTPServerError.couldNotStart }
        listeningDescriptor = descriptor
        self.response = response

        var reuseAddress: Int32 = 1
        guard withUnsafePointer(to: &reuseAddress, {
            systemSetSocketOption(
                descriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                $0,
                socklen_t(MemoryLayout<Int32>.size))
        }) == 0 else {
            _ = systemClose(descriptor)
            throw LoopbackHTTPServerError.couldNotStart
        }

        var address = sockaddr_in()
        #if !os(Linux)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard "127.0.0.1".withCString({ systemInetPton(AF_INET, $0, &address.sin_addr) }) == 1,
              withUnsafePointer(to: &address, {
                  $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                      systemBind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                  }
              }) == 0,
              systemListen(descriptor, 1) == 0,
              systemSetNonBlocking(descriptor) == 0 else {
            _ = systemClose(descriptor)
            throw LoopbackHTTPServerError.couldNotStart
        }

        var boundAddress = sockaddr_in()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &boundAddress, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                systemGetSocketName(descriptor, $0, &addressLength)
            }
        }) == 0 else {
            _ = systemClose(descriptor)
            throw LoopbackHTTPServerError.couldNotStart
        }
        let port = UInt16(bigEndian: boundAddress.sin_port)
        guard let url = URL(string: "http://127.0.0.1:\(port)/request") else {
            _ = systemClose(descriptor)
            throw LoopbackHTTPServerError.couldNotStart
        }
        self.url = url

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            serve()
        }
    }

    deinit {
        stop()
    }

    func waitUntilAccepted(timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !didAcceptConnection, !didFinish, Date() < deadline {
            _ = condition.wait(until: deadline)
        }
        return didAcceptConnection
    }

    func stop() {
        condition.lock()
        isStopped = true
        let connection = connectionDescriptor
        condition.broadcast()
        condition.unlock()
        if connection >= 0 {
            _ = systemShutdown(connection)
        }
    }

    private func serve() {
        let connection = acceptConnection()
        guard connection >= 0 else {
            finish()
            return
        }
        condition.lock()
        connectionDescriptor = connection
        didAcceptConnection = true
        condition.broadcast()
        condition.unlock()

        readRequest(from: connection)
        switch response {
        case let .raw(data):
            sendAll(data, to: connection)
        case .holdOpen:
            condition.lock()
            while !isStopped {
                condition.wait()
            }
            condition.unlock()
        }
        _ = systemShutdown(connection)
        _ = systemClose(connection)
        finish()
    }

    private func acceptConnection() -> Int32 {
        while true {
            condition.lock()
            let stopped = isStopped
            condition.unlock()
            if stopped { return -1 }

            let connection = systemAccept(listeningDescriptor)
            if connection >= 0 { return connection }
            if errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR { return -1 }
            systemMicroSleep(10000)
        }
    }

    private func readRequest(from descriptor: Int32) {
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while request.count < 64 * 1024 {
            let received = buffer.withUnsafeMutableBytes { bytes in
                systemReceive(descriptor, bytes.baseAddress, bytes.count)
            }
            if received > 0 {
                request.append(contentsOf: buffer.prefix(received))
                if request.range(of: Data("\r\n\r\n".utf8)) != nil { return }
            } else if received == 0 {
                return
            } else if errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    private func sendAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let sent = systemSend(descriptor, pointer, remaining)
                if sent < 0, errno == EINTR { continue }
                guard sent > 0 else { return }
                remaining -= sent
                pointer = pointer.advanced(by: sent)
            }
        }
    }

    private func finish() {
        condition.lock()
        if listeningDescriptor >= 0 {
            _ = systemClose(listeningDescriptor)
            listeningDescriptor = -1
        }
        connectionDescriptor = -1
        didFinish = true
        condition.broadcast()
        condition.unlock()
    }
}

private enum LoopbackHTTPServerError: Error {
    case couldNotStart
}

#if os(Linux)
    private func systemSocket() -> Int32 {
        Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    }

    private func systemSetSocketOption(
        _ descriptor: Int32,
        _ level: Int32,
        _ name: Int32,
        _ value: UnsafeRawPointer,
        _ length: socklen_t) -> Int32 {
        Glibc.setsockopt(descriptor, level, name, value, length)
    }

    private func systemInetPton(
        _ family: Int32,
        _ source: UnsafePointer<CChar>,
        _ destination: UnsafeMutableRawPointer) -> Int32 {
        Glibc.inet_pton(family, source, destination)
    }

    private func systemBind(
        _ descriptor: Int32,
        _ address: UnsafePointer<sockaddr>,
        _ length: socklen_t) -> Int32 {
        Glibc.bind(descriptor, address, length)
    }

    private func systemListen(_ descriptor: Int32, _ backlog: Int32) -> Int32 {
        Glibc.listen(descriptor, backlog)
    }

    private func systemGetSocketName(
        _ descriptor: Int32,
        _ address: UnsafeMutablePointer<sockaddr>,
        _ length: UnsafeMutablePointer<socklen_t>) -> Int32 {
        Glibc.getsockname(descriptor, address, length)
    }

    private func systemSetNonBlocking(_ descriptor: Int32) -> Int32 {
        let flags = Glibc.fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0 else { return -1 }
        return Glibc.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }

    private func systemAccept(_ descriptor: Int32) -> Int32 {
        Glibc.accept(descriptor, nil, nil)
    }

    private func systemReceive(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        Glibc.recv(descriptor, buffer, count, 0)
    }

    private func systemSend(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        Glibc.send(descriptor, buffer, count, Int32(MSG_NOSIGNAL))
    }

    private func systemShutdown(_ descriptor: Int32) -> Int32 {
        Glibc.shutdown(descriptor, Int32(SHUT_RDWR))
    }

    private func systemClose(_ descriptor: Int32) -> Int32 {
        Glibc.close(descriptor)
    }

    private func systemMicroSleep(_ microseconds: UInt32) {
        _ = Glibc.usleep(microseconds)
    }
#else
    private func systemSocket() -> Int32 {
        Darwin.socket(AF_INET, SOCK_STREAM, 0)
    }

    private func systemSetSocketOption(
        _ descriptor: Int32,
        _ level: Int32,
        _ name: Int32,
        _ value: UnsafeRawPointer,
        _ length: socklen_t) -> Int32 {
        Darwin.setsockopt(descriptor, level, name, value, length)
    }

    private func systemInetPton(
        _ family: Int32,
        _ source: UnsafePointer<CChar>,
        _ destination: UnsafeMutableRawPointer) -> Int32 {
        Darwin.inet_pton(family, source, destination)
    }

    private func systemBind(
        _ descriptor: Int32,
        _ address: UnsafePointer<sockaddr>,
        _ length: socklen_t) -> Int32 {
        Darwin.bind(descriptor, address, length)
    }

    private func systemListen(_ descriptor: Int32, _ backlog: Int32) -> Int32 {
        Darwin.listen(descriptor, backlog)
    }

    private func systemGetSocketName(
        _ descriptor: Int32,
        _ address: UnsafeMutablePointer<sockaddr>,
        _ length: UnsafeMutablePointer<socklen_t>) -> Int32 {
        Darwin.getsockname(descriptor, address, length)
    }

    private func systemSetNonBlocking(_ descriptor: Int32) -> Int32 {
        let flags = Darwin.fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0 else { return -1 }
        return Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }

    private func systemAccept(_ descriptor: Int32) -> Int32 {
        Darwin.accept(descriptor, nil, nil)
    }

    private func systemReceive(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        Darwin.recv(descriptor, buffer, count, 0)
    }

    private func systemSend(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        Darwin.send(descriptor, buffer, count, 0)
    }

    private func systemShutdown(_ descriptor: Int32) -> Int32 {
        Darwin.shutdown(descriptor, SHUT_RDWR)
    }

    private func systemClose(_ descriptor: Int32) -> Int32 {
        Darwin.close(descriptor)
    }

    private func systemMicroSleep(_ microseconds: UInt32) {
        _ = Darwin.usleep(microseconds)
    }
#endif

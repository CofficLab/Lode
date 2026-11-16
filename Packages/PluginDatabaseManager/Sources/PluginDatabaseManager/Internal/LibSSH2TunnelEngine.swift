import CLibSSH2
import Darwin
import Foundation

/// libssh2 隧道的内部错误分类。引擎边界统一映射为 ``DatabaseError/connectionFailed``，
/// 消息保留 "SSH host key rejected:" 等前缀，便于上层与测试断言。
enum SSHTunnelError: Error, LocalizedError {
    case socketFailed(String)
    case handshakeFailed(String)
    case hostKeyRejected(String)
    case authFailed(String)
    case forwardFailed(String)
    case invalidConfig(String)

    var errorDescription: String? {
        switch self {
        case .socketFailed(let m): return "SSH socket failed: \(m)"
        case .handshakeFailed(let m): return "SSH handshake failed: \(m)"
        case .hostKeyRejected(let m): return "SSH host key rejected: \(m)"
        case .authFailed(let m): return "SSH authentication failed: \(m)"
        case .forwardFailed(let m): return "SSH port forward failed: \(m)"
        case .invalidConfig(let m): return "Invalid SSH configuration: \(m)"
        }
    }
}

private let libssh2Initialized: Bool = {
    libssh2_init(0) == 0
}()

private func lastSessionError(_ session: OpaquePointer?) -> String {
    var msg: UnsafeMutablePointer<CChar>?
    var len: Int32 = 0
    libssh2_session_last_error(session, &msg, &len, 0)
    if let msg { return String(cString: msg) }
    return "unknown error"
}

/// 解析主机名（支持 IPv4/IPv6 与 DNS 名称）并建立 TCP 连接，逐个地址尝试。
private func connectSocket(host: String, port: Int) throws -> Int32 {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    let rc = getaddrinfo(host, String(port), &hints, &res)
    guard rc == 0, let res else {
        throw SSHTunnelError.socketFailed("cannot resolve host \(host)")
    }
    defer { freeaddrinfo(res) }
    var cur: UnsafeMutablePointer<addrinfo>? = res
    var lastErrno: Int32 = 0
    while let ai = cur {
        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        if fd >= 0 {
            if connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
                return fd
            }
            lastErrno = errno
            Darwin.close(fd)
        }
        cur = ai.pointee.ai_next
    }
    throw SSHTunnelError.socketFailed("connect to \(host):\(port) failed (errno \(lastErrno))")
}

private func knownhostKeyBits(_ type: Int32) -> Int32 {
    switch type {
    case 1: return 2 << 18
    case 2: return 3 << 18
    case 3: return 4 << 18
    case 4: return 5 << 18
    case 5: return 6 << 18
    case 6: return 7 << 18
    default: return 15 << 18
    }
}

/// 校验主机密钥（认证之前）。TOFU：首次接触记录密钥，之后必须匹配；不匹配则拒绝。
private func verifyHostKey(session: OpaquePointer, host: String, port: Int, knownHostsPath: String) throws {
    var len = 0
    var type: Int32 = 0
    guard let ptr = libssh2_session_hostkey(session, &len, &type), len > 0 else {
        throw SSHTunnelError.hostKeyRejected("no host key presented")
    }
    let keyBytes = Array(UnsafeBufferPointer<CChar>(start: ptr, count: len))
    guard let kh = libssh2_knownhost_init(session) else {
        throw SSHTunnelError.hostKeyRejected("knownhost init failed")
    }
    defer { libssh2_knownhost_free(kh) }
    libssh2_knownhost_readfile(kh, knownHostsPath, LIBSSH2_KNOWNHOST_FILE_OPENSSH)
    let typemask = LIBSSH2_KNOWNHOST_TYPE_PLAIN | LIBSSH2_KNOWNHOST_KEYENC_RAW | knownhostKeyBits(type)
    var store: UnsafeMutablePointer<libssh2_knownhost>?
    let rc = keyBytes.withUnsafeBufferPointer { buf in
        libssh2_knownhost_checkp(kh, host, Int32(port), buf.baseAddress, buf.count, typemask, &store)
    }
    if rc == LIBSSH2_KNOWNHOST_CHECK_MATCH { return }
    if rc == LIBSSH2_KNOWNHOST_CHECK_MISMATCH {
        throw SSHTunnelError.hostKeyRejected("host key changed for \(host):\(port) — possible MITM")
    }
    guard rc == LIBSSH2_KNOWNHOST_CHECK_NOTFOUND else {
        throw SSHTunnelError.hostKeyRejected("knownhost check failed (rc=\(rc))")
    }
    // First contact: record then persist.
    let addRC = keyBytes.withUnsafeBufferPointer { buf in
        libssh2_knownhost_addc(kh, host, nil, buf.baseAddress, buf.count, nil, 0, typemask, nil)
    }
    guard addRC == 0 else { throw SSHTunnelError.hostKeyRejected("knownhost add failed") }
    let dir = (knownHostsPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let writeRC = libssh2_knownhost_writefile(kh, knownHostsPath, LIBSSH2_KNOWNHOST_FILE_OPENSSH)
    guard writeRC == 0 else { throw SSHTunnelError.hostKeyRejected("knownhost write failed") }
}

private func authenticate(session: OpaquePointer, ssh: ConnectionSSHConfig) throws {
    switch ssh.authMethod {
    case .password:
        let pw = ssh.password ?? ""
        let rc = libssh2_userauth_password_ex(session, ssh.username, UInt32(ssh.username.utf8.count),
                                              pw, UInt32(pw.utf8.count), nil)
        guard rc == 0 else { throw SSHTunnelError.authFailed(lastSessionError(session)) }
    case .privateKey:
        let path = ssh.privateKeyPath ?? ""
        let pass = ssh.passphrase ?? ""
        // nil pubkey: libssh2 derives the public key from the private key,
        // so users need not supply a separate .pub file.
        let rc = libssh2_userauth_publickey_fromfile_ex(
            session, ssh.username, UInt32(ssh.username.utf8.count),
            nil, path, pass.isEmpty ? nil : pass)
        guard rc == 0 else { throw SSHTunnelError.authFailed(lastSessionError(session)) }
    case .agent:
        guard let agent = libssh2_agent_init(session) else {
            throw SSHTunnelError.authFailed("agent init failed")
        }
        defer {
            libssh2_agent_disconnect(agent)
            libssh2_agent_free(agent)
        }
        guard libssh2_agent_connect(agent) == 0, libssh2_agent_list_identities(agent) == 0 else {
            throw SSHTunnelError.authFailed("agent connect/list failed: \(lastSessionError(session))")
        }
        var identity: UnsafeMutablePointer<libssh2_agent_publickey>?
        var prev: UnsafeMutablePointer<libssh2_agent_publickey>?
        while libssh2_agent_get_identity(agent, &identity, prev) == 0, let identity {
            if libssh2_agent_userauth(agent, ssh.username, identity) == 0 { return }
            prev = identity
        }
        throw SSHTunnelError.authFailed("no agent identity accepted")
    }
}

private func defaultKnownHostsPath() -> String {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    let dir = (base ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support"))
        .appendingPathComponent("Lode", isDirectory: true)
    return dir.appendingPathComponent("ssh_known_hosts").path
}

/// 基于 libssh2 的本地端口转发隧道。
///
/// 阻塞完成 connect/handshake/hostkey/auth 后切换到非阻塞模式，由单线程
/// pump 循环桥接「本地客户端 ↔ direct-tcpip 通道」。libssh2 会话非线程安全，
/// 故全部会话操作集中在 pump 线程；close() 通过 shutdown 套接字唤醒 pump，
/// 待其退出后再释放会话，避免竞态。
final class LibSSH2Tunnel: SSHTunnel, @unchecked Sendable {
    let localPort: Int
    private let session: OpaquePointer
    private let sessionFd: Int32
    private let listenFd: Int32
    private let targetHost: String
    private let targetPort: Int
    private let lock = NSLock()
    private var stopped = false
    private var pumpExited = false
    private let pumpDone = DispatchSemaphore(value: 0)

    private init(localPort: Int, session: OpaquePointer, sessionFd: Int32, listenFd: Int32,
                 targetHost: String, targetPort: Int) {
        self.localPort = localPort
        self.session = session
        self.sessionFd = sessionFd
        self.listenFd = listenFd
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    static func open(ssh: ConnectionSSHConfig, targetHost: String, targetPort: Int) throws -> LibSSH2Tunnel {
        guard libssh2Initialized else { throw SSHTunnelError.socketFailed("libssh2 init failed") }
        let sessionFd = try connectSocket(host: ssh.host, port: ssh.port)
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            Darwin.close(sessionFd)
            throw SSHTunnelError.handshakeFailed("session init failed")
        }
        libssh2_session_set_blocking(session, 1)
        guard libssh2_session_handshake(session, sessionFd) == 0 else {
            let err = lastSessionError(session)
            libssh2_session_free(session); Darwin.close(sessionFd)
            throw SSHTunnelError.handshakeFailed(err)
        }
        do {
            let knownHosts = ssh.knownHostsPath ?? defaultKnownHostsPath()
            try verifyHostKey(session: session, host: ssh.host, port: ssh.port, knownHostsPath: knownHosts)
            try authenticate(session: session, ssh: ssh)
        } catch {
            libssh2_session_disconnect_ex(session, 11, "auth failed", "en")
            libssh2_session_free(session); Darwin.close(sessionFd)
            throw error
        }

        // Local listener on an ephemeral 127.0.0.1 port.
        let listenFd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var laddr = sockaddr_in()
        laddr.sin_family = sa_family_t(AF_INET)
        laddr.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &laddr.sin_addr)
        let bindRC = withUnsafePointer(to: &laddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRC == 0, listen(listenFd, 1) == 0 else {
            libssh2_session_disconnect_ex(session, 11, "listen failed", "en")
            libssh2_session_free(session); Darwin.close(sessionFd); Darwin.close(listenFd)
            throw SSHTunnelError.forwardFailed("cannot bind local listener")
        }
        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRC = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(listenFd, sa, &boundLen)
            }
        }
        guard nameRC == 0 else {
            libssh2_session_disconnect_ex(session, 11, "getsockname failed", "en")
            libssh2_session_free(session); Darwin.close(sessionFd); Darwin.close(listenFd)
            throw SSHTunnelError.forwardFailed("getsockname failed")
        }
        let localPort = Int(UInt16(bigEndian: bound.sin_port))

        libssh2_session_set_blocking(session, 0)
        let tunnel = LibSSH2Tunnel(localPort: localPort, session: session, sessionFd: sessionFd,
                                   listenFd: listenFd, targetHost: targetHost, targetPort: targetPort)
        tunnel.startPump()
        return tunnel
    }

    private func startPump() {
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.pump()
        }
        thread.stackSize = 1 << 20
        thread.start()
    }

    private func markExited() {
        lock.lock(); pumpExited = true; lock.unlock()
        pumpDone.signal()
    }

    private func isStopped() -> Bool {
        lock.lock(); defer { lock.unlock() }; return stopped
    }

    private func waitSession() {
        let dir = libssh2_session_block_directions(session)
        var events: Int16 = 0
        if dir & 1 != 0 { events |= Int16(POLLIN) }
        if dir & 2 != 0 { events |= Int16(POLLOUT) }
        if events == 0 { events = Int16(POLLIN) }
        var p = pollfd(fd: sessionFd, events: events, revents: 0)
        _ = poll(&p, 1, 500)
    }

    private func pump() {
        let clientFd = accept(listenFd, nil, nil)
        guard clientFd >= 0 else { markExited(); return }
        if isStopped() { Darwin.close(clientFd); markExited(); return }

        var channel: OpaquePointer?
        while !isStopped() {
            channel = libssh2_channel_direct_tcpip_ex(session, targetHost, Int32(targetPort), "127.0.0.1", 40000)
            if channel != nil { break }
            if libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN {
                waitSession(); continue
            }
            Darwin.close(clientFd); markExited(); return
        }
        guard let channel, !isStopped() else {
            if let channel { libssh2_channel_free(channel) }
            Darwin.close(clientFd); markExited(); return
        }

        let bufSize = 32768
        var buf = [CChar](repeating: 0, count: bufSize)
        var clientClosed = false
        var channelClosed = false

        while !clientClosed && !channelClosed && !isStopped() {
            var pfds = [
                pollfd(fd: clientFd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: sessionFd, events: Int16(POLLIN), revents: 0),
            ]
            _ = poll(&pfds, 2, 200)

            if pfds[0].revents & Int16(POLLIN) != 0 {
                let n = read(clientFd, &buf, bufSize)
                if n <= 0 {
                    clientClosed = true
                } else {
                    var off = 0
                    while off < n && !isStopped() {
                        let w = buf.withUnsafeBufferPointer { base in
                            libssh2_channel_write_ex(channel, 0, base.baseAddress! + off, n - off)
                        }
                        if w > 0 { off += w }
                        else if w == Int(LIBSSH2_ERROR_EAGAIN) { waitSession() }
                        else { clientClosed = true; break }
                    }
                }
            }

            let n = buf.withUnsafeMutableBufferPointer { base in
                libssh2_channel_read_ex(channel, 0, base.baseAddress, bufSize)
            }
            if n > 0 {
                var off = 0
                while off < n {
                    let w = buf.withUnsafeBufferPointer { base in
                        write(clientFd, base.baseAddress! + off, n - off)
                    }
                    if w > 0 { off += w }
                    else if w < 0 && errno == EAGAIN { continue }
                    else { clientClosed = true; break }
                }
            } else if n == Int(LIBSSH2_ERROR_EAGAIN) {
                // no data available right now
            } else {
                channelClosed = true
            }
            if libssh2_channel_eof(channel) != 0 { channelClosed = true }
        }

        libssh2_channel_close(channel)
        libssh2_channel_free(channel)
        Darwin.close(clientFd)
        markExited()
    }

    private func snapshotAlive() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped && !pumpExited
    }

    func isAlive() async -> Bool { snapshotAlive() }

    /// 同步 teardown：必须在普通线程上执行（含阻塞等待 pump 退出），
    /// 故由 ``close()`` 派发到专用线程，避免阻塞协作线程池。
    private func performClose() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        lock.unlock()
        // Wake the pump by shutting down its sockets, then wait for it to exit
        // before freeing the session (libssh2 is not thread-safe).
        shutdown(listenFd, SHUT_RDWR)
        Darwin.close(listenFd)
        shutdown(sessionFd, SHUT_RDWR)
        pumpDone.wait()
        libssh2_session_disconnect_ex(session, 11, "tunnel closed", "en")
        libssh2_session_free(session)
        Darwin.close(sessionFd)
    }

    func close() async {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                self.performClose()
                continuation.resume()
            }
        }
    }
}

/// 生产 SSH 隧道引擎：在专用线程上完成阻塞的登录与转发建立，
/// 把内部错误统一映射为 ``DatabaseError/connectionFailed``。
public struct LibSSH2TunnelEngine: SSHTunnelEngine {
    public init() {}

    public func openTunnel(ssh: ConnectionSSHConfig, targetHost: String, targetPort: Int) async throws -> any SSHTunnel {
        do {
            return try await withCheckedThrowingContinuation { continuation in
                Thread.detachNewThread {
                    do {
                        let tunnel = try LibSSH2Tunnel.open(ssh: ssh, targetHost: targetHost, targetPort: targetPort)
                        continuation.resume(returning: tunnel)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch let error as SSHTunnelError {
            throw DatabaseError.connectionFailed(error.errorDescription ?? "SSH tunnel failed")
        }
    }
}
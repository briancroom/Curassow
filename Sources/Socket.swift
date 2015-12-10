#if os(Linux)
import Glibc

private let sock_stream = Int32(SOCK_STREAM.rawValue)

private let system_accept = Glibc.accept
private let system_bind = Glibc.bind
private let system_close = Glibc.close
private let system_listen = Glibc.listen
private let system_read = Glibc.read
private let system_send = Glibc.send
private let system_write = Glibc.write
private let system_shutdown = Glibc.shutdown
private let system_select = Glibc.select
private let system_pipe = Glibc.pipe
#else
import Darwin.C

private let sock_stream = SOCK_STREAM

private let system_accept = Darwin.accept
private let system_bind = Darwin.bind
private let system_close = Darwin.close
private let system_listen = Darwin.listen
private let system_read = Darwin.read
private let system_send = Darwin.send
private let system_write = Darwin.write
private let system_shutdown = Darwin.shutdown
private let system_select = Darwin.select
private let system_pipe = Darwin.pipe
#endif


@_silgen_name("fcntl") private func fcntl(descriptor: Int32, _ command: Int32, _ flags: Int32) -> Int32


struct SocketError : ErrorType, CustomStringConvertible {
  let function: String
  let number: Int32

  init(function: String = __FUNCTION__) {
    self.function = function
    self.number = errno
  }

  var description: String {
    return "Socket.\(function) failed [\(number)]"
  }
}


/// Represents a TCP AF_INET socket
class Socket {
  typealias Descriptor = Int32
  typealias Port = UInt16

  let descriptor: Descriptor

  class func pipe() throws -> [Socket] {
    var fds: [Int32] = [0, 0]
    if system_pipe(&fds) == -1 {
      throw SocketError()
    }
    return [Socket(descriptor: fds[0]), Socket(descriptor: fds[1])]
  }

  init() throws {
#if os(Linux)
    descriptor = socket(AF_INET, sock_stream, 0)
#else
    descriptor = socket(AF_INET, sock_stream, IPPROTO_TCP)
#endif
    assert(descriptor > 0)

    var value: Int32 = 1;
    guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(sizeof(Int32))) != -1 else {
      throw SocketError(function: "setsockopt()")
    }
  }

  init(descriptor: Descriptor) {
    self.descriptor = descriptor
  }

  func listen(backlog: Int32) throws {
    if system_listen(descriptor, backlog) == -1 {
      throw SocketError()
    }
  }

  func bind(address: String, port: Port) throws {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(htons(in_port_t(port)))
    addr.sin_addr = in_addr(s_addr: in_addr_t(0))
    addr.sin_zero = (0, 0, 0, 0, 0, 0, 0, 0)

   let len = socklen_t(UInt8(sizeof(sockaddr_in)))
    guard system_bind(descriptor, sockaddr_cast(&addr), len) != -1 else {
      throw SocketError()
    }
  }

  func accept() throws -> Socket {
    let descriptor = system_accept(self.descriptor, nil, nil)
    if descriptor == -1 {
      throw SocketError()
    }
    return Socket(descriptor: descriptor)
  }

  func close() {
    system_close(descriptor)
  }

  func shutdown() {
    system_shutdown(descriptor, Int32(SHUT_RDWR))
  }

  func send(output: String) {
    output.withCString { bytes in
      system_send(descriptor, bytes, Int(strlen(bytes)), 0)
    }
  }

  func write(output: String) {
    output.withCString { bytes in
      system_write(descriptor, bytes, Int(strlen(bytes)))
    }
  }

  func read(bytes: Int) throws -> [CChar] {
    let data = Data(capacity: bytes)
    let bytes = system_read(descriptor, data.bytes, data.capacity)
    if bytes > 0 {
      return Array(data.characters[0..<bytes])
    }

    return []
  }

  /// Returns whether the socket is set to non-blocking or blocking
  var blocking: Bool {
    get {
      let flags = fcntl(descriptor, F_GETFL, 0)
      return flags & O_NONBLOCK == 1
    }

    set {
      let flags = fcntl(descriptor, F_GETFL, 0)
      let newFlags: Int32

      if newValue {
        newFlags = flags ^ O_NONBLOCK
      } else {
        newFlags = flags | O_NONBLOCK
      }

      fcntl(descriptor, F_SETFL, newFlags)
    }
  }

  /// Returns whether the socket is has the FD_CLOEXEC flag set
  var closeOnExec: Bool {
    get {
      let flags = fcntl(descriptor, F_GETFL, 0)
      return flags & FD_CLOEXEC == 1
    }

    set {
      let flags = fcntl(descriptor, F_GETFL, 0)
      let newFlags: Int32

      if newValue {
        newFlags = flags ^ FD_CLOEXEC
      } else {
        newFlags = flags | FD_CLOEXEC
      }

      fcntl(descriptor, F_SETFL, newFlags)
    }
  }

  private func htons(value: CUnsignedShort) -> CUnsignedShort {
    return (value << 8) + (value >> 8)
  }

  private func sockaddr_cast(p: UnsafeMutablePointer<Void>) -> UnsafeMutablePointer<sockaddr> {
    return UnsafeMutablePointer<sockaddr>(p)
  }
}


func filter(sockets: [Socket], inout _ set: fd_set) -> [Socket] {
  return sockets.filter {
    fdIsSet($0.descriptor, &set)
  }
}


func select(reads: [Socket], _ writes: [Socket], _ errors: [Socket], timeout: timeval) -> ([Socket], [Socket], [Socket]) {
  var timeout = timeout

  var readFDs = fd_set()
  fdZero(&readFDs)
  reads.forEach { fdSet($0.descriptor, &readFDs) }

  var writeFDs = fd_set()
  fdZero(&writeFDs)
  writes.forEach { fdSet($0.descriptor, &writeFDs) }

  var errorFDs = fd_set()
  fdZero(&errorFDs)
  errors.forEach { fdSet($0.descriptor, &errorFDs) }

  let maxFD = (reads + writes + errors).map { $0.descriptor }.reduce(0, combine: max)
  let result = system_select(maxFD + 1, &readFDs, &writeFDs, &errorFDs, &timeout)

  if result == 0 {
    return ([], [], [])
  } else if result > 0 {
    return (
      filter(reads, &readFDs),
      filter(writes, &writeFDs),
      filter(errors, &errorFDs)
    )
  }

  // error
  return ([], [], [])
}

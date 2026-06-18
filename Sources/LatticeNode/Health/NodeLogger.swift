import Logging

public struct NodeLogger: Sendable {
    private let logger: Logger

    public init(_ subsystem: String) {
        self.logger = Logger(label: "lattice.\(subsystem)")
    }

    public func debug(_ msg: String) { logger.debug("\(msg)") }
    public func info(_ msg: String) { logger.info("\(msg)") }
    public func warn(_ msg: String) { logger.warning("\(msg)") }
    public func error(_ msg: String) { logger.error("\(msg)") }
}

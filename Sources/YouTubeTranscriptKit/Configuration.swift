import Foundation

extension YouTubeTranscriptKit {

    /// Caller-supplied settings applied to every request the kit makes.
    ///
    /// The kit deliberately holds no opinion about identity: it ships no default `User-Agent` and adds
    /// no headers of its own. A consumer that wants to present as a browser supplies the entire header
    /// set itself, because only the consumer knows which identity is coherent for it. That is also why
    /// the hook takes an arbitrary dictionary rather than a lone user-agent string: a request claiming
    /// to be a browser while omitting the `Accept-Language` and client-hint headers a real browser
    /// always sends alongside it is a sharper mismatch than the honest CFNetwork default, so a
    /// user-agent-only knob would invite exactly the wrong change.
    public struct Configuration: Sendable {
        /// Headers attached to every request. Empty leaves URLSession's own defaults untouched.
        ///
        /// URLSession reserves a few fields it always sets itself, among them `Content-Length`,
        /// `Authorization`, `Connection` and `Host`; values supplied for those are ignored. Ordinary
        /// fields such as `User-Agent` and `Accept-Language` pass through.
        public var additionalHeaders: [String: String]

        public init(additionalHeaders: [String: String] = [:]) {
            self.additionalHeaders = additionalHeaders
        }
    }

    /// The configuration currently in force.
    public static var configuration: Configuration {
        return state.configuration
    }

    /// Applies `configuration` to every subsequent request.
    ///
    /// The session is rebuilt on the spot rather than at next use, so a call landing after some
    /// fetching has already happened still takes effect instead of silently doing nothing. Requests
    /// already in flight keep the headers they were issued with.
    public static func configure(_ configuration: Configuration) {
        state.setConfiguration(configuration)
    }

    /// The session used for every YouTube fetch.
    ///
    /// Internal rather than private so tests can install a URLProtocol stub and exercise the response
    /// handling without hitting the network. Production code never reassigns it.
    ///
    /// A session assigned here is used verbatim, and the next `configure(_:)` replaces it: that call
    /// rebuilds from `configuration` and `stubProtocolClasses`, which know nothing about a
    /// hand-assigned session. A test whose stub has to survive a `configure(_:)` should install it
    /// through `stubProtocolClasses` instead.
    static var session: URLSession {
        get { return state.session }
        set { state.session = newValue }
    }

    /// URLProtocol subclasses baked into every session the kit builds. Tests only; nil in production.
    ///
    /// Unlike a directly assigned `session`, these survive `configure(_:)`, which is what lets a test
    /// observe the headers a reconfigured session actually puts on the wire.
    static var stubProtocolClasses: [AnyClass]? {
        get { return state.protocolClasses }
        set { state.protocolClasses = newValue }
    }

    /// Builds a session carrying `configuration`'s headers, plus `protocolClasses` when tests supply them.
    static func makeSession(configuration: Configuration, protocolClasses: [AnyClass]? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false

        if !configuration.additionalHeaders.isEmpty {
            config.httpAdditionalHeaders = configuration.additionalHeaders
        }

        if let protocolClasses {
            config.protocolClasses = protocolClasses
        }

        return URLSession(configuration: config)
    }

    private static let state = State()

    /// Guards the session and the configuration it was built from.
    ///
    /// Shared mutable `static var` state is not safe here: Swift 6 rejects it outright, and even under
    /// Swift 5 a `configure(_:)` racing an in-flight fetch is a real data race rather than a
    /// theoretical one. Funnelling every read and write through the lock is what makes the
    /// `@unchecked Sendable` conformance honest rather than a suppression.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var storedConfiguration = Configuration()
        private var storedProtocolClasses: [AnyClass]?
        private var storedSession: URLSession

        init() {
            storedSession = YouTubeTranscriptKit.makeSession(configuration: Configuration())
        }

        var configuration: Configuration {
            lock.lock()
            defer { lock.unlock() }
            return storedConfiguration
        }

        /// Stores the configuration and rebuilds the session from it in one atomic step, so no fetch
        /// can observe the new configuration paired with the old session.
        func setConfiguration(_ configuration: Configuration) {
            lock.lock()
            defer { lock.unlock() }
            storedConfiguration = configuration
            storedSession = YouTubeTranscriptKit.makeSession(configuration: configuration,
                                                             protocolClasses: storedProtocolClasses)
        }

        var protocolClasses: [AnyClass]? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedProtocolClasses
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                storedProtocolClasses = newValue
                storedSession = YouTubeTranscriptKit.makeSession(configuration: storedConfiguration,
                                                                 protocolClasses: newValue)
            }
        }

        var session: URLSession {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedSession
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                storedSession = newValue
            }
        }
    }
}

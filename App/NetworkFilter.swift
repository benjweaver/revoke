import Foundation
import NetworkExtension
import os
import SystemExtensions

private let log = Logger(subsystem: "dev.benjweaver.Revoke", category: "filter")

/// Revoke's network filter, as the app sees it: installing the system extension,
/// switching the filter on, and asking it which apps it keeps off the local network
/// and to change that.
@MainActor
final class NetworkFilter: NSObject, ObservableObject {
    enum State: Equatable {
        case checking
        case notInstalled
        /// Installed, waiting for the person to allow it in System Settings.
        case needsApproval
        /// Allowed, but the filter is switched off.
        case off
        case on
        case failed(String)
    }

    @Published private(set) var state = State.checking
    /// Called whenever the filter switches on, so the app can read its list of blocked apps.
    var onReady: (() -> Void)?

    private var activation: OSSystemExtensionRequest?
    /// Whether `activation` is the request that removes the filter.
    private var removing = false
    private var connection: NSXPCConnection?
    private var configurationObserver: NSObjectProtocol?

    var isOn: Bool { state == .on }

    override init() {
        super.init()
        // The filter can be switched off or on in System Settings while Revoke runs.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .NEFilterConfigurationDidChange, object: NEFilterManager.shared(), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationDidChange() }
        }
    }

    /// Reads the filter's switch again, once the extension is known to be installed
    /// and allowed. Before then, refresh and install decide the state.
    private func configurationDidChange() {
        guard state == .on || state == .off else { return }
        readFilterSwitch()
    }

    /// Finds out where things stand, without changing anything.
    func refresh() {
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: FilterIdentity.extensionBundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Installs the extension, which macOS asks the person to allow, then switches
    /// the filter on.
    func install() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: FilterIdentity.extensionBundleID, queue: .main)
        request.delegate = self
        activation = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Switches the filter on. The first time, macOS asks whether Revoke may filter
    /// network content.
    func enable() {
        NEFilterManager.shared().loadFromPreferences { error in
            MainActor.assumeIsolated {
                if let error { return self.fail(error) }
                let manager = NEFilterManager.shared()
                let configuration = manager.providerConfiguration ?? NEFilterProviderConfiguration()
                configuration.filterSockets = true
                configuration.filterPackets = false
                configuration.filterDataProviderBundleIdentifier = FilterIdentity.extensionBundleID
                manager.providerConfiguration = configuration
                manager.localizedDescription = "Revoke"
                manager.isEnabled = true
                manager.saveToPreferences { error in
                    MainActor.assumeIsolated {
                        if let error { return self.fail(error) }
                        self.state = .on
                        self.onReady?()
                    }
                }
            }
        }
    }

    /// Switches the filter off and uninstalls it, so nothing is left behind when
    /// Revoke is deleted. macOS asks for an administrator's password.
    func remove() {
        NEFilterManager.shared().loadFromPreferences { _ in
            MainActor.assumeIsolated {
                NEFilterManager.shared().removeFromPreferences { _ in
                    MainActor.assumeIsolated {
                        let request = OSSystemExtensionRequest.deactivationRequest(
                            forExtensionWithIdentifier: FilterIdentity.extensionBundleID, queue: .main)
                        request.delegate = self
                        self.activation = request
                        self.removing = true
                        OSSystemExtensionManager.shared.submitRequest(request)
                    }
                }
            }
        }
    }

    /// Why a request didn't reach the filter.
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// The apps the filter keeps off the local network, by code-signing identifier.
    func blocked() async -> Result<[String], Failure> {
        await call { $0.getBlocked(reply: $1) }
    }

    /// Adds apps to the filter's list. Returns the list as the filter has it afterward.
    func block(_ identifiers: [String]) async -> Result<[String], Failure> {
        await call { $0.block(identifiers, reply: $1) }
    }

    /// Takes apps off the filter's list. Returns the list as the filter has it afterward.
    func unblock(_ identifiers: [String]) async -> Result<[String], Failure> {
        await call { $0.unblock(identifiers, reply: $1) }
    }

    /// Lets blocked apps through for a while. The filter blocks them again itself.
    func allow(_ identifiers: [String], minutes: Int) async -> Result<[String], Failure> {
        await call { $0.allow(identifiers, minutes: minutes, reply: $1) }
    }

    /// The apps kept to their model provider's hosts on the internet at this moment.
    func limited() async -> Result<[String], Failure> {
        await call { $0.getLimited(reply: $1) }
    }

    /// Keeps apps to these hosts on the internet. Returns the apps limited afterward.
    func limitInternet(_ identifiers: [String], hosts: [String]) async -> Result<[String], Failure> {
        await call { $0.limitInternet(identifiers, hosts: hosts, reply: $1) }
    }

    func unlimitInternet(_ identifiers: [String]) async -> Result<[String], Failure> {
        await call { $0.unlimitInternet(identifiers, reply: $1) }
    }

    /// Gives limited apps the whole internet for a while. The filter limits them again itself.
    func allowInternet(_ identifiers: [String], minutes: Int) async -> Result<[String], Failure> {
        await call { $0.allowInternet(identifiers, minutes: minutes, reply: $1) }
    }

    /// Sends one request and waits for the filter's answer. When the connection was
    /// dropped, as when the extension restarts with the filter, it's made again and
    /// the request sent once more.
    private func call(
        _ request: @escaping @Sendable (FilterControl, @escaping @Sendable ([String]) -> Void) -> Void
    ) async -> Result<[String], Failure> {
        var lastError: Error?
        for attempt in 0..<2 {
            guard isOn else { return .failure(Failure(errorDescription: "The network filter is off.")) }
            let connection = self.connection ?? connect()
            let answer: Result<[String], Error> = await withCheckedContinuation { continuation in
                // XPC calls exactly one of the two handlers, on its own queue.
                let onError: @Sendable (Error) -> Void = { continuation.resume(returning: .failure($0)) }
                guard let proxy = connection.remoteObjectProxyWithErrorHandler(onError) as? FilterControl else {
                    return continuation.resume(returning: .failure(Failure(errorDescription: "The network filter didn't answer.")))
                }
                request(proxy) { continuation.resume(returning: .success($0)) }
            }
            if case .success(let list) = answer { return .success(list) }
            if case .failure(let error) = answer { lastError = error }
            let code = lastError.map { ($0 as NSError).code }
            guard attempt == 0, code == NSXPCConnectionInterrupted || code == NSXPCConnectionInvalid else { break }
            forget(connection)
        }
        let description = lastError?.localizedDescription ?? "The network filter didn't answer."
        log.error("Can't reach the network filter: \(description, privacy: .public)")
        return .failure(Failure(errorDescription: description))
    }

    private func connect() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: FilterIdentity.machService, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: FilterControl.self)
        connection.setCodeSigningRequirement("""
            anchor apple generic and identifier "\(FilterIdentity.extensionBundleID)" and \
            certificate leaf[subject.OU] = "AR25V66TVY"
            """)
        // The extension restarts with the filter, so a dropped connection is made again.
        let id = ObjectIdentifier(connection)
        let forget: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.forget(id) }
        }
        connection.invalidationHandler = forget
        connection.interruptionHandler = forget
        connection.resume()
        self.connection = connection
        return connection
    }

    /// Lets go of a dropped connection, unless a newer one has taken its place.
    private func forget(_ id: ObjectIdentifier) {
        guard let connection, ObjectIdentifier(connection) == id else { return }
        connection.invalidate()
        self.connection = nil
    }

    private func forget(_ connection: NSXPCConnection) {
        forget(ObjectIdentifier(connection))
    }

    /// The extension is installed and allowed; whether the filter is on is a
    /// separate switch, in Network settings.
    private func readFilterSwitch() {
        NEFilterManager.shared().loadFromPreferences { _ in
            MainActor.assumeIsolated {
                let manager = NEFilterManager.shared()
                let ours = manager.providerConfiguration?.filterDataProviderBundleIdentifier
                    == FilterIdentity.extensionBundleID
                let wasOn = self.isOn
                self.state = ours && manager.isEnabled ? .on : .off
                if self.isOn && !wasOn { self.onReady?() }
            }
        }
    }

    /// The build of the filter inside this copy of Revoke.
    private static var bundledVersion: String? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions/\(FilterIdentity.extensionBundleID).systemextension")
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    private func isActivation(_ request: ObjectIdentifier) -> Bool {
        activation.map(ObjectIdentifier.init) == request
    }

    private func fail(_ error: Error) {
        log.error("\(error.localizedDescription, privacy: .public)")
        state = .failed(error.localizedDescription)
    }
}

// All requests are submitted with the main queue, so their callbacks arrive on it.
extension NetworkFilter: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { state = .needsApproval }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let enabledVersions = properties.filter(\.isEnabled).map(\.bundleVersion)
        let awaitingApproval = properties.contains(where: \.isAwaitingUserApproval)
        MainActor.assumeIsolated {
            if !enabledVersions.isEmpty {
                // After an update the app carries a newer filter, and macOS only
                // swaps it in when asked to activate it.
                if let bundled = Self.bundledVersion, !enabledVersions.contains(bundled) {
                    install()
                } else {
                    readFilterSwitch()
                }
            } else if awaitingApproval {
                state = .needsApproval
            } else {
                state = .notInstalled
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let finished = ObjectIdentifier(request)
        MainActor.assumeIsolated {
            guard isActivation(finished) else { return }
            activation = nil
            if removing {
                removing = false
                connection = nil
                state = .notInstalled
                return
            }
            switch result {
            case .completed: enable()
            case .willCompleteAfterReboot: state = .failed("Restart the Mac to finish installing the filter.")
            @unknown default: state = .failed("macOS didn't finish installing the filter.")
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let failed = ObjectIdentifier(request)
        MainActor.assumeIsolated {
            if isActivation(failed) {
                activation = nil
                removing = false
            }
            // A properties request fails this way when nothing is installed yet.
            if (error as NSError).code == OSSystemExtensionError.extensionNotFound.rawValue {
                state = .notInstalled
            } else {
                fail(error)
            }
        }
    }
}

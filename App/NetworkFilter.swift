import Foundation
import NetworkExtension
import os
import SystemExtensions

private let log = Logger(subsystem: "dev.benjweaver.Revoke", category: "filter")

/// Revoke's network filter, as the app sees it: installing the system extension,
/// switching the filter on, and telling it which apps to keep off the local network.
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
    /// Called whenever the filter is ready for the list of blocked apps.
    var onReady: (() -> Void)?

    private var activation: OSSystemExtensionRequest?
    private var connection: NSXPCConnection?

    var isOn: Bool { state == .on }

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

    /// Sends the full list of blocked apps, by code-signing identifier.
    func send(blocked identifiers: [String]) {
        guard isOn else { return }
        let proxy = (connection ?? connect()).remoteObjectProxyWithErrorHandler { error in
            log.error("Can't reach the network filter: \(error.localizedDescription, privacy: .public)")
        } as? FilterControl
        proxy?.setBlocked(identifiers) {}
    }

    private func connect() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: FilterIdentity.machService, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: FilterControl.self)
        connection.setCodeSigningRequirement("""
            anchor apple generic and identifier "\(FilterIdentity.extensionBundleID)" and \
            certificate leaf[subject.OU] = "AR25V66TVY"
            """)
        // The extension restarts with the filter, so a dropped connection is made again.
        let forget: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.invalidationHandler = forget
        connection.interruptionHandler = forget
        connection.resume()
        self.connection = connection
        return connection
    }

    /// The extension is installed and allowed; whether the filter is on is a
    /// separate switch, in Network settings.
    private func readFilterSwitch() {
        NEFilterManager.shared().loadFromPreferences { _ in
            MainActor.assumeIsolated {
                let manager = NEFilterManager.shared()
                let ours = manager.providerConfiguration?.filterDataProviderBundleIdentifier
                    == FilterIdentity.extensionBundleID
                self.state = ours && manager.isEnabled ? .on : .off
                if self.isOn { self.onReady?() }
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
            if isActivation(failed) { activation = nil }
            // A properties request fails this way when nothing is installed yet.
            if (error as NSError).code == OSSystemExtensionError.extensionNotFound.rawValue {
                state = .notInstalled
            } else {
                fail(error)
            }
        }
    }
}

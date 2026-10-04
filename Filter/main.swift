import Foundation
import NetworkExtension

// A network extension that ships as a system extension hands control to the
// system, which creates FilterDataProvider once the filter is switched on.
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()

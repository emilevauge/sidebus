import CoreMediaIO
import Foundation

// A Core Media I/O extension is a plain executable. The system launches it, it registers a
// provider, and it then lives in a run loop for as long as the camera is published. There
// is no main thread work and no UI: everything reaches it through the provider callbacks.
let source = ProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: source.provider)
CFRunLoopRun()

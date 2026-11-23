import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
// The self-test runs headless and must not steal focus or show a Dock icon.
application.setActivationPolicy(delegate.isSelfTest ? .prohibited : .regular)
application.run()

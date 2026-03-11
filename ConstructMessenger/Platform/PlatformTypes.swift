// Platform-independent type aliases.
// Add this file to BOTH the iOS/Catalyst target and the future macOS target.

#if canImport(UIKit)
import UIKit
public typealias PlatformImage      = UIImage
public typealias PlatformColor      = UIColor
public typealias PlatformFont       = UIFont
public typealias PlatformView       = UIView
public typealias PlatformViewController = UIViewController
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage      = NSImage
public typealias PlatformColor      = NSColor
public typealias PlatformFont       = NSFont
public typealias PlatformView       = NSView
public typealias PlatformViewController = NSViewController
#endif

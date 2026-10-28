import AppKit
import ApplicationServices

/// A Rex pane as the Rex app's accessibility tree shows it.
struct RexPane {
    let title: String
    /// The terminal area of the pane in global top-left coordinates, excluding the pane header.
    let content: CGRect
    let terminal: AXUIElement
    let windowFrame: CGRect
}

/// Reads the Rex app's on-screen layout through the macOS accessibility interface.
/// Each Rex pane is an AXGroup whose description is the pane title, holding an AXTextArea "Terminal".
enum RexAX {
    static let bundleID = "com.superlogical.rex"

    static func app() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ name: String) -> String {
        attribute(element, name) as? String ?? ""
    }

    static func frame(_ element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let value = attribute(element, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &origin) }
        if let value = attribute(element, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
        return CGRect(origin: origin, size: size)
    }

    static func panes(pid: pid_t) -> [RexPane] {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var result: [RexPane] = []
        for window in attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            if attribute(window, kAXMinimizedAttribute) as? Bool == true { continue }
            collect(window, windowFrame: frame(window), depth: 0, into: &result)
        }
        return result
    }

    private static func collect(_ element: AXUIElement, windowFrame: CGRect, depth: Int, into result: inout [RexPane]) {
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            let role = string(child, kAXRoleAttribute)
            let description = string(child, kAXDescriptionAttribute)
            if role == kAXGroupRole, description == "Sidebar Tabs" { continue }
            if role == kAXTextAreaRole, description == "Terminal" {
                result.append(RexPane(title: string(element, kAXDescriptionAttribute), content: frame(child),
                                      terminal: child, windowFrame: windowFrame))
            } else if depth < 10 {
                collect(child, windowFrame: windowFrame, depth: depth + 1, into: &result)
            }
        }
    }

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let value = attribute(application, kAXFocusedUIElementAttribute) else { return nil }
        return (value as! AXUIElement)
    }

    /// Window-server numbers of Rex windows on the current Space, keyed by their bounds.
    static func onScreenWindows(pid: pid_t) -> [(bounds: CGRect, number: Int)] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { entry in
            guard entry[kCGWindowOwnerPID as String] as? pid_t == pid,
                  entry[kCGWindowLayer as String] as? Int == 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  let number = entry[kCGWindowNumber as String] as? Int else { return nil }
            return (bounds, number)
        }
    }

    /// Converts a global top-left rectangle to AppKit's bottom-left screen coordinates,
    /// rounding inwards to whole points so the canvas never covers the pane divider.
    static func appKitRect(_ rect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let minX = rect.minX.rounded(.up), maxX = rect.maxX.rounded(.down)
        let minY = rect.minY.rounded(.up), maxY = rect.maxY.rounded(.down)
        return NSRect(x: minX, y: primaryHeight - maxY, width: maxX - minX, height: maxY - minY)
    }
}

import AppKit
import ApplicationServices

/// Private but long-standing accessibility call (used by window managers such as Rectangle and yabai)
/// that gives the window-server number of an accessibility window.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ window: UnsafeMutablePointer<CGWindowID>) -> AXError

/// A Rex pane as the Rex app's accessibility tree shows it.
struct RexPane {
    let title: String
    /// The terminal area of the pane in global top-left coordinates, excluding the pane header.
    let content: CGRect
    let terminal: AXUIElement
    /// The window-server number of the Rex window that holds the pane.
    let windowNumber: Int
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

    /// Panes and pane dividers (AXSplitter) in every visible Rex window.
    static func scan(pid: pid_t) -> (panes: [RexPane], dividers: [CGRect]) {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var panes: [RexPane] = []
        var dividers: [CGRect] = []
        for window in attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            if attribute(window, kAXMinimizedAttribute) as? Bool == true { continue }
            var number: CGWindowID = 0
            guard _AXUIElementGetWindow(window, &number) == .success else { continue }
            collect(window, windowNumber: Int(number), depth: 0, panes: &panes, dividers: &dividers)
        }
        return (panes, dividers)
    }

    private static func collect(_ element: AXUIElement, windowNumber: Int, depth: Int,
                                panes: inout [RexPane], dividers: inout [CGRect]) {
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            let role = string(child, kAXRoleAttribute)
            let description = string(child, kAXDescriptionAttribute)
            if role == kAXGroupRole, description == "Sidebar Tabs" { continue }
            if role == kAXTextAreaRole, description == "Terminal" {
                panes.append(RexPane(title: string(element, kAXDescriptionAttribute), content: frame(child),
                                     terminal: child, windowNumber: windowNumber))
            } else if role == kAXSplitterRole {
                dividers.append(frame(child))
            } else if depth < 10 {
                collect(child, windowNumber: windowNumber, depth: depth + 1, panes: &panes, dividers: &dividers)
            }
        }
    }

    /// The mouse position in global top-left coordinates, the same space as accessibility frames.
    static func mouseLocation() -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = NSEvent.mouseLocation
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let value = attribute(application, kAXFocusedUIElementAttribute) else { return nil }
        return (value as! AXUIElement)
    }

    /// Every on-screen window on the current Space, front to back.
    static func windowOrder() -> [(number: Int, pid: pid_t, layer: Int)] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { entry in
            guard let number = entry[kCGWindowNumber as String] as? Int, let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int else { return nil }
            return (number, pid, layer)
        }
    }

    /// The process that owns the frontmost ordinary window under a point, ignoring windows of `excluding`.
    static func windowOwner(at point: CGPoint, excluding: pid_t) -> pid_t? {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for entry in info {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != excluding,
                  entry[kCGWindowLayer as String] as? Int == 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.contains(point) else { continue }
            return pid
        }
        return nil
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

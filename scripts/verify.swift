// Prints one JSON line describing each canvas pane: is the canvas window shown, does it cover the pane,
// and where is it in the window order relative to the Rex window. Usage: verify HELPER_PID
import AppKit
import ApplicationServices

func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func frame(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
var panes: [(String, CGRect)] = []
func walk(_ e: AXUIElement, _ d: Int) {
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        let role = attr(c, kAXRoleAttribute) as? String ?? "", desc = attr(c, kAXDescriptionAttribute) as? String ?? ""
        if desc == "Sidebar Tabs" { continue }
        if role == "AXTextArea", desc == "Terminal" { panes.append((attr(e, kAXDescriptionAttribute) as? String ?? "", frame(c))) }
        else if d < 10 { walk(c, d + 1) }
    }
}
let rex = NSRunningApplication.runningApplications(withBundleIdentifier: "com.superlogical.rex").first!
for w in (attr(AXUIElementCreateApplication(rex.processIdentifier), kAXWindowsAttribute) as? [AXUIElement]) ?? [] { walk(w, 0) }
let helperPid = pid_t(CommandLine.arguments.count > 1 ? Int32(CommandLine.arguments[1]) ?? 0 : 0)
let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]])
    .filter { ($0[kCGWindowLayer as String] as? Int ?? 0) <= 3 }
    .map { (pid: $0[kCGWindowOwnerPID as String] as! pid_t, bounds: CGRect(dictionaryRepresentation: $0[kCGWindowBounds as String] as! NSDictionary)!) }
    .filter { $0.bounds.width >= 100 }
let rexIndex = windows.firstIndex { $0.pid == rex.processIdentifier }
let canvasWindows = windows.enumerated().filter { $0.element.pid == helperPid }
func inward(_ r: CGRect) -> CGRect {
    let x = r.minX.rounded(.up), y = r.minY.rounded(.up)
    return CGRect(x: x, y: y, width: r.maxX.rounded(.down) - x, height: r.maxY.rounded(.down) - y)
}
var result: [[String: Any]] = []
for (title, rect) in panes where title.hasPrefix("canvas:") {
    let match = canvasWindows.first { $0.element.bounds == inward(rect) }
    result.append([
        "pane": title,
        "covered": match != nil,
        "directly_above_rex": match.map { rexIndex != nil && $0.offset == rexIndex! - 1 } ?? false,
    ])
}
let summary: [String: Any] = [
    "front": NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
    "canvas_panes_visible": result,
    "canvas_windows_shown": canvasWindows.count,
]
print(String(decoding: try! JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), as: UTF8.self))

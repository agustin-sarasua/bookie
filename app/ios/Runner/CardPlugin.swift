import Flutter
import UIKit
import UniformTypeIdentifiers

/// Write access to the microSD card in a USB-C card reader.
///
/// iOS exposes the reader through the Files app, so the user picks the card's
/// root folder and we get a security-scoped URL. Unlike Android, the URL
/// behaves like an ordinary directory once opened — FileManager does the rest.
/// What has to be looked after is the scope: the URL is only usable between
/// `startAccessingSecurityScopedResource()` and its stop, and it only survives
/// a relaunch as a bookmark, so we store the bookmark and re-resolve it.
class CardPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {

  static let channelName = "com.bookie.studio/card"
  private static let bookmarkPrefix = "cardBookmark."

  private var pendingPick: FlutterResult?

  /// handle -> (url, how many times we have started accessing it)
  private var open: [String: (url: URL, depth: Int)] = [:]

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(CardPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]

    do {
      switch call.method {
      case "pick":
        pick(result: result)
      case "resolve":
        result(try describe(handle: str(args, "handle")))
      case "list":
        result(try withCard(args) { try self.list(root: $0, path: str(args, "path")) })
      case "read":
        result(try withCard(args) { try self.read(root: $0, path: str(args, "path")) })
      case "writeBytes":
        guard let data = (args["bytes"] as? FlutterStandardTypedData)?.data else {
          throw CardError.failed("No bytes to write.")
        }
        result(try withCard(args) { try self.write(root: $0, path: str(args, "path"), data: data) })
      case "copy":
        result(try withCard(args) {
          try self.copyIn(root: $0, path: str(args, "path"), from: str(args, "src"))
        })
      case "copyOut":
        result(try withCard(args) {
          try self.copyOut(root: $0, path: str(args, "path"), to: str(args, "dest"))
        })
      case "delete":
        result(try withCard(args) { try self.delete(root: $0, path: str(args, "path")) })
      case "release":
        release(handle: try? str(args, "handle"))
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch let error as CardError {
      switch error {
      case .unavailable(let message): result(FlutterError(code: "unavailable", message: message, details: nil))
      case .failed(let message): result(FlutterError(code: "failed", message: message, details: nil))
      }
    } catch {
      result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
    }
  }

  enum CardError: Error {
    case unavailable(String)
    case failed(String)
  }

  private func str(_ args: [String: Any], _ key: String) throws -> String {
    guard let value = args[key] as? String else { throw CardError.failed("Missing \(key).") }
    return value
  }

  // ------------------------------------------------------------- picking

  private func pick(result: @escaping FlutterResult) {
    guard pendingPick == nil else {
      return result(FlutterError(code: "failed", message: "A folder picker is already open.", details: nil))
    }
    let windows = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .flatMap({ $0.windows })
    guard let host = (windows.first(where: { $0.isKeyWindow }) ?? windows.first)?
      .rootViewController else {
      return result(FlutterError(code: "failed", message: "No view controller to present on.", details: nil))
    }

    pendingPick = result
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    host.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pendingPick else { return }
    pendingPick = nil

    guard let url = urls.first else { return result(nil) }
    do {
      // The bookmark has to be made while the scope is open, or it is useless
      // after a relaunch.
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }

      let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
      let handle = UUID().uuidString
      UserDefaults.standard.set(bookmark, forKey: Self.bookmarkPrefix + handle)
      result(try describe(handle: handle))
    } catch {
      result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingPick?(nil)
    pendingPick = nil
  }

  /// Turn a stored bookmark back into a usable URL, refreshing it if iOS says
  /// it went stale (the volume was remounted at a different path).
  private func resolve(handle: String) throws -> URL {
    if let entry = open[handle] { return entry.url }
    guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkPrefix + handle) else {
      throw CardError.unavailable("This card has not been chosen on this device.")
    }
    var stale = false
    guard let url = try? URL(
      resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale
    ) else {
      throw CardError.unavailable("The card is not plugged in.")
    }
    if stale {
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
        UserDefaults.standard.set(fresh, forKey: Self.bookmarkPrefix + handle)
      }
    }
    return url
  }

  private func describe(handle: String) throws -> [String: Any?]? {
    let url: URL
    do { url = try resolve(handle: handle) } catch { return nil }

    guard url.startAccessingSecurityScopedResource() else { return nil }
    defer { url.stopAccessingSecurityScopedResource() }
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }

    let values = try? url.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeNameKey,
    ])
    // The Files picker hands back a real path, so "where does this point" is
    // just the path. Whether it is removable, and whether it is the root of the
    // volume, is not ours to claim on iOS — nil leaves the app quiet about it.
    return [
      "handle": handle,
      "name": values?.volumeName ?? url.lastPathComponent,
      "freeBytes": values?.volumeAvailableCapacityForImportantUsage,
      "totalBytes": values?.volumeTotalCapacity.map { Int64($0) },
      "location": url.path,
      "removable": nil,
      "atRoot": nil,
    ]
  }

  private func release(handle: String?) {
    guard let handle, let entry = open[handle] else { return }
    for _ in 0..<entry.depth { entry.url.stopAccessingSecurityScopedResource() }
    open.removeValue(forKey: handle)
  }

  /// Run [body] with the card's scope held open, and always close it again.
  private func withCard<T>(_ args: [String: Any], _ body: (URL) throws -> T) throws -> T {
    let handle = try str(args, "handle")
    let root = try resolve(handle: handle)
    guard root.startAccessingSecurityScopedResource() else {
      throw CardError.unavailable("The card is not plugged in.")
    }
    defer { root.stopAccessingSecurityScopedResource() }
    return try body(root)
  }

  // ------------------------------------------------------------- files

  /// Card paths arrive as "/audio/en/bear.mp3"; the leading slash is ours, not
  /// the file system's.
  private func child(_ root: URL, _ path: String) -> URL {
    var url = root
    for segment in path.split(separator: "/") where !segment.isEmpty {
      url.appendPathComponent(String(segment))
    }
    return url
  }

  private func list(root: URL, path: String) throws -> [[String: Any]] {
    let dir = child(root, path)
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]
    ) else {
      return []
    }
    return entries.map { url in
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
      return [
        "name": url.lastPathComponent,
        "isDirectory": values?.isDirectory ?? false,
        "size": values?.fileSize ?? 0,
      ]
    }
  }

  private func read(root: URL, path: String) throws -> FlutterStandardTypedData? {
    let url = child(root, path)
    guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
    return FlutterStandardTypedData(bytes: data)
  }

  private func ensureParent(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
  }

  private func write(root: URL, path: String, data: Data) throws -> Int {
    let url = child(root, path)
    try ensureParent(url)
    try data.write(to: url, options: .atomic)
    return data.count
  }

  private func copyIn(root: URL, path: String, from source: String) throws -> Int {
    let dest = child(root, path)
    try ensureParent(dest)
    if FileManager.default.fileExists(atPath: dest.path) {
      try FileManager.default.removeItem(at: dest)
    }
    try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: dest)
    let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    return size
  }

  private func copyOut(root: URL, path: String, to destination: String) throws -> Int {
    let source = child(root, path)
    let dest = URL(fileURLWithPath: destination)
    try FileManager.default.createDirectory(
      at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    if FileManager.default.fileExists(atPath: dest.path) {
      try FileManager.default.removeItem(at: dest)
    }
    try FileManager.default.copyItem(at: source, to: dest)
    return (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
  }

  private func delete(root: URL, path: String) throws -> Bool {
    let url = child(root, path)
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    try FileManager.default.removeItem(at: url)
    return true
  }
}

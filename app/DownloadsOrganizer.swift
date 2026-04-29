import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

struct ItemState: Codable {
    var kind: String
    var size: Int64
    var mtime: Double
    var firstSeen: Double
    var stableRuns: Int
    var lastSeen: Double
}

struct State: Codable {
    var version: Int
    var startedAt: Double
    var items: [String: ItemState]
}

struct Config {
    static let inProgressSuffixes = [".download", ".crdownload", ".part"]
    static let inProgressExtensions = ["download", "crdownload", "part"]
    static let appName = "DownloadsOrganizer.app"
    static let recentFileLimit = 12
    static let timerInterval: TimeInterval = 60
    static let changePassDelay: TimeInterval = 2
    static let changeFollowupDelay: TimeInterval = 8

    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let downloads = home.appendingPathComponent("Downloads")
    static let desktop = home.appendingPathComponent("Desktop")
    static let appSupport = home.appendingPathComponent("Library/Application Support/DownloadsOrganizer")
    static let statePath = appSupport.appendingPathComponent("state.json")
    static let lockPath = appSupport.appendingPathComponent("lock")
    static let moveIndexPath = appSupport.appendingPathComponent("move-index.tsv")
    static let logDir = home.appendingPathComponent("Library/Logs/DownloadsOrganizer")
    static let logPath = logDir.appendingPathComponent("organize.log")
}

struct Options {
    var dryRun = false
    var fullSweep = false
    var minStableRuns = 1
    var once = false
}

var lockFileDescriptor: Int32 = -1
var appController: MenuBarController?

func ensureRuntimeDirs() {
    let fm = FileManager.default
    try? fm.createDirectory(at: Config.appSupport, withIntermediateDirectories: true)
    try? fm.createDirectory(at: Config.logDir, withIntermediateDirectories: true)
}

func log(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "\(ts) \(message)\n"
    if let data = line.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: Config.logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Config.logPath)
        }
    }
    print(message)
}

func tsvField(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
}

func appendMoveIndex(timestamp: String, src: URL, movedTo: URL, typeLabel: String) {
    let fields = [
        timestamp,
        src.lastPathComponent,
        src.path,
        movedTo.path,
        typeLabel
    ].map(tsvField)
    let line = fields.joined(separator: "\t") + "\n"

    guard let data = line.data(using: .utf8) else {
        return
    }

    if let handle = try? FileHandle(forWritingTo: Config.moveIndexPath) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: Config.moveIndexPath)
    }
}

func lockOwnerText() -> String? {
    guard
        let data = try? Data(contentsOf: Config.lockPath),
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        !text.isEmpty
    else {
        return nil
    }
    return text
}

func acquireLock() -> Bool {
    let fd = Darwin.open(
        Config.lockPath.path,
        O_CREAT | O_RDWR | O_CLOEXEC | O_EXLOCK | O_NONBLOCK,
        0o600
    )
    if fd == -1 {
        let owner = lockOwnerText()
        if errno == EWOULDBLOCK {
            if let owner {
                log("SKIP: organizer already running with pid \(owner).")
            } else {
                log("SKIP: organizer already running.")
            }
        } else {
            log("ERROR: failed to open lock file at \(Config.lockPath.path).")
        }
        return false
    }

    guard Darwin.ftruncate(fd, 0) == 0 else {
        log("ERROR: failed to reset lock file.")
        Darwin.close(fd)
        return false
    }

    let pid = "\(getpid())"
    _ = pid.withCString { cstr in
        Darwin.write(fd, cstr, strlen(cstr))
    }
    lockFileDescriptor = fd
    return true
}

func releaseLock() {
    if lockFileDescriptor != -1 {
        Darwin.close(lockFileDescriptor)
        lockFileDescriptor = -1
    }
}

func loadState(now: Double) -> State {
    guard let data = try? Data(contentsOf: Config.statePath) else {
        return State(version: 1, startedAt: now, items: [:])
    }

    do {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var state = try decoder.decode(State.self, from: data)
        if state.items.isEmpty && state.startedAt <= 0 {
            state.startedAt = now
        }
        return state
    } catch {
        return State(version: 1, startedAt: now, items: [:])
    }
}

func saveState(_ state: State) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    if let data = try? encoder.encode(state) {
        let tmp = Config.statePath.appendingPathExtension("tmp")
        try? data.write(to: tmp)
        _ = try? FileManager.default.replaceItemAt(Config.statePath, withItemAt: tmp)
    }
}

func safeMove(src: URL, dest: URL, dryRun: Bool) throws -> URL {
    let fm = FileManager.default
    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    if dryRun {
        return dest
    }
    if !fm.fileExists(atPath: dest.path) {
        try fm.moveItem(at: src, to: dest)
        return dest
    }

    let base = dest.deletingPathExtension().lastPathComponent
    let ext = dest.pathExtension
    for i in 1..<1000 {
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let candidate = dest.deletingLastPathComponent()
            .appendingPathComponent("\(base)__mv\(i)\(suffix)")
        if !fm.fileExists(atPath: candidate.path) {
            try fm.moveItem(at: src, to: candidate)
            return candidate
        }
    }
    throw NSError(domain: "DownloadsOrganizer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Too many name collisions for \(dest.path)"])
}

func shouldSkip(url: URL, isDir: Bool) -> Bool {
    let name = url.lastPathComponent
    if name.hasPrefix(".") {
        return true
    }
    if isDir && name.hasPrefix("_") && url.pathExtension.lowercased() != "app" {
        return true
    }
    if isDir && url.pathExtension.lowercased() != "app" {
        return true
    }
    if Config.inProgressSuffixes.contains(where: { name.hasSuffix($0) }) {
        return true
    }
    if Config.inProgressExtensions.contains(url.pathExtension.lowercased()) {
        return true
    }
    return false
}

func classifyDestination(url: URL, isDir: Bool, mtime: Double, contentType: UTType?) -> URL {
    let year = String(Calendar.current.component(.year, from: Date(timeIntervalSince1970: mtime)))
    let ext = url.pathExtension.lowercased()

    if isDir && ext == "app" {
        return Config.downloads.appendingPathComponent("_Apps")
    }

    if ["dmg", "pkg", "mpkg", "iso"].contains(ext) {
        return Config.downloads.appendingPathComponent("_Installers")
    }

    if ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"].contains(ext) {
        return Config.downloads.appendingPathComponent("_Archives")
    }

    if ext == "pdf" || contentType?.conforms(to: .pdf) == true {
        return Config.downloads.appendingPathComponent("_PDF")
    }

    if ["xlsx", "xls", "numbers"].contains(ext) || contentType?.conforms(to: .spreadsheet) == true {
        return Config.downloads.appendingPathComponent("_Docs/Spreadsheets/Excel/\(year)")
    }

    if ext == "csv" || contentType?.conforms(to: .commaSeparatedText) == true {
        return Config.downloads.appendingPathComponent("_CSV")
    }

    if ["doc", "docx", "pages", "rtf", "odt"].contains(ext) {
        return Config.downloads.appendingPathComponent("_Docs/Word/\(year)")
    }

    if ["ppt", "pptx", "key"].contains(ext) || contentType?.conforms(to: .presentation) == true {
        return Config.downloads.appendingPathComponent("_Docs/Presentations/\(year)")
    }

    if ["eml", "msg"].contains(ext) || contentType?.conforms(to: .emailMessage) == true {
        return Config.downloads.appendingPathComponent("_EML/\(year)")
    }

    if ["html", "htm", "webloc"].contains(ext) || contentType?.conforms(to: .html) == true {
        return Config.downloads.appendingPathComponent("_Docs/Web/\(year)")
    }

    if ["md", "txt", "log", "patch"].contains(ext) || contentType?.conforms(to: .plainText) == true {
        return Config.downloads.appendingPathComponent("_Docs/Text/\(year)")
    }

    if ["png", "jpg", "jpeg", "heic", "gif", "bmp", "tif", "tiff", "webp", "svg"].contains(ext)
        || contentType?.conforms(to: .image) == true {
        return Config.downloads.appendingPathComponent("_Images")
    }

    if ["mp3", "wav", "m4a", "aac", "flac", "ogg", "aiff"].contains(ext)
        || contentType?.conforms(to: .audio) == true {
        return Config.downloads.appendingPathComponent("_Audio")
    }

    if ["mp4", "mov", "mkv", "avi", "wmv", "m4v", "webm"].contains(ext)
        || contentType?.conforms(to: .movie) == true
        || contentType?.conforms(to: .video) == true {
        return Config.downloads.appendingPathComponent("_Video")
    }

    if ["ttf", "otf", "woff", "woff2"].contains(ext) {
        return Config.downloads.appendingPathComponent("_Fonts")
    }

    if ["py", "js", "ts", "json", "yaml", "yml", "toml", "ipynb", "sh", "gs", "swift"].contains(ext) {
        return Config.downloads.appendingPathComponent("_Code")
    }

    if contentType?.conforms(to: .executable) == true {
        return Config.downloads.appendingPathComponent("_Binaries")
    }

    return Config.downloads.appendingPathComponent("_Other")
}

func organizeOnce(options: Options) -> Int32 {
    ensureRuntimeDirs()

    guard acquireLock() else {
        return 0
    }
    defer { releaseLock() }

    let now = Date().timeIntervalSince1970
    var state = loadState(now: now)
    let fm = FileManager.default
    let keys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .contentTypeKey
    ]

    var entries: [URL] = []
    do {
        entries = try fm.contentsOfDirectory(at: Config.downloads, includingPropertiesForKeys: Array(keys))
    } catch {
        log(
            "PermissionError: this background job can't read ~/Downloads due to macOS Privacy & Security. " +
            "Fix: System Settings -> Privacy & Security -> Full Disk Access -> add " +
            "~/Applications/\(Config.appName) (and enable it), then reload the agent."
        )
        return 2
    }

    var currentKeys = Set<String>()
    var moves: [(URL, URL, String)] = []

    for url in entries {
        let values = try? url.resourceValues(forKeys: keys)
        if values?.isSymbolicLink == true {
            continue
        }
        let isDir = values?.isDirectory ?? false
        if shouldSkip(url: url, isDir: isDir) {
            continue
        }
        let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? now

        let size = Int64(values?.fileSize ?? 0)
        let key = url.path
        currentKeys.insert(key)

        let prev = state.items[key]
        let stableRuns: Int
        if let prev = prev,
           prev.kind == (isDir ? "dir" : "file"),
           prev.size == size,
           prev.mtime == mtime {
            stableRuns = prev.stableRuns + 1
        } else {
            stableRuns = 0
        }

        let firstSeen = prev?.firstSeen ?? now
        state.items[key] = ItemState(
            kind: isDir ? "dir" : "file",
            size: size,
            mtime: mtime,
            firstSeen: firstSeen,
            stableRuns: stableRuns,
            lastSeen: now
        )

        if stableRuns < options.minStableRuns {
            continue
        }

        let contentType = isDir ? nil : values?.contentType
        let destDir = classifyDestination(url: url, isDir: isDir, mtime: mtime, contentType: contentType)
        let dest = destDir.appendingPathComponent(url.lastPathComponent)
        if dest.path == url.path {
            continue
        }
        let typeLabel = contentType?.identifier ?? ""
        moves.append((url, dest, typeLabel))
    }

    var movedCount = 0
    for (src, dest, typeLabel) in moves {
        if !fm.fileExists(atPath: src.path) {
            state.items.removeValue(forKey: src.path)
            continue
        }
        do {
            let movedTo = try safeMove(src: src, dest: dest, dryRun: options.dryRun)
            state.items.removeValue(forKey: src.path)
            movedCount += 1
            let prefix = options.dryRun ? "DRYRUN" : "MOVE"
            let timestamp = ISO8601DateFormatter().string(from: Date())
            log("\(prefix): \(src.lastPathComponent) -> \(movedTo.path) | \(typeLabel)")
            if !options.dryRun {
                appendMoveIndex(timestamp: timestamp, src: src, movedTo: movedTo, typeLabel: typeLabel)
            }
        } catch {
            log("ERROR: failed to move \(src.path) -> \(dest.path): \(error)")
        }
    }

    for key in state.items.keys where !currentKeys.contains(key) {
        state.items.removeValue(forKey: key)
    }

    saveState(state)

    if movedCount > 0 && !options.dryRun {
        log("Moved \(movedCount) item(s).")
    }
    return 0
}

func recentFiles(limit: Int) -> [URL] {
    let keys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isHiddenKey,
        .contentModificationDateKey,
        .contentTypeKey
    ]

    var collected: [String: (URL, Date)] = [:]
    collectRecentFiles(in: Config.downloads, keys: keys, into: &collected)

    let screenshots = screenshotDirectory()
    if !isPathWithinDirectory(screenshots, base: Config.downloads) {
        collectScreenshots(in: screenshots, keys: keys, into: &collected)
    }

    return collected.values
        .sorted { lhs, rhs in
            if lhs.1 == rhs.1 {
                return lhs.0.lastPathComponent.localizedCaseInsensitiveCompare(rhs.0.lastPathComponent) == .orderedAscending
            }
            return lhs.1 > rhs.1
        }
        .prefix(limit)
        .map { $0.0 }
}

func copyTextToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

func copyFileURLToPasteboard(_ url: URL) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects([url as NSURL])
}

func standardizedPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
}

func isPathWithinDirectory(_ candidate: URL, base: URL) -> Bool {
    let candidatePath = standardizedPath(candidate)
    let basePath = standardizedPath(base)
    return candidatePath == basePath || candidatePath.hasPrefix(basePath + "/")
}

func screenshotDirectory() -> URL {
    if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !path.isEmpty {
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }
    return Config.desktop
}

func isScreenshotFile(url: URL, contentType: UTType?) -> Bool {
    let name = url.deletingPathExtension().lastPathComponent.lowercased()
    let ext = url.pathExtension.lowercased()
    let looksLikeScreenshot = name.hasPrefix("screenshot ") || name.hasPrefix("screen shot ")
    guard looksLikeScreenshot else {
        return false
    }
    if contentType?.conforms(to: .image) == true || contentType?.conforms(to: .pdf) == true {
        return true
    }
    return ["png", "jpg", "jpeg", "heic", "tif", "tiff", "pdf"].contains(ext)
}

func mergeRecentFile(_ url: URL, modifiedAt: Date, into collected: inout [String: (URL, Date)]) {
    let key = standardizedPath(url)
    guard collected[key] == nil || modifiedAt > collected[key]!.1 else {
        return
    }
    collected[key] = (url, modifiedAt)
}

func collectFiles(
    in base: URL,
    keys: Set<URLResourceKey>,
    recursive: Bool,
    include: (URL, URLResourceValues) -> Bool,
    into collected: inout [String: (URL, Date)]
) {
    let fm = FileManager.default
    func collect(_ url: URL) {
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return
        }
        if values.isDirectory == true {
            return
        }
        if values.isHidden == true || url.lastPathComponent.hasPrefix(".") {
            return
        }
        guard include(url, values) else {
            return
        }
        let modifiedAt = values.contentModificationDate ?? .distantPast
        mergeRecentFile(url, modifiedAt: modifiedAt, into: &collected)
    }

    if recursive {
        guard let enumerator = fm.enumerator(
            at: base,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return
        }
        while let url = enumerator.nextObject() as? URL {
            collect(url)
        }
        return
    }

    guard let entries = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: Array(keys)) else {
        return
    }
    for url in entries {
        collect(url)
    }
}

func collectRecentFiles(in base: URL, keys: Set<URLResourceKey>, into collected: inout [String: (URL, Date)]) {
    collectFiles(in: base, keys: keys, recursive: true, include: { _, _ in true }, into: &collected)
}

func collectScreenshots(in base: URL, keys: Set<URLResourceKey>, into collected: inout [String: (URL, Date)]) {
    collectFiles(
        in: base,
        keys: keys,
        recursive: false,
        include: { url, values in isScreenshotFile(url: url, contentType: values.contentType) },
        into: &collected
    )
}

func relativeFolderDescription(for url: URL) -> String {
    if isScreenshotFile(url: url, contentType: nil) {
        return "Screenshots"
    }
    let folder = url.deletingLastPathComponent().path
    let base = Config.downloads.path
    if folder == base {
        return "Downloads"
    }
    if folder.hasPrefix(base + "/") {
        return String(folder.dropFirst(base.count + 1))
    }
    return folder
}

func shortDisplayTitle(_ title: String, limit: Int = 44) -> String {
    guard title.count > limit else {
        return title
    }
    return String(title.prefix(limit - 1)) + "…"
}

final class RecentFileCellView: NSTableCellView {
    private let subtitleField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        iconView.imageScaling = .scaleProportionallyDown
        self.imageView = iconView

        let titleField = NSTextField(labelWithString: "")
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 1
        self.textField = titleField

        subtitleField.translatesAutoresizingMaskIntoConstraints = false
        subtitleField.font = .systemFont(ofSize: 11)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingMiddle
        subtitleField.maximumNumberOfLines = 1

        let textStack = NSStackView(views: [titleField, subtitleField])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.spacing = 2
        textStack.alignment = .leading

        addSubview(iconView)
        addSubview(textStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with url: URL) {
        imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
        textField?.stringValue = shortDisplayTitle(url.lastPathComponent)
        subtitleField.stringValue = relativeFolderDescription(for: url)
        toolTip = url.path
    }
}

final class RecentFilesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let contextMenu = NSMenu()
    private let openDownloadsButton = NSButton(title: "Downloads", target: nil, action: nil)
    private var filteredFiles: [URL] = []

    var files: [URL] = [] {
        didSet {
            applyFilter()
        }
    }

    var onOpenDownloads: (() -> Void)?
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 360))

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search recent files"
        searchField.maximumRecents = 0
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("RecentFilesColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 42
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.focusRingType = .none
        tableView.backgroundColor = .clear
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelectedRow(_:))
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        contextMenu.delegate = self
        tableView.menu = contextMenu

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = tableView

        openDownloadsButton.target = self
        openDownloadsButton.action = #selector(openDownloads(_:))

        let buttonRow = NSStackView(views: [openDownloadsButton])
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        view.addSubview(searchField)
        view.addSubview(scrollView)
        view.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -10),

            buttonRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            buttonRow.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -10),
            buttonRow.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10)
        ])

        applyFilter()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredFiles.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("RecentFileCellView")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? RecentFileCellView) ?? {
            let view = RecentFileCellView()
            view.identifier = identifier
            return view
        }()
        cell.configure(with: filteredFiles[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        filteredFiles[row] as NSURL
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard tableView.clickedRow >= 0, tableView.clickedRow < filteredFiles.count else {
            return
        }

        let url = filteredFiles[tableView.clickedRow]

        let copyPath = NSMenuItem(title: "Copy Path", action: #selector(copyPathFromContext(_:)), keyEquivalent: "")
        copyPath.target = self
        copyPath.representedObject = url
        menu.addItem(copyPath)

        let copyFile = NSMenuItem(title: "Copy File", action: #selector(copyFileFromContext(_:)), keyEquivalent: "")
        copyFile.target = self
        copyFile.representedObject = url
        menu.addItem(copyFile)

        let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealFromContext(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.representedObject = url
        menu.addItem(reveal)
    }

    @objc private func openSelectedRow(_ sender: Any?) {
        guard tableView.clickedRow >= 0, tableView.clickedRow < filteredFiles.count else {
            let row = tableView.selectedRow
            guard row >= 0, row < filteredFiles.count else {
                return
            }
            NSWorkspace.shared.open(filteredFiles[row])
            return
        }
        NSWorkspace.shared.open(filteredFiles[tableView.clickedRow])
    }

    @objc private func openDownloads(_ sender: Any?) {
        onOpenDownloads?()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        applyFilter()
    }

    @objc private func copyPathFromContext(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else {
            return
        }
        copyTextToPasteboard(url.path)
    }

    @objc private func copyFileFromContext(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else {
            return
        }
        copyFileURLToPasteboard(url)
    }

    @objc private func revealFromContext(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredFiles = files
        } else {
            filteredFiles = files.filter { url in
                url.lastPathComponent.localizedCaseInsensitiveContains(query) ||
                url.path.localizedCaseInsensitiveContains(query)
            }
        }
        if isViewLoaded {
            tableView.reloadData()
            tableView.deselectAll(nil)
        }
    }
}

final class MenuBarController: NSObject, NSApplicationDelegate {
    private let organizerQueue = DispatchQueue(label: "DownloadsOrganizer.organizer", qos: .utility)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let recentFilesViewController = RecentFilesViewController()

    private var timer: Timer?
    private var directoryMonitor: DispatchSourceFileSystemObject?
    private var screenshotMonitor: DispatchSourceFileSystemObject?
    private var pendingChangeWorkItem: DispatchWorkItem?
    private var pendingFollowupWorkItem: DispatchWorkItem?
    private var pendingScreenshotRefreshWorkItem: DispatchWorkItem?
    private var lastRunDate: Date?
    private var lastExitCode: Int32 = 0
    private var recentFilesSnapshot: [URL] = []
    private var isRefreshingRecents = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        refreshRecentFiles(reason: "launch")
        startTimer()
        startDirectoryMonitor()
        scheduleOrganizerRun(after: 0, reason: "launch")
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        pendingChangeWorkItem?.cancel()
        pendingFollowupWorkItem?.cancel()
        pendingScreenshotRefreshWorkItem?.cancel()
        directoryMonitor?.cancel()
        screenshotMonitor?.cancel()
        popover.performClose(nil)
    }

    private func setupStatusItem() {
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "folder.badge.gearshape", accessibilityDescription: "Recent Downloads") {
                image.isTemplate = true
                button.image = image
            }
            button.title = " Recents"
            button.toolTip = "Downloads Organizer"
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
    }

    private func setupPopover() {
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 420, height: 360)
        popover.contentViewController = recentFilesViewController
        recentFilesViewController.onOpenDownloads = { [weak self] in
            self?.openDownloads(nil)
        }
    }

    private func startTimer() {
        let timer = Timer.scheduledTimer(withTimeInterval: Config.timerInterval, repeats: true) { [weak self] _ in
            self?.runOrganizer(reason: "timer")
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func startDirectoryMonitor() {
        directoryMonitor = makeDirectoryMonitor(at: Config.downloads) { [weak self] in
            self?.scheduleChangeDrivenRuns()
        }
        directoryMonitor?.resume()

        let screenshots = screenshotDirectory()
        if !isPathWithinDirectory(screenshots, base: Config.downloads) {
            screenshotMonitor = makeDirectoryMonitor(at: screenshots) { [weak self] in
                self?.scheduleScreenshotRefresh()
            }
            screenshotMonitor?.resume()
        }
    }

    private func makeDirectoryMonitor(
        at directory: URL,
        handler: @escaping () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = Darwin.open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            return nil
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib, .extend],
            queue: organizerQueue
        )
        source.setEventHandler(handler: handler)
        source.setCancelHandler {
            Darwin.close(fd)
        }
        return source
    }

    private func scheduleChangeDrivenRuns() {
        pendingChangeWorkItem?.cancel()
        pendingFollowupWorkItem?.cancel()

        let first = DispatchWorkItem { [weak self] in
            self?.runOrganizer(reason: "downloads-change")
        }
        let second = DispatchWorkItem { [weak self] in
            self?.runOrganizer(reason: "downloads-change-followup")
        }

        pendingChangeWorkItem = first
        pendingFollowupWorkItem = second

        organizerQueue.asyncAfter(deadline: .now() + Config.changePassDelay, execute: first)
        organizerQueue.asyncAfter(deadline: .now() + Config.changeFollowupDelay, execute: second)
    }

    private func scheduleScreenshotRefresh() {
        pendingScreenshotRefreshWorkItem?.cancel()

        let refresh = DispatchWorkItem { [weak self] in
            self?.refreshRecentFiles(reason: "screenshot-change")
        }

        pendingScreenshotRefreshWorkItem = refresh
        organizerQueue.asyncAfter(deadline: .now() + Config.changePassDelay, execute: refresh)
    }

    private func scheduleOrganizerRun(after delay: TimeInterval, reason: String) {
        organizerQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runOrganizer(reason: reason)
        }
    }

    private func runOrganizer(reason: String) {
        let result = organizeOnce(options: Options())
        DispatchQueue.main.async { [weak self] in
            self?.lastRunDate = Date()
            self?.lastExitCode = result
            self?.updateStatus(reason: reason)
        }
        refreshRecentFiles(reason: reason)
    }

    private func updateStatus(reason: String) {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let runText = lastRunDate.map { formatter.string(from: $0) } ?? "never"
        statusItem.button?.toolTip = "Downloads Organizer\nLast scan: \(runText)\nLast result: \(lastExitCode)\nReason: \(reason)"
    }

    private func refreshRecentFiles(reason: String) {
        guard !isRefreshingRecents else {
            return
        }
        isRefreshingRecents = true
        organizerQueue.async { [weak self] in
            let files = recentFiles(limit: Config.recentFileLimit)
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.recentFilesSnapshot = files
                self.isRefreshingRecents = false
                self.recentFilesViewController.files = files
                self.updateStatus(reason: reason)
            }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else {
            return
        }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func openDownloads(_ sender: Any?) {
        NSWorkspace.shared.open(Config.downloads)
    }
}

func parseOptions() -> Options {
    var options = Options()
    var i = 1
    let args = CommandLine.arguments
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--dry-run":
            options.dryRun = true
        case "--full-sweep":
            options.fullSweep = true
        case "--min-stable-runs":
            if i + 1 < args.count {
                options.minStableRuns = Int(args[i + 1]) ?? options.minStableRuns
                i += 1
            }
        case "--once":
            options.once = true
        default:
            break
        }
        i += 1
    }
    return options
}

let options = parseOptions()
if CommandLine.arguments.count > 1 || options.once {
    exit(organizeOnce(options: options))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
appController = MenuBarController()
app.delegate = appController
app.run()

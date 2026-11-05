import Foundation
import Combine

struct LCAppStorageItem: Identifiable {
    let id: UUID

    let appModel: LCAppModel
    let bundleSize: Int64?
    let containersSize: Int64

    let totalSize: Int64

    let containerDetails: [LCAppStorageContainerItem]
}

struct LCAppStorageContainerItem: Identifiable {
    let id: UUID
    let name: String
    let size: Int64
    let isExternalContainer: Bool
}

/// A folder inside Data/Application that no app points to: a container that was renamed in Files,
/// one whose app was deleted, or one left behind by an old version. Before, it was silently counted as "Other".
struct LCOrphanContainerItem: Identifiable {
    let url: URL
    let folderName: String
    /// "name" saved in LCContainerInfo.plist (the name shown in LiveContainer), if the plist is there
    let containerName: String?
    /// bundle id of the app that created it, from LCContainerInfo.plist
    let appIdentifier: String?
    let keychainGroupId: Int
    let isShared: Bool
    let size: Int64

    var id: String { url.path }
}

struct LCStorageBreakdown {
    let totalSize: Int64
    let appBundleSize: Int64
    let containersSize: Int64
    let orphanContainersSize: Int64
    let temporaryFilesSize: Int64
    let appGroupSize: Int64
    let tweaksSize: Int64
    /// Documents/.Trash: what is deleted from Files inside LiveContainer ("Recently Deleted"), still using space
    let filesTrashSize: Int64
    /// other items whose name starts with "." in the root of the LiveContainer folder (Files never shows them)
    let hiddenRootSize: Int64
    /// LiveContainer's own Library (not visible in Files)
    let lcLibrarySize: Int64
    /// The rest of the shared folder (app group) LiveContainer borrows from SideStore: signed copies of the apps
    /// SideStore installs (Apps/Payloads), its backups, caches... iOS counts it for the app in Settings.
    let sharedRestSize: Int64
    let otherSize: Int64

    let appItems: [LCAppStorageItem]
    let orphanContainers: [LCOrphanContainerItem]
}

/// One file or folder found by the deep scan.
struct LCStorageFoundItem: Identifiable {
    let url: URL
    let size: Int64
    let isDirectory: Bool
    let isHidden: Bool

    var id: String { url.path }
}

struct LCStorageDeepScanResult {
    /// items whose own name starts with "." (folders counted as a whole), biggest first
    let hiddenItems: [LCStorageFoundItem]
    let hiddenTotal: Int64
    let hiddenCount: Int
    /// biggest regular files (outside hidden folders), biggest first
    let largestFiles: [LCStorageFoundItem]
}

@MainActor
final class LCStorageManagementModel: ObservableObject {
    @Published var breakdown: LCStorageBreakdown?
    @Published var isCalculating = false
    @Published var errorInfo: String?

    @Published var deepScan: LCStorageDeepScanResult?
    @Published var isDeepScanning = false

    func refresh(apps: [LCAppModel], hiddenApps: [LCAppModel]) async {
        guard !isCalculating else {
            return
        }

        isCalculating = true
        defer { isCalculating = false }
        errorInfo = nil
        breakdown = nil

        do {
            breakdown = try await Self.calculateBreakdown(apps: apps, hiddenApps: hiddenApps)
        } catch {
            errorInfo = error.localizedDescription
        }
    }

    func runDeepScan() async {
        guard !isDeepScanning else {
            return
        }
        isDeepScanning = true
        defer { isDeepScanning = false }
        let roots = LCStorageScanner.scanRoots
        deepScan = await Task.detached(priority: .userInitiated) {
            LCStorageScanner.deepScan(roots: roots)
        }.value
    }

    private enum StorageCategory {
        case temporaryFiles
        case appGroup
        case tweaks
        case filesTrash
        case hiddenRoot
        case lcLibrary
        case sharedRest
        case knownRoots
    }

    nonisolated static func isBuiltInApp(_ appInfo: LCAppInfo) -> Bool {
        return appInfo is BuiltInSideStoreAppInfo || appInfo is BuiltInOmniStationAppInfo
    }

    nonisolated private static func calculateBreakdown(apps: [LCAppModel], hiddenApps: [LCAppModel]) async throws -> LCStorageBreakdown {
        let hiddenUnlocked = await MainActor.run { DataManager.shared.model.isHiddenAppUnlocked }

        var listedApps: [LCAppModel]
        if hiddenUnlocked {
            listedApps = apps + hiddenApps
        } else {
            listedApps = apps
        }

        if UserDefaults.sideStoreExist() {
            listedApps.append(LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared))
        }
        // The built-in OmniStation keeps its data in Documents/OmniStation: before it ended up in "Other".
        if UserDefaults.omniStationExist() {
            listedApps.append(LCAppModel(appInfo: BuiltInOmniStationAppInfo.shared))
        }

        let appItems = try await calculateAppItems(from: listedApps)

        // Every folder that some app points to (hidden apps included, even when locked).
        var referencedPaths = Set<String>()
        for app in apps + hiddenApps + listedApps {
            for container in app.uiContainers {
                referencedPaths.insert(container.containerURL.lcStorageKey)
            }
        }

        var countedContainerPaths = Set<String>()
        var countedBundlePaths = Set<String>()
        var appBundleSize: Int64 = 0
        var containersSize: Int64 = 0

        for appItem in appItems {
            let appInfo = appItem.appModel.appInfo
            if !isBuiltInApp(appInfo), let bundlePath = appInfo.bundlePath() {
                let key = URL(fileURLWithPath: bundlePath).lcStorageKey
                if countedBundlePaths.insert(key).inserted {
                    appBundleSize += appItem.bundleSize ?? 0
                }
            }
        }
        for appItem in appItems {
            for (index, container) in appItem.appModel.uiContainers.enumerated() where !LCStorageScanner.isExternal(container) {
                let key = container.containerURL.lcStorageKey
                if countedContainerPaths.insert(key).inserted, index < appItem.containerDetails.count {
                    containersSize += appItem.containerDetails[index].size
                }
            }
        }

        // Locked hidden apps aren't listed, but their space is theirs, not "Other".
        if !hiddenUnlocked {
            for app in hiddenApps {
                if let bundlePath = app.appInfo.bundlePath() {
                    let url = URL(fileURLWithPath: bundlePath)
                    if countedBundlePaths.insert(url.lcStorageKey).inserted {
                        appBundleSize += LCStorageScanner.size(of: url)
                    }
                }
                for container in app.uiContainers where !LCStorageScanner.isExternal(container) {
                    if countedContainerPaths.insert(container.containerURL.lcStorageKey).inserted {
                        containersSize += LCStorageScanner.size(of: container.containerURL)
                    }
                }
            }
        }

        let orphanContainers = findOrphanContainers(referencedPaths: referencedPaths)
        let orphanContainersSize = orphanContainers.reduce(Int64(0)) { $0 + $1.size }

        let knownRoots = uniquePaths([LCPath.docPath, LCPath.lcGroupDocPath])
        let appGroupRoots = uniquePaths([LCPath.appGroupPath, LCPath.lcGroupAppGroupPath])
        let tweakRoots = uniquePaths([LCPath.tweakPath, LCPath.lcGroupTweakPath])
        let hiddenRootItems = topLevelHiddenItems(in: knownRoots)
        let trashURLs = hiddenRootItems.filter { $0.lastPathComponent == ".Trash" }
        let otherHiddenURLs = hiddenRootItems.filter { $0.lastPathComponent != ".Trash" }

        var sizesByCategory: [StorageCategory: Int64] = [:]
        try await withThrowingTaskGroup(of: (StorageCategory, Int64).self) { group in
            group.addTask(priority: .utility) {
                (.temporaryFiles, LCStorageScanner.size(of: FileManager.default.temporaryDirectory))
            }
            group.addTask(priority: .utility) {
                (.appGroup, LCStorageScanner.combinedSize(of: appGroupRoots))
            }
            group.addTask(priority: .utility) {
                (.tweaks, LCStorageScanner.combinedSize(of: tweakRoots))
            }
            group.addTask(priority: .utility) {
                (.filesTrash, LCStorageScanner.combinedSize(of: trashURLs))
            }
            group.addTask(priority: .utility) {
                (.hiddenRoot, LCStorageScanner.combinedSize(of: otherHiddenURLs))
            }
            group.addTask(priority: .utility) {
                var librarySize: Int64 = 0
                if let libraryPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
                    librarySize = LCStorageScanner.size(of: libraryPath)
                }
                return (.lcLibrary, librarySize)
            }
            group.addTask(priority: .utility) {
                (.knownRoots, LCStorageScanner.combinedSize(of: knownRoots))
            }
            group.addTask(priority: .utility) {
                (.sharedRest, LCStorageScanner.sharedRestSize())
            }
            for try await (category, size) in group {
                sizesByCategory[category] = size
            }
        }

        let temporaryFilesSize = sizesByCategory[.temporaryFiles] ?? 0
        let appGroupSize = sizesByCategory[.appGroup] ?? 0
        let tweaksSize = sizesByCategory[.tweaks] ?? 0
        let filesTrashSize = sizesByCategory[.filesTrash] ?? 0
        let hiddenRootSize = sizesByCategory[.hiddenRoot] ?? 0
        let lcLibrarySize = sizesByCategory[.lcLibrary] ?? 0
        let knownRootsSize = sizesByCategory[.knownRoots] ?? 0
        let sharedRestSize = sizesByCategory[.sharedRest] ?? 0

        // Other is now only what really has no owner: loose files in the root, leftovers, folders made by hand...
        let explained = appBundleSize + containersSize + orphanContainersSize + appGroupSize + tweaksSize + filesTrashSize + hiddenRootSize
        let otherSize = max(0, knownRootsSize - explained)

        return LCStorageBreakdown(
            totalSize: explained + otherSize + temporaryFilesSize + lcLibrarySize + sharedRestSize,
            appBundleSize: appBundleSize,
            containersSize: containersSize,
            orphanContainersSize: orphanContainersSize,
            temporaryFilesSize: temporaryFilesSize,
            appGroupSize: appGroupSize,
            tweaksSize: tweaksSize,
            filesTrashSize: filesTrashSize,
            hiddenRootSize: hiddenRootSize,
            lcLibrarySize: lcLibrarySize,
            sharedRestSize: sharedRestSize,
            otherSize: otherSize,
            appItems: appItems,
            orphanContainers: orphanContainers
        )
    }

    nonisolated static func findOrphanContainers(referencedPaths: Set<String>) -> [LCOrphanContainerItem] {
        let fm = FileManager.default
        var result: [LCOrphanContainerItem] = []
        var seen = Set<String>()
        let roots: [(URL, Bool)] = [(LCPath.dataPath, false), (LCPath.lcGroupDataPath, true)]
        for (root, isShared) in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root.path) else {
                continue
            }
            for name in names {
                let url = root.appendingPathComponent(name)
                let key = url.lcStorageKey
                guard seen.insert(key).inserted, !referencedPaths.contains(key) else {
                    continue
                }
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    continue
                }
                let info = NSDictionary(contentsOf: url.appendingPathComponent("LCContainerInfo.plist")) as? [String: Any]
                result.append(LCOrphanContainerItem(
                    url: url,
                    folderName: name,
                    containerName: info?["name"] as? String,
                    appIdentifier: info?["appIdentifier"] as? String,
                    keychainGroupId: info?["keychainGroupId"] as? Int ?? -1,
                    // when there is no app group, lcGroupDataPath is dataPath: the folder is private
                    isShared: isShared && LCPath.lcGroupDataPath.lcStorageKey != LCPath.dataPath.lcStorageKey,
                    size: LCStorageScanner.size(of: url)
                ))
            }
        }
        return result.sorted { $0.size > $1.size }
    }

    nonisolated private static func topLevelHiddenItems(in roots: [URL]) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        for root in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root.path) else {
                continue
            }
            for name in names where name.hasPrefix(".") {
                result.append(root.appendingPathComponent(name))
            }
        }
        return result
    }

    nonisolated private static func calculateAppItem(
        from input: LCAppModel
    ) async throws -> LCAppStorageItem {
        var containerDetails: [LCAppStorageContainerItem] = []
        containerDetails.reserveCapacity(input.uiContainers.count)

        var containersSize: Int64 = 0
        for container in input.uiContainers {
            try Task.checkCancellation()
            if container.bookmarkResolved {
                let _ = container.containerURL.startAccessingSecurityScopedResource()
            }

            let size = LCStorageScanner.size(of: container.containerURL)

            if container.bookmarkResolved {
                container.containerURL.stopAccessingSecurityScopedResource()
            }

            // A folder linked with the file picker is saved as "external" (bookmark) even when it is inside
            // LiveContainer's own folder: then it is a normal container and its space must count as such.
            let isExternal = LCStorageScanner.isExternal(container)
            if !isExternal {
                containersSize += size
            }
            containerDetails.append(
                LCAppStorageContainerItem(
                    id: UUID(),
                    name: container.name,
                    size: size,
                    isExternalContainer: isExternal
                )
            )
        }

        let bundleSize: Int64?
        if let bundlePath = input.appInfo.bundlePath() {
            bundleSize = LCStorageScanner.size(of: URL(fileURLWithPath: bundlePath))
        } else {
            bundleSize = nil
        }

        let totalSize: Int64
        if isBuiltInApp(input.appInfo) {
            // the built-in apps live inside LiveContainer's own bundle: only their data is theirs
            totalSize = containersSize
        } else {
            totalSize = (bundleSize ?? 0) + containersSize
        }

        return LCAppStorageItem(
            id: UUID(),
            appModel: input,
            bundleSize: bundleSize,
            containersSize: containersSize,
            totalSize: totalSize,
            containerDetails: containerDetails
        )
    }

    nonisolated private static func calculateAppItems(
        from inputs: [LCAppModel]
    ) async throws -> [LCAppStorageItem] {
        var appItems: [LCAppStorageItem] = []
        appItems.reserveCapacity(inputs.count)

        try await withThrowingTaskGroup(of: LCAppStorageItem.self) { group in
            for input in inputs {
                group.addTask(priority: .utility) {
                    try await calculateAppItem(
                        from: input
                    )
                }
            }

            for try await item in group {
                appItems.append(item)
            }
        }

        return appItems.sorted {
            if $0.totalSize == $1.totalSize {
                return ($0.appModel.displayName).localizedCaseInsensitiveCompare($1.appModel.displayName) == .orderedAscending
            }
            return $0.totalSize > $1.totalSize
        }
    }

    nonisolated private static func uniquePaths(_ urls: [URL]) -> [URL] {
        return LCStorageScanner.uniquePaths(urls)
    }
}

/// Synchronous helpers that walk the disk. They include hidden files (names starting with "."),
/// which the Files app never shows.
enum LCStorageScanner {
    /// Whole app group folder (the one that contains LCPath.lcGroupDocPath), when there is one.
    static var sharedRoot: URL? {
        let group = LCPath.lcGroupDocPath
        guard group.lcStorageKey != LCPath.docPath.lcStorageKey else {
            return nil
        }
        return group.deletingLastPathComponent()
    }

    /// Everything in the shared folder except LiveContainer's own part (already counted in the other categories).
    static func sharedRestSize() -> Int64 {
        guard let root = sharedRoot,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return 0
        }
        let ownKey = LCPath.lcGroupDocPath.lcStorageKey
        var total: Int64 = 0
        for name in names {
            let url = root.appendingPathComponent(name)
            if url.lcStorageKey == ownKey {
                continue
            }
            total += size(of: url)
        }
        return total
    }

    static var scanRoots: [URL] {
        var roots = [LCPath.docPath, sharedRoot ?? LCPath.lcGroupDocPath]
        if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            roots.append(library)
        }
        roots.append(FileManager.default.temporaryDirectory)
        return uniquePaths(roots)
    }

    /// True only for containers really outside LiveContainer (another app's folder, USB disk...).
    static func isExternal(_ container: LCContainer) -> Bool {
        guard container.storageBookMark != nil else {
            return false
        }
        return !isInsideLiveContainer(container.containerURL)
    }

    static func isInsideLiveContainer(_ url: URL) -> Bool {
        let path = url.lcStorageKey
        for root in uniquePaths([LCPath.docPath, LCPath.lcGroupDocPath]) {
            let rootPath = root.lcStorageKey
            if path == rootPath || path.hasPrefix(rootPath + "/") {
                return true
            }
        }
        return false
    }

    static func uniquePaths(_ urls: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        var uniqueURLs: [URL] = []
        for url in urls {
            guard seenPaths.insert(url.lcStorageKey).inserted else {
                continue
            }
            uniqueURLs.append(url)
        }
        return uniqueURLs
    }

    private static let sizeKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .fileSizeKey
    ]

    static func fileSize(_ values: URLResourceValues) -> Int64 {
        let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
        return Int64(size)
    }

    /// Size on disk of a file or of everything inside a folder (symbolic links aren't followed).
    static func size(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: sizeKeys) else {
            return 0
        }
        if values.isSymbolicLink == true {
            return 0
        }
        if values.isRegularFile == true {
            return fileSize(values)
        }
        guard values.isDirectory == true,
              let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: Array(sizeKeys),
                options: [],
                errorHandler: { _, _ in true }
              ) else {
            return 0
        }
        var totalSize: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            guard let values = try? fileURL.resourceValues(forKeys: sizeKeys), values.isRegularFile == true else {
                continue
            }
            totalSize += fileSize(values)
        }
        return totalSize
    }

    static func combinedSize(of urls: [URL]) -> Int64 {
        return uniquePaths(urls).reduce(Int64(0)) { $0 + size(of: $1) }
    }

    /// Walks every root once: collects hidden items (a hidden folder is measured whole and not entered)
    /// and the biggest files.
    static func deepScan(roots: [URL], limit: Int = 40) -> LCStorageDeepScanResult {
        var hidden: [LCStorageFoundItem] = []
        var largest: [LCStorageFoundItem] = []
        var largestFloor: Int64 = 0

        func addLargest(_ item: LCStorageFoundItem) {
            if largest.count >= limit && item.size <= largestFloor {
                return
            }
            let index = largest.firstIndex { $0.size < item.size } ?? largest.count
            largest.insert(item, at: index)
            if largest.count > limit {
                largest.removeLast()
            }
            largestFloor = largest.last?.size ?? 0
        }

        var seenRoots = Set<String>()
        for root in uniquePaths(roots) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(sizeKeys),
                options: [],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }
            while let url = enumerator.nextObject() as? URL {
                let path = url.lcStorageKey
                // the private folder can contain the group folder or vice versa: count each place once
                if seenRoots.contains(path) {
                    enumerator.skipDescendants()
                    continue
                }
                guard let values = try? url.resourceValues(forKeys: sizeKeys), values.isSymbolicLink != true else {
                    continue
                }
                let isDirectory = values.isDirectory == true
                if url.lastPathComponent.hasPrefix(".") {
                    let itemSize = isDirectory ? size(of: url) : fileSize(values)
                    if isDirectory {
                        enumerator.skipDescendants()
                    }
                    hidden.append(LCStorageFoundItem(url: url, size: itemSize, isDirectory: isDirectory, isHidden: true))
                    continue
                }
                if values.isRegularFile == true {
                    addLargest(LCStorageFoundItem(url: url, size: fileSize(values), isDirectory: false, isHidden: false))
                }
            }
            seenRoots.insert(root.lcStorageKey)
        }

        hidden.sort { $0.size > $1.size }
        return LCStorageDeepScanResult(
            hiddenItems: hidden,
            hiddenTotal: hidden.reduce(Int64(0)) { $0 + $1.size },
            hiddenCount: hidden.count,
            largestFiles: largest
        )
    }

    /// Lists a folder (hidden items included) with the size of each entry, biggest first.
    static func listEntries(at url: URL) throws -> [LCStorageFoundItem] {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: url.path)
        var entries: [LCStorageFoundItem] = []
        entries.reserveCapacity(names.count)
        for name in names {
            let child = url.appendingPathComponent(name)
            let values = try? child.resourceValues(forKeys: sizeKeys)
            let isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
            entries.append(LCStorageFoundItem(
                url: child,
                size: size(of: child),
                isDirectory: isDirectory,
                isHidden: name.hasPrefix(".")
            ))
        }
        return entries.sorted {
            if $0.size == $1.size {
                return $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
            }
            return $0.size > $1.size
        }
    }

    /// Path relative to the LiveContainer folder, easier to read than the full path.
    static func displayPath(_ url: URL) -> String {
        let path = url.lcStorageKey
        var places: [(URL, String)] = []
        places.append((LCPath.docPath, "LiveContainer"))
        places.append((LCPath.lcGroupDocPath, "Grupo de apps"))
        if let shared = sharedRoot {
            places.append((shared, "Carpeta compartida"))
        }
        places.append((FileManager.default.temporaryDirectory, "tmp de LiveContainer"))
        if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            places.append((library, "Library de LiveContainer"))
        }
        for (root, label) in places {
            let rootPath = root.lcStorageKey
            if path == rootPath {
                return label
            }
            if path.hasPrefix(rootPath + "/") {
                return label + "/" + String(path.dropFirst(rootPath.count + 1))
            }
        }
        return path
    }
}

extension URL {
    /// Path used to compare places: symbolic links resolved (/var vs /private/var) and normalized.
    var lcStorageKey: String {
        return self.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

//
//  LCStorageToolsView.swift
//  LiveContainer
//
//  Storage analyzer: explores the LiveContainer folder showing hidden items (the Files app hides
//  everything whose name starts with "."), empties the Files trash kept inside LiveContainer, and
//  finds containers that no app points to (renamed in Files, left behind...) to repair, link or delete them.
//

import SwiftUI

func lcFormatStorageSize(_ size: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
}

// MARK: - Names and protection of known folders

@MainActor
enum LCStorageLabels {
    struct Info {
        var labels: [String: String] = [:]
        var protected: [String: String] = [:]
    }

    static func key(_ url: URL) -> String {
        return url.lcStorageKey
    }

    static func build(_ sharedModel: SharedModel) -> Info {
        var info = Info()
        let fm = FileManager.default

        let structure: [URL] = [
            LCPath.docPath, LCPath.lcGroupDocPath,
            LCPath.bundlePath, LCPath.lcGroupBundlePath,
            LCPath.docPath.appendingPathComponent("Data"), LCPath.lcGroupDocPath.appendingPathComponent("Data"),
            LCPath.dataPath, LCPath.lcGroupDataPath,
            LCPath.appGroupPath, LCPath.lcGroupAppGroupPath,
            LCPath.tweakPath, LCPath.lcGroupTweakPath,
            fm.temporaryDirectory
        ] + (fm.urls(for: .libraryDirectory, in: .userDomainMask).first.map { [$0] } ?? [])
        for url in structure {
            info.protected[key(url)] = "Es una carpeta de la estructura de LiveContainer. Entra y borra lo que haya dentro."
        }

        info.labels[key(LCPath.bundlePath)] = "Apps instaladas"
        info.labels[key(LCPath.dataPath)] = "Contenedores de las apps"
        info.labels[key(LCPath.appGroupPath)] = "Grupos de apps"
        info.labels[key(LCPath.tweakPath)] = "Tweaks"

        let sideStore = LCPath.docPath.appendingPathComponent("SideStore")
        info.labels[key(sideStore)] = "Datos del SideStore integrado"
        info.protected[key(sideStore)] = "Son los datos del SideStore integrado (cuenta, certificados, apps)."
        let omniStation = LCPath.docPath.appendingPathComponent("OmniStation")
        info.labels[key(omniStation)] = "Datos del OmniStation integrado"
        info.protected[key(omniStation)] = "Son los datos del OmniStation integrado. Entra y borra lo que no quieras."

        for trash in [LCPath.docPath, LCPath.lcGroupDocPath] {
            info.labels[key(trash.appendingPathComponent(".Trash"))] = "«Eliminados recientemente» de Archivos"
        }

        let unlocked = sharedModel.isHiddenAppUnlocked
        for app in sharedModel.apps + sharedModel.hiddenApps {
            let visible = unlocked || !app.appInfo.isHidden
            let appName = visible ? app.displayName : "una app oculta"
            if let bundlePath = app.appInfo.bundlePath() {
                let url = URL(fileURLWithPath: bundlePath)
                if visible {
                    info.labels[key(url)] = "App: \(appName)"
                }
                info.protected[key(url)] = "Es la app \(appName). Desinstálala desde la lista de apps de LiveContainer."
            }
            for container in app.uiContainers where !LCStorageScanner.isExternal(container) {
                if visible {
                    info.labels[key(container.containerURL)] = "\(appName) · \(container.name)"
                }
                info.protected[key(container.containerURL)] = "Es un contenedor en uso de \(appName). Entra y borra lo que sobre, o bórralo desde los ajustes de la app."
            }
        }

        for name in sharedModel.appDataFolderNames where info.labels[key(LCPath.dataPath.appendingPathComponent(name))] == nil {
            let url = LCPath.dataPath.appendingPathComponent(name)
            if let plist = NSDictionary(contentsOf: url.appendingPathComponent("LCContainerInfo.plist")) as? [String: Any],
               info.protected[key(url)] == nil {
                let containerName = plist["name"] as? String ?? name
                info.labels[key(url)] = "Sin app · \(containerName)"
            }
        }
        return info
    }
}

// MARK: - Repair, link or delete containers no app points to

@MainActor
enum LCOrphanContainerFixer {
    static func ownerApps(for orphan: LCOrphanContainerItem, sharedModel: SharedModel) -> [LCAppModel] {
        guard let appIdentifier = orphan.appIdentifier else {
            return []
        }
        let candidates = sharedModel.isHiddenAppUnlocked ? sharedModel.apps + sharedModel.hiddenApps : sharedModel.apps
        return candidates.filter {
            !LCStorageManagementModel.isBuiltInApp($0.appInfo) && $0.appInfo.bundleIdentifier() == appIdentifier
        }
    }

    /// Containers of the app the orphan can take the place of (same kind of storage, not external).
    /// The one with the same name goes first: that's the one LiveContainer recreated empty after the rename.
    static func replaceCandidates(for orphan: LCOrphanContainerItem, in app: LCAppModel) -> [LCContainer] {
        let list = app.uiContainers.filter { $0.storageBookMark == nil && $0.isShared == orphan.isShared }
        guard let name = orphan.containerName else {
            return list
        }
        return list.filter { $0.name == name } + list.filter { $0.name != name }
    }

    private static func isReferenced(_ orphan: LCOrphanContainerItem, sharedModel: SharedModel) -> Bool {
        let path = orphan.url.lcStorageKey
        for app in sharedModel.apps + sharedModel.hiddenApps {
            for container in app.uiContainers where container.containerURL.lcStorageKey == path {
                return true
            }
        }
        return false
    }

    private static func freeKeychainGroup(preferred: [Int], used: Set<Int>) throws -> Int {
        for group in preferred where group >= 0 && group < SharedModel.keychainAccessGroupCount && !used.contains(group) {
            return group
        }
        var free = Set(0..<SharedModel.keychainAccessGroupCount)
        free.subtract(used)
        guard let group = free.randomElement() else {
            throw "lc.container.notEnoughKeychainGroup".loc
        }
        return group
    }

    /// The app goes back to using the orphan folder in place of `target` (the usual case: the folder was
    /// renamed in Files and LiveContainer made an empty one with the old name). The old folder is deleted
    /// only if it's practically empty; otherwise it's left as an unlinked container.
    /// Returns true if the old folder was deleted.
    @discardableResult
    static func replace(_ target: LCContainer, in app: LCAppModel, with orphan: LCOrphanContainerItem, sharedModel: SharedModel) throws -> Bool {
        guard !isReferenced(orphan, sharedModel: sharedModel) else {
            throw "Esta carpeta ya la usa una app."
        }
        guard let bundleId = app.appInfo.bundleIdentifier() else {
            throw "La app no tiene identificador."
        }
        let fm = FileManager.default
        let oldFolder = target.folderName
        let oldURL = target.containerURL
        let oldKeychainGroup = target.keychainGroupId
        let used = Set(app.uiContainers.filter { $0 !== target }.map { $0.keychainGroupId })
        let keychainGroup = try freeKeychainGroup(preferred: [orphan.keychainGroupId, oldKeychainGroup], used: used)

        target.folderName = orphan.folderName
        target.makeLCContainerInfoPlist(appIdentifier: bundleId, keychainGroupId: keychainGroup)
        if app.uiDefaultDataFolder == oldFolder {
            app.uiDefaultDataFolder = orphan.folderName
            app.appInfo.dataUUID = orphan.folderName
        }
        app.appInfo.containers = app.uiContainers
        app.objectWillChange.send()

        if !sharedModel.appDataFolderNames.contains(orphan.folderName) {
            sharedModel.appDataFolderNames.append(orphan.folderName)
        }

        var removedOld = false
        if fm.fileExists(atPath: oldURL.path) && LCStorageScanner.size(of: oldURL) < 1_000_000 {
            if (try? fm.removeItem(at: oldURL)) != nil {
                removedOld = true
                sharedModel.appDataFolderNames.removeAll { $0 == oldFolder }
            }
        }
        return removedOld
    }

    /// Adds the orphan to the app as one more container (with its name).
    static func attach(_ orphan: LCOrphanContainerItem, to app: LCAppModel, sharedModel: SharedModel) throws {
        guard !isReferenced(orphan, sharedModel: sharedModel) else {
            throw "Esta carpeta ya la usa una app."
        }
        guard let bundleId = app.appInfo.bundleIdentifier() else {
            throw "La app no tiene identificador."
        }
        guard orphan.isShared == app.appInfo.isShared else {
            throw "La carpeta y la app están en almacenamientos distintos (privado / grupo de apps). Mueve la app al mismo sitio primero."
        }
        guard app.uiContainers.count + 1 <= SharedModel.keychainAccessGroupCount else {
            throw "lc.container.tooMuchContainers".loc
        }
        let used = Set(app.uiContainers.map { $0.keychainGroupId })
        let keychainGroup = try freeKeychainGroup(preferred: [orphan.keychainGroupId], used: used)

        let container = LCContainer(folderName: orphan.folderName, name: orphan.containerName ?? orphan.folderName, isShared: orphan.isShared)
        container.makeLCContainerInfoPlist(appIdentifier: bundleId, keychainGroupId: keychainGroup)
        app.uiContainers.append(container)
        if app.uiSelectedContainer == nil {
            app.uiSelectedContainer = container
        }
        if app.uiDefaultDataFolder == nil {
            app.uiDefaultDataFolder = orphan.folderName
            app.appInfo.dataUUID = orphan.folderName
        }
        app.appInfo.containers = app.uiContainers
        app.objectWillChange.send()
        if !sharedModel.appDataFolderNames.contains(orphan.folderName) {
            sharedModel.appDataFolderNames.append(orphan.folderName)
        }
    }

    static func delete(_ orphan: LCOrphanContainerItem, sharedModel: SharedModel) throws {
        guard !isReferenced(orphan, sharedModel: sharedModel) else {
            throw "Esta carpeta la usa una app: no se borra."
        }
        try FileManager.default.removeItem(at: orphan.url)
        if !orphan.isShared {
            LCUtils.removeAppKeychain(dataUUID: orphan.folderName)
        }
        sharedModel.appDataFolderNames.removeAll { $0 == orphan.folderName }
    }
}

// MARK: - Folder explorer (shows hidden items)

struct LCStorageExplorerView: View {
    let url: URL
    let title: String
    var onChange: (() -> Void)? = nil

    @EnvironmentObject private var sharedModel: SharedModel
    @State private var entries: [LCStorageFoundItem] = []
    @State private var isLoading = false
    @State private var loaded = false
    @State private var info = LCStorageLabels.Info()

    @State private var pendingDelete: LCStorageFoundItem?
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var messageTitle = ""
    @State private var messageText = ""
    @State private var showMessage = false

    private var totalSize: Int64 {
        entries.reduce(Int64(0)) { $0 + $1.size }
    }

    private var hiddenSize: Int64 {
        entries.filter { $0.isHidden }.reduce(Int64(0)) { $0 + $1.size }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Total")
                    Spacer()
                    if isLoading || isDeleting {
                        ProgressView()
                    } else {
                        Text(lcFormatStorageSize(totalSize))
                            .foregroundStyle(.secondary)
                    }
                }
                if hiddenSize > 0 {
                    HStack {
                        Label("Oculto en Archivos", systemImage: "eye.slash")
                            .foregroundStyle(.orange)
                        Spacer()
                        Text(lcFormatStorageSize(hiddenSize))
                            .foregroundStyle(.orange)
                    }
                }
            } footer: {
                Text(LCStorageScanner.displayPath(url))
            }

            Section {
                if loaded && entries.isEmpty {
                    Text("Carpeta vacía")
                        .foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    row(entry)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                askDelete(entry)
                            } label: {
                                Label("lc.common.delete".loc, systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = entry.url.path
                            } label: {
                                Label("Copiar ruta", systemImage: "doc.on.doc")
                            }
                            Button(role: .destructive) {
                                askDelete(entry)
                            } label: {
                                Label("lc.common.delete".loc, systemImage: "trash")
                            }
                        }
                }
            } footer: {
                Text("Desliza a la izquierda o mantén pulsado para borrar. En naranja, lo que la app Archivos no enseña.")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !loaded {
                await load()
            }
        }
        .refreshable {
            await load()
        }
        .confirmationDialog(
            pendingDelete.map { "¿Borrar «\($0.url.lastPathComponent)» (\(lcFormatStorageSize($0.size)))?" } ?? "",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("lc.common.delete".loc, role: .destructive) {
                if let entry = pendingDelete {
                    Task { await delete(entry) }
                }
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("Se borra de verdad (no pasa por «Eliminados recientemente») y no se puede deshacer.")
        }
        .alert(messageTitle, isPresented: $showMessage) {
            Button("lc.common.ok".loc, role: .cancel) {}
        } message: {
            Text(messageText)
        }
    }

    @ViewBuilder
    private func row(_ entry: LCStorageFoundItem) -> some View {
        if entry.isDirectory {
            NavigationLink {
                LCStorageExplorerView(url: entry.url, title: entry.url.lastPathComponent, onChange: {
                    onChange?()
                    Task { await load() }
                })
            } label: {
                rowLabel(entry)
            }
        } else {
            rowLabel(entry)
        }
    }

    private func rowLabel(_ entry: LCStorageFoundItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isHidden ? Color.orange : (entry.isDirectory ? Color.blue : Color.secondary))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.url.lastPathComponent)
                    .foregroundStyle(entry.isHidden ? Color.orange : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let label = info.labels[LCStorageLabels.key(entry.url)] {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(lcFormatStorageSize(entry.size))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
        }
    }

    private func load() async {
        isLoading = true
        defer {
            isLoading = false
            loaded = true
        }
        info = LCStorageLabels.build(sharedModel)
        let folder = url
        do {
            entries = try await Task.detached(priority: .userInitiated) {
                try LCStorageScanner.listEntries(at: folder)
            }.value
        } catch {
            entries = []
            messageTitle = "lc.common.error".loc
            messageText = error.localizedDescription
            showMessage = true
        }
    }

    private func askDelete(_ entry: LCStorageFoundItem) {
        if let reason = info.protected[LCStorageLabels.key(entry.url)] {
            messageTitle = "No se puede borrar desde aquí"
            messageText = reason
            showMessage = true
            return
        }
        pendingDelete = entry
        showDeleteConfirm = true
    }

    private func delete(_ entry: LCStorageFoundItem) async {
        isDeleting = true
        defer {
            isDeleting = false
            pendingDelete = nil
        }
        let target = entry.url
        let error: String? = await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.removeItem(at: target)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let error {
            messageTitle = "lc.common.error".loc
            messageText = error
            showMessage = true
        } else {
            entries.removeAll { $0.id == entry.id }
            if target.deletingLastPathComponent().lcStorageKey == LCPath.dataPath.lcStorageKey {
                sharedModel.appDataFolderNames.removeAll { $0 == target.lastPathComponent }
            }
            onChange?()
        }
    }
}

// MARK: - Container with no app

struct LCOrphanContainerDetailView: View {
    let orphan: LCOrphanContainerItem
    var onChange: () -> Void

    @EnvironmentObject private var sharedModel: SharedModel
    @Environment(\.dismiss) private var dismiss

    @State private var owners: [LCAppModel] = []
    @State private var candidateSizes: [String: Int64] = [:]
    @State private var showDeleteConfirm = false
    @State private var messageTitle = ""
    @State private var messageText = ""
    @State private var showMessage = false
    @State private var closeAfterMessage = false

    var body: some View {
        Form {
            Section {
                infoRow("Carpeta", orphan.folderName)
                infoRow("Nombre del contenedor", orphan.containerName ?? "—")
                infoRow("App que lo creó", ownerDescription)
                infoRow("Almacenamiento", orphan.isShared ? "Grupo de apps" : "Privado")
                infoRow("Tamaño", lcFormatStorageSize(orphan.size))
                NavigationLink {
                    LCStorageExplorerView(url: orphan.url, title: orphan.containerName ?? orphan.folderName)
                } label: {
                    Label("Ver contenido", systemImage: "folder")
                }
            } footer: {
                Text("Ninguna app apunta a esta carpeta, así que antes contaba como «Otro». Suele pasar al renombrar la carpeta en Archivos: LiveContainer busca el nombre exacto de la carpeta, no lo encuentra y crea otra vacía. Para cambiar el nombre de un contenedor, hazlo dentro de LiveContainer (solo cambia el nombre que ves).")
            }

            ForEach(owners, id: \.self) { app in
                let candidates = LCOrphanContainerFixer.replaceCandidates(for: orphan, in: app)
                Section {
                    ForEach(candidates, id: \.self) { container in
                        Button {
                            replace(container, in: app)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Usar esta carpeta en lugar de «\(container.name)»")
                                Text("Ahora apunta a \(container.folderName) · \(candidateSizes[container.folderName].map(lcFormatStorageSize) ?? "…")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if orphan.isShared == app.appInfo.isShared {
                        Button {
                            attach(to: app)
                        } label: {
                            Text("Añadir como contenedor nuevo de \(app.displayName)")
                        }
                    }
                } header: {
                    Text(app.displayName)
                } footer: {
                    Text("Reparar: la app vuelve a usar esta carpeta con sus datos. La carpeta a la que apuntaba ahora solo se borra si está prácticamente vacía; si tiene datos, se queda como contenedor sin app para que decidas.")
                }
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Text("Borrar contenedor (\(lcFormatStorageSize(orphan.size)))")
                }
            }
        }
        .navigationTitle(orphan.containerName ?? orphan.folderName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            owners = LCOrphanContainerFixer.ownerApps(for: orphan, sharedModel: sharedModel)
            var urls: [String: URL] = [:]
            for app in owners {
                for container in LCOrphanContainerFixer.replaceCandidates(for: orphan, in: app) {
                    urls[container.folderName] = container.containerURL
                }
            }
            let toMeasure = urls
            let measured: [String: Int64] = await Task.detached(priority: .userInitiated) {
                var sizes: [String: Int64] = [:]
                for (name, url) in toMeasure {
                    sizes[name] = FileManager.default.fileExists(atPath: url.path) ? LCStorageScanner.size(of: url) : 0
                }
                return sizes
            }.value
            candidateSizes = measured
        }
        .confirmationDialog("¿Borrar este contenedor y todo lo que tiene?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("lc.common.delete".loc, role: .destructive) {
                delete()
            }
            Button("lc.common.cancel".loc, role: .cancel) {}
        } message: {
            Text("No se puede deshacer.")
        }
        .alert(messageTitle, isPresented: $showMessage) {
            Button("lc.common.ok".loc, role: .cancel) {
                if closeAfterMessage {
                    dismiss()
                }
            }
        } message: {
            Text(messageText)
        }
    }

    private var ownerDescription: String {
        guard let appIdentifier = orphan.appIdentifier else {
            return "Desconocida"
        }
        if let app = owners.first {
            return app.displayName
        }
        return "\(appIdentifier) (no instalada)"
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func finish(_ title: String, _ text: String) {
        messageTitle = title
        messageText = text
        closeAfterMessage = true
        showMessage = true
        onChange()
    }

    private func fail(_ error: Error) {
        messageTitle = "lc.common.error".loc
        messageText = error.localizedDescription
        closeAfterMessage = false
        showMessage = true
    }

    private func replace(_ container: LCContainer, in app: LCAppModel) {
        do {
            let removedOld = try LCOrphanContainerFixer.replace(container, in: app, with: orphan, sharedModel: sharedModel)
            finish("Reparado", "\(app.displayName) vuelve a usar sus datos en «\(container.name)»." + (removedOld ? " La carpeta vacía que había creado LiveContainer se ha borrado." : " La carpeta anterior tenía datos: queda como contenedor sin app."))
        } catch {
            fail(error)
        }
    }

    private func attach(to app: LCAppModel) {
        do {
            try LCOrphanContainerFixer.attach(orphan, to: app, sharedModel: sharedModel)
            finish("Añadido", "Ahora es un contenedor de \(app.displayName).")
        } catch {
            fail(error)
        }
    }

    private func delete() {
        do {
            try LCOrphanContainerFixer.delete(orphan, sharedModel: sharedModel)
            finish("Borrado", "Se han liberado \(lcFormatStorageSize(orphan.size)).")
        } catch {
            fail(error)
        }
    }
}

struct LCOrphanContainersSection: View {
    let breakdown: LCStorageBreakdown?
    var onChange: () -> Void

    var body: some View {
        if let breakdown, !breakdown.orphanContainers.isEmpty {
            Section {
                ForEach(breakdown.orphanContainers) { orphan in
                    NavigationLink {
                        LCOrphanContainerDetailView(orphan: orphan, onChange: onChange)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "shippingbox")
                                .foregroundStyle(.yellow)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(orphan.containerName ?? orphan.folderName)
                                    .lineLimit(1)
                                Text(orphan.appIdentifier ?? orphan.folderName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text(lcFormatStorageSize(orphan.size))
                                .foregroundStyle(.secondary)
                                .layoutPriority(1)
                        }
                    }
                }
            } header: {
                Text("Contenedores sin app")
            } footer: {
                Text("Carpetas de Data/Application a las que no apunta ninguna app (renombradas en Archivos, de apps borradas…). Entra para repararlas, vincularlas o borrarlas.")
            }
        }
    }
}

// MARK: - Tools and deep scan

struct LCStorageToolsSection: View {
    let breakdown: LCStorageBreakdown?
    @ObservedObject var model: LCStorageManagementModel
    var onChange: () -> Void

    @State private var showEmptyTrashConfirm = false
    @State private var isEmptying = false
    @State private var messageText = ""
    @State private var showMessage = false

    var body: some View {
        Section {
            NavigationLink {
                LCStorageExplorerView(url: LCPath.docPath, title: "LiveContainer", onChange: onChange)
            } label: {
                Label("Explorar la carpeta de LiveContainer", systemImage: "folder.badge.gearshape")
            }
            if LCPath.lcGroupDocPath.lcStorageKey != LCPath.docPath.lcStorageKey {
                NavigationLink {
                    LCStorageExplorerView(url: LCPath.lcGroupDocPath, title: "Grupo de apps", onChange: onChange)
                } label: {
                    Label("Explorar el grupo de apps", systemImage: "folder.badge.person.crop")
                }
            }
            if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
                NavigationLink {
                    LCStorageExplorerView(url: library, title: "Library", onChange: onChange)
                } label: {
                    Label("Explorar los datos internos (Library)", systemImage: "folder")
                }
            }
            NavigationLink {
                LCStorageExplorerView(url: FileManager.default.temporaryDirectory, title: "tmp", onChange: onChange)
            } label: {
                Label("Explorar los archivos temporales", systemImage: "clock.arrow.circlepath")
            }

            if let breakdown, breakdown.filesTrashSize > 0 {
                Button(role: .destructive) {
                    showEmptyTrashConfirm = true
                } label: {
                    HStack {
                        Label("Vaciar «Eliminados recientemente»", systemImage: "trash")
                        Spacer()
                        if isEmptying {
                            ProgressView()
                        } else {
                            Text(lcFormatStorageSize(breakdown.filesTrashSize))
                        }
                    }
                }
                .disabled(isEmptying)
            }

            Button {
                Task { await model.runDeepScan() }
            } label: {
                HStack {
                    Label("Buscar ocultos y archivos grandes", systemImage: "magnifyingglass")
                    Spacer()
                    if model.isDeepScanning {
                        ProgressView()
                    }
                }
            }
            .disabled(model.isDeepScanning)
        } header: {
            Text("Analizar y limpiar")
        } footer: {
            Text("Lo que borras en Archivos dentro de LiveContainer no se libera: va a «Eliminados recientemente», que está guardado dentro de la propia carpeta de LiveContainer (.Trash) durante 30 días.")
        }
        .confirmationDialog("¿Vaciar «Eliminados recientemente» de LiveContainer?", isPresented: $showEmptyTrashConfirm, titleVisibility: .visible) {
            Button("Vaciar", role: .destructive) {
                Task { await emptyTrash() }
            }
            Button("lc.common.cancel".loc, role: .cancel) {}
        } message: {
            Text("Lo borrado desde Archivos dentro de LiveContainer ya no se podrá recuperar.")
        }
        .alert("Eliminados recientemente", isPresented: $showMessage) {
            Button("lc.common.ok".loc, role: .cancel) {}
        } message: {
            Text(messageText)
        }

        if let scan = model.deepScan {
            Section {
                let shownHidden = scan.hiddenItems.filter { $0.size >= 1_000_000 }.prefix(40)
                if shownHidden.isEmpty {
                    Text("Nada oculto de más de 1 MB")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(shownHidden)) { item in
                    foundRow(item)
                }
            } header: {
                Text("Ocultos: \(lcFormatStorageSize(scan.hiddenTotal)) en \(scan.hiddenCount) elementos")
            } footer: {
                Text("Todo lo que empieza por punto, también dentro de los contenedores. Archivos no lo enseña.")
            }

            Section {
                ForEach(scan.largestFiles) { item in
                    foundRow(item)
                }
            } header: {
                Text("Archivos más grandes")
            }
        }
    }

    @ViewBuilder
    private func foundRow(_ item: LCStorageFoundItem) -> some View {
        let parent = item.url.deletingLastPathComponent()
        NavigationLink {
            LCStorageExplorerView(url: item.isDirectory ? item.url : parent, title: item.isDirectory ? item.url.lastPathComponent : parent.lastPathComponent, onChange: onChange)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.url.lastPathComponent)
                        .foregroundStyle(item.isHidden ? Color.orange : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(LCStorageScanner.displayPath(parent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(lcFormatStorageSize(item.size))
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
            }
        }
    }

    private func emptyTrash() async {
        isEmptying = true
        defer { isEmptying = false }
        let roots = LCStorageScanner.uniquePaths([LCPath.docPath, LCPath.lcGroupDocPath])
        let failures: [String] = await Task.detached(priority: .userInitiated) {
            var errors: [String] = []
            let fm = FileManager.default
            for root in roots {
                let trash = root.appendingPathComponent(".Trash")
                guard let items = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) else {
                    continue
                }
                for item in items {
                    do {
                        try fm.removeItem(at: item)
                    } catch {
                        errors.append(item.lastPathComponent + ": " + error.localizedDescription)
                    }
                }
            }
            return errors
        }.value
        messageText = failures.isEmpty ? "Vaciado." : failures.joined(separator: "\n")
        showMessage = true
        onChange()
    }
}

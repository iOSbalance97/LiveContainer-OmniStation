import Foundation
import SwiftUI

struct LCStorageManagementView: View {
    @EnvironmentObject private var sharedModel: SharedModel
    @StateObject private var model = LCStorageManagementModel()
    @State private var refreshed: Bool = false
    @State private var needsRefresh: Bool = false

    var body: some View {
        Form {
            LCStorageSummarySection(
                breakdown: model.breakdown,
                isCalculating: model.isCalculating,
                errorInfo: model.errorInfo
            )
            LCStorageToolsSection(breakdown: model.breakdown, model: model, onChange: markChanged)
            LCOrphanContainersSection(breakdown: model.breakdown, onChange: markChanged)
            LCInstalledAppsSection(breakdown: model.breakdown)
        }
        .navigationTitle("lc.settings.storageManagement".loc)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isCalculating)
            }
        }
        .refreshable {
            await refresh()
        }
        .task {
            if !refreshed {
                await refresh()
                refreshed = true
            }
        }
        .onAppear {
            // something was deleted or repaired in a pushed screen: recalculate when coming back
            if needsRefresh {
                needsRefresh = false
                Task { await refresh() }
            }
        }
    }

    private func markChanged() {
        needsRefresh = true
    }

    private func refresh() async {
        await model.refresh(apps: sharedModel.apps, hiddenApps: sharedModel.hiddenApps)
    }
}

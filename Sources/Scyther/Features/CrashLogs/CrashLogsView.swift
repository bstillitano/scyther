//
//  CrashLogsView.swift
//  Scyther
//
//  Created by Brandon Stillitano on 22/12/2024.
//

#if !os(macOS)
import SwiftUI

/// A view displaying captured crash logs from the application.
///
/// `CrashLogsView` presents a searchable list of all crashes captured by
/// ``CrashLogger``. Each crash can be tapped to view detailed information
/// including the full stack trace.
///
/// ## Features
/// - Searchable list filtered by exception name or reason
/// - Navigation to detailed crash view with ``CrashDetailsView``
/// - Export of the crashes shown, search applied, via ``CrashExportSheet``
/// - Clear all functionality to remove stored crashes
/// - Test crash button in debug builds
/// - Real-time updates when new crashes are recorded
///
/// ## Usage
/// ```swift
/// NavigationStack {
///     CrashLogsView()
/// }
/// ```
///
/// The view automatically updates when crashes are recorded via
/// ``CrashLogger/didRecordCrashNotification``.
///
/// ## Topics
///
/// ### Related Types
/// - ``CrashLogsViewModel``
/// - ``CrashDetailsView``
/// - ``CrashLogEntry``
struct CrashLogsView: View {
    @StateObject private var viewModel = CrashLogsViewModel()
    @State private var searchText = ""

    /// The export sheet's view model while the sheet is open.
    @State private var exportViewModel: CrashExportViewModel?

    private var filteredCrashes: [CrashLogEntry] {
        if searchText.isEmpty {
            return viewModel.crashes
        }
        return viewModel.crashes.filter { crash in
            crash.name.localizedCaseInsensitiveContains(searchText) ||
            (crash.reason?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        Group {
            if viewModel.crashes.isEmpty {
                emptyState
            } else {
                crashList
            }
        }
        .navigationTitle(localized("Crash Logs"))
        .searchable(text: $searchText, prompt: localized("Search crashes"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !viewModel.crashes.isEmpty {
                    Button {
                        exportViewModel = CrashExportViewModel(crashes: filteredCrashes)
                    } label: {
                        Label(localized("Export"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(filteredCrashes.isEmpty)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if !viewModel.crashes.isEmpty {
                    Button(localized("Clear All"), role: .destructive) {
                        viewModel.clearAll()
                    }
                }
            }
            #if DEBUG
            ToolbarItem(placement: .secondaryAction) {
                Button(localized("Test Crash")) {
                    viewModel.triggerTestCrash()
                }
            }
            #endif
        }
        .sheet(item: $exportViewModel) { exportViewModel in
            CrashExportSheet(viewModel: exportViewModel)
        }
        .onFirstAppear {
            await viewModel.onFirstAppear()
        }
        .onReceive(NotificationCenter.default.publisher(for: CrashLogger.didRecordCrashNotification)) { _ in
            Task {
                await viewModel.refresh()
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView(
                localized("No Crashes"),
                systemImage: "checkmark.circle",
                description: Text(localized("No crashes have been recorded. That's a good thing!"))
            )
        } else {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(localized("No Crashes"))
                    .font(.headline)
                Text(localized("No crashes have been recorded. That's a good thing!"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }

    private var crashList: some View {
        List {
            ForEach(filteredCrashes) { crash in
                NavigationLink {
                    CrashDetailsView(crash: crash)
                } label: {
                    CrashRowView(crash: crash)
                }
            }
        }
    }
}

/// Row view for a single crash entry in the crash logs list.
///
/// Displays a summary of the crash including the exception name,
/// reason (if available), timestamp, and app version.
private struct CrashRowView: View {
    /// The crash log entry to display.
    let crash: CrashLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(crash.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let reason = crash.reason {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Text(crash.formattedTimestamp)
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()

                Text(verbatim: "v\(crash.appVersion)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        CrashLogsView()
    }
}
#endif

//
//  CrashExportSheet.swift
//  Scyther
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
import SwiftUI

/// A full-height sheet that builds a crash archive and shares it after a warning.
///
/// Opened from ``CrashDetailsView`` for one crash, or from ``CrashLogsView`` for every crash.
/// Shows a progress indicator while ``CrashExportViewModel`` writes the zip, then the archive
/// name, crash count, contents, a redaction toggle that rebuilds the archive in place, and a red
/// Export button. Export shows the sensitivity alert; confirming it opens the system share sheet.
/// It is laid out as ``NetworkLogExportSheet`` is, so the two exports read the same. The archive
/// is deleted when the sheet is dismissed.
struct CrashExportSheet: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel: CrashExportViewModel

    /// Whether the sensitivity alert is presented.
    @State private var showingWarning: Bool = false

    /// Whether the system share sheet is presented.
    @State private var showingShareSheet: Bool = false

    /// Creates the export sheet.
    ///
    /// - Parameter viewModel: The view model that builds and owns the archive.
    init(viewModel: CrashExportViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            List {
                archiveSection
                contentsSection
                if viewModel.includesSessionLogs {
                    redactionSection
                }
                exportSection
            }
            .navigationTitle(localized("Export Crash Report"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton { dismiss() }
                }
            }
            .alert(localized("Export Sensitive Data?"), isPresented: $showingWarning) {
                Button(localized("Cancel"), role: .cancel) {}
                Button(localized("Export"), role: .destructive) {
                    showingShareSheet = true
                }
            } message: {
                Text(warningMessage)
            }
            .sheet(isPresented: $showingShareSheet) {
                if let url = viewModel.archiveURL {
                    ActivityShareSheet(items: [url])
                        .presentationDetents([.medium, .large])
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onFirstAppear {
            await viewModel.onFirstAppear()
        }
        .onDisappear {
            viewModel.cleanup()
        }
    }

    private var warningMessage: String {
        var message = localized("The archive contains stack traces and device details. Handle and share it with care.")
        guard viewModel.includesSessionLogs else { return message }
        message = localized("The archive contains the console output and network traffic of the sessions these crashes happened in, including headers, cookies, authentication tokens, and request and response bodies. This data may be extremely sensitive. Handle and share it with extreme care.")
        guard viewModel.redactSensitiveValues else { return message }
        return message + " " + localized("Redaction is on, but it is best effort and not a guarantee of privacy.")
    }

    @ViewBuilder
    private var archiveSection: some View {
        switch viewModel.state {
        case .preparing:
            Section(localized("Archive")) {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(localized("Preparing archive of \(viewModel.crashCount) crashes…"))
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            }
        case .ready(let url):
            Section(localized("Archive")) {
                // The spinner stays mounted and only changes opacity, so the row never re-lays
                // out when a rebuild starts or ends.
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localized("File"))
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ProgressView()
                        .opacity(viewModel.isRebuilding ? 1 : 0)
                }
                LabeledContent(localized("Crashes"), value: "\(viewModel.crashCount)")
            }
        case .failed(let message):
            Section(localized("Archive")) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }

    private var contentsSection: some View {
        Section {
            Label(localized("Crash report with symbolication commands"), systemImage: "doc.text")
            Label(localized("IPS file for Xcode and Console"), systemImage: "ladybug")
            if viewModel.includesDiagnostics {
                Label(localized("Raw MetricKit diagnostic"), systemImage: "curlybraces")
            }
            if viewModel.includesSessionLogs {
                Label(localized("Console output of the crashed session"), systemImage: "terminal")
                Label(localized("Network requests of the crashed session"), systemImage: "network")
            }
        } header: {
            Text(localized("Contents"))
        } footer: {
            Text(localized("One folder per crash. A README in the archive explains each file and how to symbolicate it."))
        }
    }

    private var redactionSection: some View {
        Section {
            Toggle(
                localized("Redact sensitive values"),
                isOn: Binding(
                    get: { viewModel.redactSensitiveValues },
                    set: { viewModel.setRedaction($0) }
                )
            )
        } header: {
            Text(localized("Redaction"))
        } footer: {
            Text(localized("Replaces common tokens, cookies, passwords, and API keys in the console output and network traffic with REDACTED. This is an attempt, not a guarantee of privacy."))
        }
    }

    private var exportSection: some View {
        Section {
            Button(role: .destructive) {
                showingWarning = true
            } label: {
                Text(localized("Export"))
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
            .disabled(viewModel.archiveURL == nil || viewModel.isRebuilding)
            .listRowBackground(Color.clear)
            .listRowInsets(.init())
        }
    }
}
#endif

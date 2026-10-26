//
//  CrashDetailsView.swift
//  Scyther
//
//  Created by Brandon Stillitano on 22/12/2024.
//

#if !os(macOS)
import SwiftUI

/// A detailed view for a single crash log entry.
///
/// `CrashDetailsView` displays comprehensive information about a captured crash,
/// including exception details, environment information, and the full stack trace.
///
/// ## Features
/// - Exception name and reason display
/// - Where the crash was captured: the exception handler, or MetricKit on a later launch
/// - Device and app environment details
/// - Searchable stack trace with text highlighting
/// - Copy to clipboard functionality
/// - The full report, every thread and binary image included
/// - Export to a zip archive via ``CrashExportSheet``
///
/// ## Usage
/// ```swift
/// NavigationLink {
///     CrashDetailsView(crash: crashEntry)
/// } label: {
///     Text(crashEntry.name)
/// }
/// ```
///
/// ## Topics
///
/// ### Related Types
/// - ``CrashDetailsViewModel``
/// - ``CrashLogEntry``
/// - ``CrashLogsView``
struct CrashDetailsView: View {
    /// The view model managing state and logic for this view.
    @StateObject private var viewModel: CrashDetailsViewModel

    /// The export sheet's view model while the sheet is open.
    @State private var exportViewModel: CrashExportViewModel?

    /// Creates a new crash details view.
    ///
    /// - Parameter crash: The crash log entry to display.
    init(crash: CrashLogEntry) {
        _viewModel = StateObject(wrappedValue: CrashDetailsViewModel(crash: crash))
    }

    var body: some View {
        List {
            Section(localized("Exception")) {
                LabeledContent(localized("Name"), value: viewModel.crash.name)
                LabeledContent(localized("Source"), value: viewModel.crash.source.displayName)
                if let codes = viewModel.exceptionCodes {
                    LabeledContent(localized("Exception Codes"), value: codes)
                }
                if let reason = viewModel.crash.reason {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(localized("Reason"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(reason)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }
            }

            Section(localized("Timestamp")) {
                LabeledContent(localized("Date"), value: viewModel.crash.formattedTimestamp)
            }

            if let region = viewModel.details?.virtualMemoryRegionInfo {
                Section(localized("Memory Region")) {
                    Text(region)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Section(localized("Environment")) {
                LabeledContent(localized("App Version"), value: viewModel.crash.appVersion)
                LabeledContent(localized("Build Number"), value: viewModel.crash.buildNumber)
                LabeledContent(localized("OS Version"), value: viewModel.crash.osVersion)
                LabeledContent(localized("Device"), value: viewModel.crash.deviceModel)
            }

            Section {
                NavigationLink {
                    TextReaderView(text: viewModel.fullReport, title: localized("Full Report"))
                } label: {
                    LabeledContent(localized("Full Report"), value: localized("\(viewModel.threadCount) threads"))
                }
            } footer: {
                Text(localized("Every thread and binary image, in the layout of Apple's crash reports."))
            }

            Section {
                if viewModel.crash.stackTrace.isEmpty {
                    Text(localized("No stack trace available"))
                        .foregroundStyle(.secondary)
                        .italic()
                } else if viewModel.filteredStackTrace.isEmpty {
                    Text(localized("No matching frames"))
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    ForEach(viewModel.filteredStackTrace, id: \.index) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(entry.index)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            HighlightedText(
                                text: entry.symbol,
                                highlight: viewModel.searchText
                            )
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                HStack {
                    Text(localized("Stack Trace"))
                    Spacer()
                    if !viewModel.crash.stackTrace.isEmpty && !viewModel.searchText.isEmpty {
                        Text(localized("\(viewModel.filteredStackTrace.count) of \(viewModel.crash.stackTrace.count)"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(localized("Crash Details"))
        .sheet(item: $exportViewModel) { exportViewModel in
            CrashExportSheet(viewModel: exportViewModel)
        }
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText, prompt: localized("Search stack trace"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    viewModel.copyToClipboard()
                } label: {
                    Label(viewModel.copied ? localized("Copied") : localized("Copy"), systemImage: viewModel.copied ? "checkmark" : "doc.on.doc")
                }

                Button {
                    exportViewModel = viewModel.makeExportViewModel()
                } label: {
                    Label(localized("Export"), systemImage: "square.and.arrow.up")
                }
            }
        }
    }
}

/// A text view that highlights occurrences of a search term.
private struct HighlightedText: View {
    /// The full text to display.
    let text: String

    /// The term to highlight within the text.
    let highlight: String

    var body: some View {
        Text(attributedString)
    }

    /// Builds an attributed string with highlighted matches.
    private var attributedString: AttributedString {
        var attributedString = AttributedString(text)

        guard !highlight.isEmpty else {
            return attributedString
        }

        var searchStart = attributedString.startIndex
        while let range = attributedString[searchStart...].range(
            of: highlight,
            options: .caseInsensitive
        ) {
            attributedString[range].backgroundColor = .yellow.opacity(0.4)
            attributedString[range].foregroundColor = .primary
            searchStart = range.upperBound
        }

        return attributedString
    }
}

#Preview {
    NavigationStack {
        CrashDetailsView(crash: CrashLogEntry(
            id: UUID(),
            timestamp: Date(),
            name: "NSInvalidArgumentException",
            reason: "Attempted to insert nil object into array",
            stackTrace: [
                "0   CoreFoundation  0x00000001a1234567 __exceptionPreprocess + 220",
                "1   libobjc.A.dylib 0x00000001a0987654 objc_exception_throw + 60",
                "2   CoreFoundation  0x00000001a1345678 -[__NSArrayM insertObject:atIndex:] + 1084",
                "3   MyApp           0x0000000104567890 -[ViewController viewDidLoad] + 156",
                "4   UIKitCore       0x00000001a2345678 -[UIViewController _sendViewDidLoadWithAppearanceProxyObjectTaggingEnabled] + 100"
            ],
            appVersion: "1.0.0",
            buildNumber: "42",
            osVersion: "17.0",
            deviceModel: "iPhone"
        ))
    }
}
#endif

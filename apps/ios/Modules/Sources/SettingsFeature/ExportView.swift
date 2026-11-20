import SrokaCore
import SrokaDesign
import SwiftUI
import UniformTypeIdentifiers

/// Export as CSV or JSON, then share or save (Android `ExportScreen`).
struct ExportView: View {
    @State var model: ExportViewModel

    init(model: ExportViewModel = ExportViewModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Button {
                        model.formatSelected(format)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(format.title)
                                    .foregroundStyle(SrokaColor.onSurface)
                                Text(format.subtitle)
                                    .font(.footnote)
                                    .foregroundStyle(SrokaColor.onSurfaceVariant)
                            }
                            Spacer()
                            if model.format == format {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(SrokaColor.brand)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .accessibilityAddTraits(model.format == format ? .isSelected : [])
                    .disabled(model.isExporting)
                }
            } header: {
                Text("Format", bundle: #bundle)
            }
            .listRowBackground(SrokaColor.surfaceLowest)
            Section {
                if let message = model.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(SrokaColor.error)
                        .accessibilityIdentifier("export.error")
                }
                if let ready = model.ready {
                    ReadyRows(model: model, ready: ready)
                } else {
                    Button {
                        Task { await model.exportTapped() }
                    } label: {
                        HStack {
                            Spacer()
                            if model.isExporting {
                                ProgressView()
                                Text("Building export…", bundle: #bundle)
                            } else {
                                Text("Export", bundle: #bundle)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SrokaColor.brand)
                    .controlSize(.large)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .disabled(model.isExporting)
                    .accessibilityIdentifier("export.button")
                }
            }
            .listRowBackground(SrokaColor.surfaceLowest)
        }
        .scrollContentBackground(.hidden)
        .background(SrokaColor.background)
        .tint(SrokaColor.brand)
        .navigationTitle(Text("Export", bundle: #bundle))
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $model.isSavingFile,
            document: model.ready.map { ExportDocument(fileURL: $0.fileURL) },
            contentType: model.format == .csv ? .commaSeparatedText : .json,
            defaultFilename: model.ready?.fileName
        ) { result in
            model.fileSaved(result)
        }
    }
}

private struct ReadyRows: View {
    let model: ExportViewModel
    let ready: ReadyExport

    var body: some View {
        Label {
            Text("Ready · \(ready.bytes.formatted(.byteCount(style: .file)))", bundle: #bundle)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(SrokaColor.brand)
        }
        .accessibilityIdentifier("export.ready")
        ShareLink(item: ready.fileURL) {
            Label {
                Text("Share", bundle: #bundle)
            } icon: {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .accessibilityIdentifier("export.share")
        Button {
            model.saveTapped()
        } label: {
            Label {
                Text("Save", bundle: #bundle)
            } icon: {
                Image(systemName: "folder")
            }
        }
        .accessibilityIdentifier("export.save")
        if let message = model.saveMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(SrokaColor.onSurfaceVariant)
        }
    }
}

/// Wraps the built export file for the system "save to Files" sheet.
struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText, .json]
    let fileURL: URL?

    init(fileURL: URL) { self.fileURL = fileURL }

    init(configuration: ReadConfiguration) throws { fileURL = nil }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
        return try FileWrapper(url: fileURL, options: .immediate)
    }
}

extension ExportFormat {
    var title: LocalizedStringResource {
        switch self {
        case .csv: LocalizedStringResource("CSV", bundle: #bundle)
        case .json: LocalizedStringResource("JSON", bundle: #bundle)
        }
    }

    var subtitle: LocalizedStringResource {
        switch self {
        case .csv: LocalizedStringResource("Links, tags and dates in a spreadsheet", bundle: #bundle)
        case .json: LocalizedStringResource("Everything Sroka knows about each link", bundle: #bundle)
        }
    }
}

import SrokaCore
import SrokaDesign
import SwiftUI

/// Import from Pocket, Instapaper or browser bookmarks (Android `ImportScreen`).
struct ImportView: View {
    @State var model: ImportViewModel

    init(model: ImportViewModel = ImportViewModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
            } header: {
                Text(
                    "Bring links over from another app. The server fetches each article, and they appear in My List as they’re ready.",
                    bundle: #bundle
                )
                .font(.subheadline)
                .textCase(nil)
            }
            if let job = model.job {
                JobSection(model: model, job: job)
            } else {
                SourceSection(model: model)
                FileSection(model: model)
            }
        }
        .scrollContentBackground(.hidden)
        .background(SrokaColor.background)
        .tint(SrokaColor.brand)
        .navigationTitle(Text("Import", bundle: #bundle))
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $model.isPickingFile,
            allowedContentTypes: ImportViewModel.allowedContentTypes(for: model.source)
        ) { result in
            model.fileImported(result)
        }
        .task { await model.task() }
    }
}

private struct SourceSection: View {
    let model: ImportViewModel

    var body: some View {
        Section {
            ForEach(ImportSource.allCases, id: \.self) { source in
                Button {
                    model.sourceSelected(source)
                } label: {
                    HStack {
                        Text(source.title)
                            .foregroundStyle(SrokaColor.onSurface)
                        Spacer()
                        if model.source == source {
                            Image(systemName: "checkmark")
                                .foregroundStyle(SrokaColor.brand)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityAddTraits(model.source == source ? .isSelected : [])
                .disabled(!model.canChangeSource)
            }
        } header: {
            Text("Source", bundle: #bundle)
        }
        .listRowBackground(SrokaColor.surfaceLowest)
    }
}

private struct FileSection: View {
    let model: ImportViewModel

    var body: some View {
        Section {
            Button {
                model.chooseFileTapped()
            } label: {
                Label {
                    if let name = model.fileName {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).lineLimit(1).truncationMode(.middle)
                            if let size = model.fileSizeBytes {
                                Text(size.formatted(.byteCount(style: .file)))
                                    .font(.footnote)
                                    .foregroundStyle(SrokaColor.onSurfaceVariant)
                            }
                        }
                    } else {
                        Text("Choose file", bundle: #bundle)
                    }
                } icon: {
                    Image(systemName: "doc")
                }
            }
            .disabled(!model.canChangeSource)
            .accessibilityIdentifier("import.chooseFile")
            if let message = model.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(SrokaColor.error)
                    .accessibilityIdentifier("import.error")
            }
            Button {
                Task { await model.importTapped() }
            } label: {
                HStack {
                    Spacer()
                    if model.isUploading {
                        ProgressView()
                        Text("Uploading…", bundle: #bundle)
                    } else {
                        Text("Import", bundle: #bundle)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(SrokaColor.brand)
            .controlSize(.large)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .disabled(!model.canImport)
            .accessibilityIdentifier("import.button")
        }
        .listRowBackground(SrokaColor.surfaceLowest)
    }
}

private struct JobSection: View {
    let model: ImportViewModel
    let job: ImportJob

    var body: some View {
        Section {
            switch job.status {
            case .queued, .running: running
            case .done: finished
            case .failed: failed
            }
        }
        .listRowBackground(SrokaColor.surfaceLowest)
    }

    @ViewBuilder private var running: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Importing…", bundle: #bundle)
                .font(.headline)
            if let total = job.total, total > 0 {
                ProgressView(value: Double(min(job.done, total)), total: Double(total))
                    .tint(SrokaColor.progress)
                Text("\(job.done.formatted()) of \(total.formatted())", bundle: #bundle)
                    .font(.footnote)
                    .foregroundStyle(SrokaColor.onSurfaceVariant)
            } else {
                ProgressView().progressViewStyle(.linear).tint(SrokaColor.progress)
                Text("\(job.done.formatted()) done", bundle: #bundle)
                    .font(.footnote)
                    .foregroundStyle(SrokaColor.onSurfaceVariant)
            }
            Text("You can leave this screen. Progress continues in the background.", bundle: #bundle)
                .font(.footnote)
                .foregroundStyle(SrokaColor.onSurfaceVariant)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("import.progress")
        if model.isJobStale {
            Button {
                Task { await model.doneTapped() }
            } label: {
                Text("Dismiss", bundle: #bundle)
            }
            .accessibilityIdentifier("import.dismiss")
        }
    }

    @ViewBuilder private var finished: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                if model.importedCount == 1 {
                    Text("Imported 1 link", bundle: #bundle)
                } else {
                    Text("Imported \(model.importedCount.formatted()) links", bundle: #bundle)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(SrokaColor.brand)
            }
            .font(.headline)
            if job.skipped == 1 {
                Text("1 skipped because it had no usable web address", bundle: #bundle)
                    .font(.footnote)
                    .foregroundStyle(SrokaColor.onSurfaceVariant)
            } else if job.skipped > 1 {
                Text(
                    "\(job.skipped.formatted()) skipped because they had no usable web address",
                    bundle: #bundle
                )
                .font(.footnote)
                .foregroundStyle(SrokaColor.onSurfaceVariant)
            }
        }
        .accessibilityIdentifier("import.result")
        doneButton
    }

    @ViewBuilder private var failed: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Import failed", bundle: #bundle)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SrokaColor.error)
            }
            .font(.headline)
            Text(ImportViewModel.jobMessage(for: job.error))
                .font(.footnote)
                .foregroundStyle(SrokaColor.onSurfaceVariant)
        }
        .accessibilityIdentifier("import.failure")
        doneButton
    }

    private var doneButton: some View {
        Button {
            Task { await model.doneTapped() }
        } label: {
            Text("Done", bundle: #bundle)
        }
        .accessibilityIdentifier("import.done")
    }
}

extension ImportSource {
    var title: LocalizedStringResource {
        switch self {
        case .pocket: LocalizedStringResource("Pocket", bundle: #bundle)
        case .instapaper: LocalizedStringResource("Instapaper", bundle: #bundle)
        case .browser: LocalizedStringResource("Browser bookmarks (HTML)", bundle: #bundle)
        }
    }
}

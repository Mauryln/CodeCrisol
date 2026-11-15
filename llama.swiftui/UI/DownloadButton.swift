import SwiftUI

struct DownloadButton: View {
    @ObservedObject var state: LlamaState
    let model: Model
    let downloaded: Bool
    @State private var confirmDelete = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Label(model.name, systemImage: downloaded ? "doc.fill" : "arrow.down.circle")
                    .font(.subheadline)
                if let source = model.source {
                    Text(source).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if downloaded {
                if state.isLoaded(model) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Cargado")
                } else {
                    Button("Cargar") { state.loadModel(model) }
                        .disabled(state.busy || state.loadingModel != nil)
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Eliminar \(model.name)")
                    .disabled(state.loadingModel != nil)
                }
            } else if let url = URL(string: model.url) {
                Button("Descargar") { state.download(url, filename: model.filename) }
                    .disabled(state.transfer != nil)
            }
        }
        .buttonStyle(.bordered)
        .padding(.vertical, 4)
        .confirmationDialog("¿Eliminar \(model.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Eliminar archivo", role: .destructive) { state.removeModel(model) }
        }
    }
}

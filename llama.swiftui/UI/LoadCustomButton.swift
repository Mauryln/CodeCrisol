import SwiftUI
import UniformTypeIdentifiers

struct LoadCustomButton: View {
    @ObservedObject var llamaState: LlamaState
    @State private var showFileImporter = false

    var body: some View {
        Button { showFileImporter = true } label: { Label("Importar GGUF", systemImage: "folder") }
            .disabled(llamaState.transfer != nil)
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data]) { result in
                switch result {
                case .success(let url):
                    llamaState.importModel(url)
                case .failure(let error):
                    llamaState.report("No se pudo abrir el archivo: \(error.localizedDescription)")
                }
            }
    }
}

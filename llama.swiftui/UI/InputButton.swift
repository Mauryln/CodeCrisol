import SwiftUI

struct InputButton: View {
    @ObservedObject var llamaState: LlamaState
    @State private var showInput = false
    @State private var link = ""

    var body: some View {
        Button { showInput = true } label: { Label("Descargar por enlace", systemImage: "link") }
            .disabled(llamaState.transfer != nil)
            .alert("Enlace directo al GGUF", isPresented: $showInput) {
                TextField("https://…/modelo.gguf", text: $link)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancelar", role: .cancel) {}
                Button("Descargar") {
                    guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        llamaState.report("El enlace al modelo no es válido.")
                        return
                    }
                    llamaState.download(url, filename: url.lastPathComponent)
                }
            }
    }
}

import SwiftUI

struct ContentView: View {
    @ObservedObject var state: LlamaState
    @Environment(\.scenePhase) private var scenePhase
    @State private var showLogs = false
    @State private var showChat = false
    @State private var prompt = ""
    @State private var copied = false
    private let accent = Color(red: 0.38, green: 0.91, blue: 0.77)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                memoryCard
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        modelCard.frame(minWidth: 300)
                        serverCard.frame(minWidth: 300)
                    }
                    VStack(spacing: 16) {
                        modelCard
                        serverCard
                    }
                }
                library
                Link("Gracias a CrucibleLLM, la base de CodeCrisol.",
                     destination: URL(string: "https://github.com/vidaliya/crucible-llm-server")!)
                    .font(.footnote)
            }
            .frame(maxWidth: 980)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.05, green: 0.07, blue: 0.10).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(accent)
        .sheet(isPresented: $showLogs) { DiagnosticsView() }
        .sheet(isPresented: $showChat) { chatPanel }
        .onChange(of: scenePhase) { phase in
            if phase == .active { state.refreshModels() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("SERVIDOR LOCAL", systemImage: "cpu")
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .tracking(3)
                .foregroundStyle(accent)
            Text("CodeCrisol")
                .font(.system(.largeTitle, design: .default, weight: .bold))
            Button { showLogs = true } label: { Label("Diagnóstico", systemImage: "text.alignleft") }
                .buttonStyle(.bordered)
        }
        .accessibilityElement(children: .contain)
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Modelo", systemImage: "memorychip")
                .font(.headline)
                .foregroundStyle(accent)
            Text(state.loadingModel ?? state.loadedModel ?? "Sin modelo cargado")
                .font(.title3.weight(.semibold))
            Text(state.loadStatus)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if state.hasModel {
                Label(state.supportsTools ? "Herramientas disponibles · ipad-code" : "Chat de texto · ipad-chat",
                      systemImage: state.supportsTools ? "hammer" : "text.bubble")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            reasoningControl
            if state.loadingModel != nil {
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    if state.loadProgress > 0 && state.loadProgress < 1 {
                        ProgressView(value: state.loadProgress)
                    } else {
                        ProgressView()
                    }
                }
                Button("Cancelar carga", role: .destructive) { state.cancelLoad() }
                    .buttonStyle(.bordered)
                    .disabled(state.stoppingLoad)
            } else {
                Picker("Motor para la próxima carga", selection: $state.useMetal) {
                    Text("Metal").tag(true)
                    Text("CPU").tag(false)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Motor para la próxima carga")
                .disabled(state.busy)
                Picker("Contexto para la próxima carga", selection: $state.requestedContextTokens) {
                    ForEach(LlamaState.contextOptions, id: \.self) { size in
                        Text("\(size.formatted()) tokens").tag(size)
                    }
                }
                .pickerStyle(.menu)
                .disabled(state.busy)
                if let context = state.activeContextTokens {
                    Text("Contexto activo · \(context.formatted()) tokens · KV \(state.activeCacheLabel)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Toggle("Caché KV compacta (Q8_0)", isOn: $state.compactKV)
                    .font(.subheadline)
                    .disabled(state.busy)
                if state.requestedContextTokens >= 65536 {
                    Text("Los contextos grandes consumen más memoria. Sube por etapas en este iPad.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if state.hasModel {
                    if state.hasPendingModelSettings {
                        Button("Aplicar y recargar") { state.reloadModel() }
                            .buttonStyle(.borderedProminent)
                            .disabled(state.busy)
                    }
                    HStack {
                        Button("Chat local") { showChat = true }
                        Button("Liberar modelo") { state.unloadModel() }
                            .disabled(state.busy)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .panel()
    }

    private var reasoningControl: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Pensamiento · \(state.reasoning.title)").font(.subheadline.weight(.medium))
            Slider(value: Binding(get: { Double(state.reasoning.rawValue) }, set: { value in
                if let level = ReasoningLevel(rawValue: Int(value)) { state.reasoning = level }
            }), in: 0...2, step: 1)
            .accessibilityLabel("Nivel de pensamiento")
            .accessibilityValue(state.reasoning.title)
            .disabled(state.hasModel && !state.supportsTools)
            Text(state.hasModel && !state.supportsTools ? "Disponible con Qwen 3.5." :
                    "Bajo: directo · Medio: hasta 128 tokens · Alto: hasta 512 tokens")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Memoria", systemImage: "memorychip")
                .font(.headline)
                .foregroundStyle(accent)
            Text("Increased Memory Limit · \(IncreasedMemoryStatus.current.rawValue)")
                .font(.subheadline)
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                let memory = RuntimeMemorySample()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Disponible para la app: \(RuntimeMemorySample.gib(memory.available)) · RAM física: \(RuntimeMemorySample.gib(memory.physical))")
                    if let footprint = memory.footprint {
                        Text("Huella del proceso: \(RuntimeMemorySample.gib(footprint))")
                    }
                    if let allocated = memory.metalAllocated, let budget = memory.metalBudget {
                        Text("Metal: \(RuntimeMemorySample.gib(allocated)) asignados · \(RuntimeMemorySample.gib(budget)) recomendados")
                    }
                    if let kv = state.activeKVBytes {
                        Text("Caché KV reservada: \(RuntimeMemorySample.gib(kv)) · \(state.activeCacheLabel)")
                    }
                }
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .panel()
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("API de red", systemImage: "network")
                .font(.headline)
                .foregroundStyle(accent)
            Label(state.serverRunning ? "Activo" : state.serverStarting ? "Iniciando…" : "Detenido",
                  systemImage: state.serverRunning ? "circle.fill" : "circle")
                .font(.title3.weight(.semibold))
            if state.serverRunning {
                Text(state.serverAddress)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = state.serverAddress
                    copied = true
                } label: {
                    Label(copied ? "Copiada" : "Copiar dirección", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
            } else {
                Text(state.serverError ?? (state.hasModel ? "Comparte este modelo con clientes de tu red local." : "Carga un modelo para habilitar la API."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(state.serverRunning ? "Detener servidor" : state.serverStarting ? "Cancelar inicio" : "Iniciar servidor") {
                    copied = false
                    state.toggleServer()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!state.hasModel)
                if state.serverRunning || state.serverError != nil {
                    Button("Reiniciar servidor") {
                        copied = false
                        state.restartServer()
                    }
                    .buttonStyle(.bordered)
                }
            }
            if state.isGenerating {
                prefillIndicator
                Button("Detener generación", role: .destructive) { state.stopGeneration() }
                    .buttonStyle(.bordered)
            }
        }
        .panel()
    }

    @ViewBuilder
    private var prefillIndicator: some View {
        if let progress = state.prefillProgress {
            ProgressView(value: Double(progress.processed), total: Double(progress.total)) {
                Text("Procesando entrada · \(progress.processed.formatted()) de \(progress.total.formatted()) tokens")
                    .font(.footnote)
            }
            if progress.cached > 0 {
                Text("\(progress.cached.formatted()) tokens reutilizados")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Biblioteca GGUF").font(.title2.bold())
                Spacer()
                Button { state.refreshModels() } label: {
                    Label("Actualizar", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            Text("También puedes copiar un GGUF en Archivos → En mi iPad → CodeCrisol.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                LoadCustomButton(llamaState: state)
                InputButton(llamaState: state)
            }
            .buttonStyle(.bordered)
            if let transfer = state.transfer {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(state.downloadProgress == nil ? "Importando modelo" : "Descargando modelo")
                                .font(.headline)
                            Text(transfer).lineLimit(1).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancelar", role: .destructive) { state.cancelDownload() }
                            .buttonStyle(.bordered)
                    }
                    if let progress = state.downloadProgress {
                        if let fraction = progress.fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView()
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            let seconds = max(0, Int(timeline.date.timeIntervalSince(progress.lastUpdate)))
                            Text(seconds >= 10 ? "\(progress.detail) · Sin datos nuevos hace \(seconds) s" : progress.detail)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView()
                    }
                }
                .font(.subheadline)
                .panel()
            }
            if !state.downloadedModels.isEmpty {
                Text("En el iPad").font(.headline)
                ForEach(state.downloadedModels) { model in
                    DownloadButton(state: state, model: model, downloaded: true)
                }
            }
            catalogSection("Programación con herramientas · ipad-code", models: state.undownloadedModels.filter(\.forOpenCode))
            catalogSection("Código y razonamiento · ipad-chat", models: state.undownloadedModels.filter { !$0.forOpenCode })
        }
        .panel()
    }

    @ViewBuilder
    private func catalogSection(_ title: String, models: [Model]) -> some View {
        if !models.isEmpty {
            Text(title).font(.headline)
            ForEach(models) { model in
                DownloadButton(state: state, model: model, downloaded: false)
            }
        }
    }

    private var chatPanel: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView {
                    Text(state.messageLog)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                TextField("Escribe un mensaje", text: $prompt)
                    .textFieldStyle(.roundedBorder)
                prefillIndicator
                HStack {
                    Button("Enviar") {
                        let text = prompt
                        prompt = ""
                        Task { await state.complete(text: text) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.busy || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Benchmark") { Task { await state.bench() } }.disabled(state.busy)
                    Button("Limpiar") { Task { await state.clear() } }.disabled(state.busy)
                    if state.isGenerating {
                        Button("Detener", role: .destructive) { state.stopGeneration() }
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .navigationTitle("Chat local")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cerrar") { showChat = false } }
        }
    }
}

private struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []
    private var log: DiagnosticLog { DiagnosticLog.shared }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Archivos › En mi iPad › CodeCrisol › Logs")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(lines.joined(separator: "\n"))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .navigationTitle("Diagnóstico")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: log.file) { Label("Compartir log", systemImage: "square.and.arrow.up") }
                }
            }
            .task {
                while !Task.isCancelled {
                    lines = Array(log.recent().reversed())
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
    }
}

private extension View {
    func panel() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.10)))
    }
}

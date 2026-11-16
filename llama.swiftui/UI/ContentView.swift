import SwiftUI

struct ContentView: View {
    @ObservedObject var state: LlamaState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showLogs = false
    @State private var showChat = false
    @State private var prompt = ""
    @State private var copied = false
    @State private var dashboardWidth: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var activityHeight: CGFloat = 124
    private let accent = Color(red: 0.38, green: 0.91, blue: 0.77)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                memoryCard
                if dashboardWidth >= 616 && !dynamicTypeSize.isAccessibilitySize {
                    let columnWidth = (dashboardWidth - 16) / 2
                    HStack(alignment: .top, spacing: 16) {
                        modelCard.frame(width: columnWidth)
                        serverColumn.frame(width: columnWidth)
                    }
                } else {
                    VStack(spacing: 16) {
                        modelCard
                        serverColumn
                    }
                }
                library
                Link("CodeCrisol se basa en Crucible LLM Server",
                     destination: URL(string: "https://github.com/vidaliya/crucible-llm-server")!)
                    .font(.footnote)
            }
            .frame(maxWidth: 980)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            min(980, geometry.size.width - 48)
        } action: { width in
            dashboardWidth = width
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
            Label("SERVIDOR LOCAL PARA CÓDIGO", systemImage: "cpu")
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
            Text(state.loadingModel ?? state.loadedModel ?? String(localized: "Sin modelo cargado"))
                .font(.title3.weight(.semibold))
            Text(state.loadStatus)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if state.hasModel {
                let capability: LocalizedStringKey = state.supportsTools ? "Herramientas disponibles · ipad-code" : "Chat de texto · ipad-chat"
                Label(capability,
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
                DisclosureGroup("Ajustes de inferencia") {
                    Picker("Hilos para procesar entrada", selection: $state.prefillThreads) {
                        ForEach(LlamaState.threadOptions, id: \.self) { count in
                            Text(count == 0 ? String(localized: "Automático") : count.formatted()).tag(count)
                        }
                    }
                    Picker("Hilos de generación", selection: $state.decodeThreads) {
                        ForEach(LlamaState.threadOptions, id: \.self) { count in
                            Text(count == 0 ? String(localized: "Automático") : count.formatted()).tag(count)
                        }
                    }
                    Picker("Lote de entrada", selection: $state.prefillBatch) {
                        ForEach(LlamaState.prefillBatchOptions, id: \.self) { count in
                            Text("\(count.formatted()) tokens").tag(count)
                        }
                    }
                }
                .font(.subheadline)
                .disabled(state.busy)
                if state.requestedContextTokens > 100_000 {
                    Text("Con más de 100.000 tokens, Q8_0 deja más memoria disponible para Metal.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if state.requestedContextTokens >= 65_536 {
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
        let title: String
        switch state.reasoning {
        case .low: title = String(localized: "Bajo")
        case .medium: title = String(localized: "Medio")
        case .high: title = String(localized: "Alto")
        }
        return VStack(alignment: .leading, spacing: 5) {
            Text("Pensamiento · \(title)").font(.subheadline.weight(.medium))
            Slider(value: Binding(get: { Double(state.reasoning.rawValue) }, set: { value in
                if let level = ReasoningLevel(rawValue: Int(value)) { state.reasoning = level }
            }), in: 0...2, step: 1)
            .accessibilityLabel("Nivel de pensamiento")
            .accessibilityValue(title)
            .disabled(state.hasModel && !state.supportsTools)
            let description: LocalizedStringKey = state.hasModel && !state.supportsTools ? "Disponible con Qwen 3.5." :
                "Bajo sin pensamiento · Medio hasta 128 tokens · Alto hasta 512 tokens"
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Memoria", systemImage: "memorychip")
                .font(.headline)
                .foregroundStyle(accent)
            Text("Increased Memory Limit · \(memoryEntitlementStatus)")
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

    private var memoryEntitlementStatus: String {
        switch IncreasedMemoryStatus.current {
        case .enabled: return String(localized: "Activado en la firma")
        case .disabled: return String(localized: "Desactivado en la firma")
        case .unknown: return String(localized: "Firma no verificable")
        }
    }

    private var serverColumn: some View {
        VStack(spacing: 16) {
            serverCard
            agentActivityCard
        }
    }

    private var agentActivityCard: some View {
        Color.clear
            .frame(height: activityHeight)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                agentActivityContent
            }
            .clipped()
            .panel()
    }

    private var agentActivityContent: some View {
        let activity = state.agentActivity
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Actividad del agente", systemImage: "text.alignleft")
                    .font(.headline)
                    .foregroundStyle(accent)
                Spacer()
                Button(role: .destructive) { state.stopGeneration() } label: {
                    Image(systemName: "stop.fill")
                }
                .accessibilityLabel("Detener generación")
                .buttonStyle(.bordered)
                .opacity(activity?.isRunning == true ? 1 : 0)
                .disabled(activity?.isRunning != true)
                .accessibilityHidden(activity?.isRunning != true)
            }
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let activity {
                            HStack(spacing: 8) {
                                if activity.isRunning && state.prefillProgress == nil {
                                    ProgressView()
                                        .controlSize(.small)
                                        .accessibilityHidden(true)
                                }
                                Text(activity.status).font(.subheadline)
                            }
                            .id("activity-status")
                            if activity.isRunning { prefillIndicator }
                            if !activity.thought.isEmpty {
                                Text("Pensamiento del modelo")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(activity.thought)
                                    .font(.system(.footnote, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text("Aún no hay peticiones en esta sesión.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Color.clear.frame(height: 1).id("thought-end")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear {
                    if activity?.isRunning == true, activity?.thought.isEmpty == false {
                        reader.scrollTo("thought-end", anchor: .bottom)
                    }
                }
                .onChange(of: activity?.thought) { thought in
                    if activity?.isRunning == true, thought?.isEmpty == false {
                        reader.scrollTo("thought-end", anchor: .bottom)
                    }
                }
                .onChange(of: activity?.isRunning) { running in
                    if running == false {
                        reader.scrollTo("activity-status", anchor: .top)
                    }
                }
            }
        }
    }

    private var serverCard: some View {
        let serverStatus: LocalizedStringKey = state.serverRunning ? "Activo" : state.serverStarting ? "Iniciando…" : "Detenido"
        let serverAction: LocalizedStringKey = state.serverRunning ? "Detener servidor" : state.serverStarting ? "Cancelar inicio" : "Iniciar servidor"
        let copyAction: LocalizedStringKey = copied ? "Copiada" : "Copiar dirección"
        return VStack(alignment: .leading, spacing: 14) {
            Label("API de red", systemImage: "network")
                .font(.headline)
                .foregroundStyle(accent)
            Label(serverStatus,
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
                    Label(copyAction, systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
            } else {
                Text(state.serverError ?? (state.hasModel ? String(localized: "Conecta OpenCode a este modelo por la red local.") :
                                          String(localized: "Carga un modelo para habilitar la API.")))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(serverAction) {
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
                            let transferStatus: LocalizedStringKey = state.downloadProgress == nil ? "Importando modelo" : "Descargando modelo"
                            Text(transferStatus)
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
                            Text(seconds >= 10 ? String(localized: "\(progress.detail) · Sin datos nuevos hace \(seconds) s") : progress.detail)
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
    private func catalogSection(_ title: LocalizedStringKey, models: [Model]) -> some View {
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

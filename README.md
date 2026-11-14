# CrucibleLLM

Run custom GGUF language models locally on iPad and iPhone. Serve them through an OpenAI-compatible HTTP API. No cloud, no subscription, no data leaves your device.

## Features

- **Local inference** — runs GGUF models on-device with Metal GPU acceleration via llama.cpp
- **OpenAI-compatible API** — serves `/v1/chat/completions` so any client that speaks OpenAI can talk to your iPad
- **HuggingFace downloads** — browse and download models directly in the app
- **Server mode** — toggle the HTTP server on/off, see your IP and port in the UI
- **Default models** — ships with Gemma 3 4B and Qwen 3.5 4B in the download list
- **Zero cloud** — your model, your device, your data

## Quick Start

1. Sideload `CrucibleLLM.ipa` via [AltStore](https://altstore.io/) or [AltServer-Linux](https://github.com/NyaMisty/AltServer-Linux)
2. Open the app, go to **View Models**, download a model (or paste a HuggingFace GGUF URL)
3. Tap the model to load it
4. Tap **Start Server**
5. The app shows your IP and port — you're serving

## API Usage

```bash
curl http://YOUR_IPAD_IP:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "local",
    "messages": [
      {"role": "system", "content": "Be concise."},
      {"role": "user", "content": "What is the capital of France?"}
    ],
    "max_tokens": 100
  }'
```

Use `http://YOUR_IPAD_IP:8080/v1` as the base URL. The API supports text chat, `GET /v1/models`, and SSE when the request sets `"stream": true`.

## OpenCode en Windows

1. Instala el IPA compilado y firmado en tu iPad. Conecta el PC y el iPad a la misma red de confianza. El servidor usa HTTP en la LAN.
2. En **View Models**, descarga y carga **Qwen3-8B Q4_K_M**. Puedes empezar con el Qwen de 4B para probar antes la conexión.
3. Pulsa **Start Server** y deja la app visible. Copia la dirección que aparece y añade `/v1`.
4. En el proyecto que abrirás con OpenCode 2.x, copia [opencode.example.jsonc](opencode.example.jsonc) a `opencode.jsonc` o integra el proveedor `ipad` y el agente `ipad-chat` en tu configuración existente. Sustituye la IP de ejemplo por la del iPad.
5. Prueba con `opencode run --agent ipad-chat --model ipad/local "Responde solo con OK."`

El modelo se publica como `local` y corresponde al GGUF cargado en el iPad. OpenCode puede usarlo para conversación de texto. Las acciones que requieren llamadas a herramientas, como editar archivos o ejecutar comandos, requieren soporte adicional del servidor.

El contexto de 4.096 tokens incluye instrucciones de OpenCode, historial y respuesta. Si pruebas con un prompt largo, empieza una sesión nueva para liberar contexto. El servidor acepta una generación a la vez y devuelve HTTP 429 si está ocupado.

## Diagnóstico en el iPad

Abre **Diagnóstico** para revisar la carga del GGUF, el contexto, la memoria disponible y los errores de llama.cpp. El registro se guarda en **Archivos → En mi iPad → CrucibleLLM → Logs** y se puede compartir desde la app.

Prueba **Metal** primero. Si un modelo falla, selecciona **CPU** y vuelve a cargarlo para comprobar si el fallo depende de la GPU. Puedes cancelar la carga, detener una generación y liberar el modelo. Inicia la API cuando el modelo indique que está listo.

El proyecto solicita `com.apple.developer.kernel.increased-memory-limit`. Si firmas el IPA de Actions por separado, incluye el entitlement en la firma con un perfil que lo admita.

## Building from Source

The app builds on GitHub Actions using a macOS runner with Xcode:

1. Fork this repo
2. Push to trigger the `Build iOS IPA` workflow
3. Download the IPA artifact from the Actions run
4. Sideload to your device via AltStore

The workflow verifies the SHA-256 of the official llama.cpp XCFramework for the pinned submodule commit and compiles the iOS app on a macOS runner.

## Known Limitations

- **Memory pressure** — iPads with 8GB RAM can crash on long prompts with large models. Use Q4_K_M quantization and keep context sizes reasonable.
- **Foreground only** — iOS suspends background apps. The server only works while the app is in the foreground with the screen on.
- **Single request** — the server allows one generation at a time.

## Architecture

- Swift + SwiftUI frontend
- llama.cpp via xcframework for inference (Metal-accelerated)
- Network.framework HTTP server (no external dependencies)
- ChatML prompt formatting with `/no_think` support for reasoning models

## Created By

[Crucible](https://github.com/vidaliya) — built on a Tuesday because we needed an iOS Ollama and nobody had made one.

## License

MIT

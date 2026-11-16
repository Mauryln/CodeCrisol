# CodeCrisol

Run GGUF models on iPad and iPhone and serve them over an OpenAI-compatible API. CodeCrisol focuses on local coding workflows with OpenCode.

## Features

- **Local inference** — runs GGUF models on-device with Metal GPU acceleration via llama.cpp
- **OpenAI-compatible API** — serves `/v1/chat/completions` so any client that speaks OpenAI can talk to your iPad
- **HuggingFace downloads** — browse and download models directly in the app
- **Server mode** — toggle the HTTP server on/off, see your IP and port in the UI
- **Model catalog** — Qwen 3.5 for OpenCode tools, plus Qwen Coder, DeepSeek and IBM Granite for chat
- **Zero cloud** — your model, your device, your data

## Quick Start

1. Sideload `CodeCrisol.ipa` via [AltStore](https://altstore.io/) or [AltServer-Linux](https://github.com/NyaMisty/AltServer-Linux)
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
2. En **Biblioteca GGUF**, descarga y carga **Qwen 3.5 9B Q4_K_M**. Puedes empezar con la variante 4B para probar antes la conexión.
3. Pulsa **Iniciar servidor** y deja la app visible. Copia la dirección completa que aparece, incluida la terminación `/v1`.
4. En el proyecto que abrirás con OpenCode 2.x, copia [opencode.example.jsonc](opencode.example.jsonc) a `opencode.jsonc` o integra el proveedor `ipad` y el agente `ipad-chat` en tu configuración existente. Sustituye la IP de ejemplo por la del iPad.
5. Prueba con `opencode run --agent ipad-chat --model ipad/local "Responde solo con OK."`

El modelo se publica como `local` y corresponde al GGUF cargado en el iPad. El ejemplo manual configura el chat de texto. Para activar las herramientas con un modelo compatible, usa el script de sincronización.

### Programación con archivos y comandos

Carga **Qwen 3.5** en CodeCrisol e inicia el servidor. Desde la carpeta que quieras abrir en OpenCode, ejecuta este script de PowerShell. Usa la ruta al repositorio y la URL que muestra el iPad.

```powershell
& 'C:/ruta/a/CodeCrisol/Sync-CrucibleOpenCode.ps1' -BaseUrl http://192.168.1.62:8080/v1 -Launch
```

El script consulta `/v1/models`, sincroniza el contexto efectivo y abre el agente `ipad-code` cuando el modelo soporta herramientas. Vuelve a ejecutarlo al cambiar el contexto, el modelo o el puerto. Puedes omitir `-Launch` para actualizar solo la configuración.

El iPad genera las llamadas y OpenCode las ejecuta en Windows. El agente puede leer y buscar en el proyecto, escribir o editar archivos y ejecutar comandos para trabajar con archivos y directorios. OpenCode aplica sus permisos de edición y shell y devuelve el resultado al modelo.

El contexto efectivo incluye las instrucciones de OpenCode, el historial y la respuesta. Si pruebas con un prompt largo, empieza una sesión nueva para liberar contexto. El servidor acepta una generación a la vez y devuelve HTTP 429 si está ocupado.

### Más modelos de programación

Para usar un modelo que requiere más memoria que la disponible en el iPad, ejecútalo en la estación de trabajo o en otro equipo con un servidor compatible con **Chat Completions** y llamadas a herramientas. El script crea un proveedor y un agente `<proveedor>-code` con las mismas skills y permisos que `ipad-code`. Puedes alternar entre ellos sin cambiar el destino del iPad.

```powershell
$sync = 'C:/ruta/a/CodeCrisol/Sync-CrucibleOpenCode.ps1'

# Ejemplo para un runtime local como LM Studio en Windows.
& $sync -BaseUrl http://127.0.0.1:1234/v1 -ProviderId coder-windows `
    -ModelId 'id-del-modelo-en-models' -ContextLength 32768 -SupportsTools -Launch

# Ejemplo para vLLM u otro runtime en un servidor de inferencia en la LAN.
& $sync -BaseUrl http://gpu-host:8000/v1 -ProviderId coder-servidor `
    -ModelId 'id-del-modelo-en-models' -ContextLength 65536 -SupportsTools
opencode mini --standalone --agent coder-servidor-code --model coder-servidor/id-del-modelo-en-models
```

Usa el ID exacto publicado en `GET /models` bajo la URL base. Si el servidor lista un solo modelo puedes omitir `-ModelId`. `-ContextLength` se puede omitir cuando el servidor anuncia el contexto efectivo en `context_length`. Usa `-SupportsTools` si el servidor no anuncia `supports_tools` y has confirmado que el modelo y su plantilla aceptan llamadas estructuradas.

Un servicio remoto también puede registrarse con una URL HTTPS. Si exige una clave, usa `-ApiKeyEnv NOMBRE_DE_VARIABLE` con una variable ya disponible en el entorno de PowerShell. El archivo de configuración guarda el nombre de la variable. El servicio seleccionado recibe las peticiones de la sesión, que pueden incluir código y resultados de herramientas según la tarea y los permisos. [Proveedores personalizados de OpenCode](https://opencode.ai/docs/providers/#custom)

## Diagnóstico en el iPad

Abre **Diagnóstico** para revisar la carga del GGUF, el contexto, la memoria disponible y los errores de llama.cpp. El registro se guarda en **Archivos → En mi iPad → CodeCrisol → Logs** y se puede compartir desde la app.

Durante una descarga, **Biblioteca GGUF** muestra los bytes recibidos, el porcentaje si el servidor indica el tamaño total y cuánto tiempo lleva sin recibir datos. El registro guarda el inicio, los hitos de progreso y el resultado.

Prueba **Metal** primero. Si un modelo falla, selecciona **CPU** y vuelve a cargarlo para comprobar si el fallo depende de la GPU. Puedes cancelar la carga, detener una generación y liberar el modelo. Inicia la API cuando el modelo indique que está listo.

El proyecto solicita `com.apple.developer.kernel.increased-memory-limit`. Si firmas el IPA de Actions por separado, incluye el entitlement en la firma con un perfil que lo admita.

La tarjeta **Memoria** muestra si el permiso aparece en la firma instalada y cuánto puede asignar CodeCrisol en ese momento. Si la firma no se puede inspeccionar, muestra **Firma no verificable**. La cifra disponible corresponde al presupuesto del proceso. La RAM física se muestra aparte.

El catálogo incluye Qwen 3.5 4B y 9B de Bartowski, Unsloth y LM Studio Community para `ipad-code`. Qwen2.5-Coder 7B, DeepSeek R1 Distill 7B, DeepSeek Coder V2 Lite e IBM Granite 4.0 Micro se ofrecen para `ipad-chat` en esta build. La tarjeta del modelo cargado indica si tiene herramientas disponibles. El script de sincronización muestra en OpenCode el nombre del GGUF cargado y su contexto efectivo.

En **Modelo**, el control **Pensamiento** se aplica a la siguiente petición de Qwen 3.5. **Bajo** cierra el bloque de razonamiento desde el prompt. **Medio**, el valor inicial, reserva hasta 128 tokens y **Alto** hasta 512. El motor reduce el presupuesto en salidas cortas para dejar espacio a la respuesta o a la llamada de herramienta.

**Caché KV compacta (Q8_0)** reduce la memoria de las claves y valores de atención con Flash Attention. Actívala y usa **Aplicar y recargar**. El diagnóstico muestra la memoria KV reservada. Si un GGUF falla al iniciar con ese ajuste, vuelve a FP16 y recarga.

CodeCrisol recuerda los ajustes de cada GGUF tras una carga exitosa y restaura el perfil al seleccionarlo de nuevo. Durante el prefill, la app muestra los tokens de entrada procesados y permite detener la generación. **Memoria** separa la huella del proceso, las asignaciones de Metal, su presupuesto recomendado y la reserva KV cuando el motor la reporta.

Para Qwen 3.5, el servidor conserva un punto de restauración en memoria y lo reutiliza si el siguiente prompt comparte ese prefijo exacto. El log y \`usage.prompt_tokens_details.cached_tokens\` indican cuántos tokens se ahorraron. Envía \`"cache_prompt": false\` en una petición para obtener una medición en frío.

Para actualizar desde CrucibleLLM, instala CodeCrisol con el mismo identificador y equipo de firma usados en la instalación anterior. Conserva una copia de tus GGUF si tu instalador requiere desinstalar la app.

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

## Agradecimientos

Gracias a CrucibleLLM y a [vidaliya](https://github.com/vidaliya) por construir la base de CodeCrisol. El proyecto original aportó la app nativa para iOS, la integración con llama.cpp y el servidor local sobre el que construimos el flujo de programación con OpenCode. [CrucibleLLM original](https://github.com/vidaliya/crucible-llm-server)

## License

MIT

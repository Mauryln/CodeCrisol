# Plan de rendimiento para CrucibleLLM

## Referencia

Usa Qwen 3.5 4B Q4_K_M en el iPad Pro M5 de 12 GB, con Metal, contexto de 4.096 tokens, una petición a la vez y el iPad en primer plano. Anota la build, el nombre exacto del GGUF, la versión de iPadOS, si está cargando batería y la dirección que muestra la app. Conserva el mismo archivo y las mismas peticiones al comparar con Windows o CPU.

| Prueba | Procedimiento | Qué registrar |
|---|---|---|
| Arranque | Tres cargas después de cerrar y volver a abrir la app. Cronometra de **Cargar** a **Listo**. | Tiempo de carga, memoria disponible al inicio y fallos |
| Inferencia corta | Una petición de calentamiento y cinco medidas con el mismo prompt y un máximo de 128 tokens. | Mediana hasta el primer texto, mediana de tok/s y tokens generados |
| Contexto largo | Repite con un texto de entrada de unas 3.000 fichas reales según `prompt_tokens`. Reserva espacio para la salida. | Tiempo hasta el primer texto y prefill en el log |
| Rendimiento sostenido | Repite la prueba corta durante 20 minutos sin recargar el modelo. Compara las primeras cinco mediciones con las últimas cinco. | Variación de tok/s, latencia y errores |
| Comparación | Repite la prueba corta y la larga con CPU en el iPad y con el mismo GGUF en Windows. Después prueba un 8B en Metal si interesa evaluar calidad. | Latencia, tok/s, calidad y estabilidad por modelo y motor |
| Recuperación | Importa un GGUF desde Archivos, arranca el servidor y reinícialo tres veces. Entre ciclos, pide una respuesta. | URL efectiva, petición completada y errores en Diagnóstico |

## Medición desde Windows

En PowerShell, pega este bloque con la URL que muestra CrucibleLLM. La primera petición calienta el modelo. Las cinco restantes muestran cifras individuales y medianas. Si quieres comparar motores, conserva el prompt y el máximo de salida. Un contexto largo se puede probar sustituyendo el prompt por el contenido del mismo archivo de texto en cada equipo.

```powershell
$env:CRUCIBLE_API_URL = 'http://192.168.1.62:8080/v1'
@'
import json
import os
import statistics
import time
import urllib.request

url = os.environ["CRUCIBLE_API_URL"].rstrip("/") + "/chat/completions"
body = {
    "model": "local",
    "messages": [{"role": "user", "content": "Enumera 30 consejos prácticos para documentar un proyecto de software. Escribe una oración por consejo."}],
    "max_tokens": 128,
    "stream": True,
    "stream_options": {"include_usage": True},
}
samples = []
for run in range(6):
    req = urllib.request.Request(url, json.dumps(body).encode(), {"Content-Type": "application/json"})
    start = time.perf_counter()
    first = None
    last = None
    usage = {}
    with urllib.request.urlopen(req, timeout=120) as response:
        for line in response:
            if not line.startswith(b"data: "):
                continue
            data = line[6:].strip()
            if data == b"[DONE]":
                break
            event = json.loads(data)
            if "error" in event:
                raise RuntimeError(event["error"])
            usage = event.get("usage") or usage
            if any(c.get("delta", {}).get("content") for c in event.get("choices", [])):
                last = time.perf_counter()
                if first is None:
                    first = last
    output = usage.get("completion_tokens", 0)
    if first is None or last is None or output < 2 or last <= first:
        raise RuntimeError("Respuesta demasiado corta o sin estadísticas")
    sample = (1000 * (first - start), (output - 1) / (last - first))
    label = "calentamiento" if run == 0 else str(run)
    print(f"{label}: TTFT={sample[0]:.0f} ms, salida={sample[1]:.1f} tok/s, entrada={usage['prompt_tokens']}, salida_tokens={output}")
    if run:
        samples.append(sample)
print(f"Mediana: TTFT={statistics.median(s[0] for s in samples):.0f} ms, salida={statistics.median(s[1] for s in samples):.1f} tok/s")
'@ | python -
```

La latencia hasta el primer texto incluye la red y la espera de la API. La tasa calculada se observa desde Windows; los envíos SSE o los tokens que no producen texto visible pueden introducir diferencias. **Diagnóstico** registra el prefill y la tasa de generación observada en el iPad. Usa OpenCode después para medir la experiencia real: sus instrucciones y la generación del título cambian la carga de trabajo.

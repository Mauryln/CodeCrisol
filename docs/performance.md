# Plan de rendimiento para CodeCrisol

## Referencia

Usa Qwen 3.5 4B Q4_K_M en el iPad Pro M5 de 12 GB, con Metal, contexto de 4.096 tokens, una petición a la vez y el iPad en primer plano. Anota la build, el nombre exacto del GGUF, la versión de iPadOS, si está cargando batería y la dirección que muestra la app. Conserva el mismo archivo y las mismas peticiones al comparar con Windows o CPU.

Referencia medida en la build 4 con 36 tokens de entrada y 128 de salida. El tiempo al primer texto fue de 901 ms en el calentamiento y 184 ms de mediana en las cinco repeticiones. La salida fue de 39,0 tok/s de mediana desde Windows.

### Prueba con Qwen 3.5 9B en iPad

Medido el 15 de noviembre de 2026 desde Windows contra la build 7 del iPad Pro M5 con **Qwen 3.5 9B Q4_K_M y 16.384 tokens de contexto**. Cada petición generó 128 tokens. Las medianas excluyen la primera petición de cada serie.

| Carga | Tokens de entrada | Mediciones | Mediana al primer texto | Mediana de salida |
|---|---:|---:|---:|---:|
| Consejos para documentar software | 32 | 5 | 472 ms | 23,5 tok/s |
| Resumen de 145 reglas de documentación | 3.509 | 3 | 10,26 s | 16,6 tok/s |

| Prueba | Procedimiento | Qué registrar |
|---|---|---|
| Arranque | Tres cargas después de cerrar y volver a abrir la app. Cronometra de **Cargar** a **Listo**. | Tiempo de carga, memoria disponible al inicio y fallos |
| Inferencia corta | Una petición de calentamiento y cinco medidas con el mismo prompt y un máximo de 128 tokens. | Mediana hasta el primer texto, mediana de tok/s y tokens generados |
| Contexto largo | Repite con un texto de entrada de unas 3.000 fichas reales según `prompt_tokens`. Reserva espacio para la salida. | Tiempo hasta el primer texto y prefill en el log |
| Rendimiento sostenido | Repite la prueba corta durante 20 minutos sin recargar el modelo. Compara las primeras cinco mediciones con las últimas cinco. | Variación de tok/s, latencia y errores |
| Comparación | Repite la prueba corta y la larga con CPU en el iPad y con el mismo GGUF en Windows. Después prueba un 8B en Metal si interesa evaluar calidad. | Latencia, tok/s, calidad y estabilidad por modelo y motor |
| Recuperación | Importa un GGUF desde Archivos, arranca el servidor y reinícialo tres veces. Entre ciclos, pide una respuesta. | URL efectiva, petición completada y errores en Diagnóstico |

### Registros del 15 de noviembre · Qwen 3.5 9B Q4_K_M

| Medición | Entrada | Reutilizados | Prefill | Salida |
|---|---:|---:|---:|---:|
| Build 9 · contexto amplio | 122.922 | — | 774,52 s | 128 tokens · 7,4 tok/s |
| Build 10 · continuación con caché | 30.253 | 29.696 | 2,19 s | 2 tokens |
| Build 10 · misma continuación sin caché | 30.253 | 0 | 103,52 s | 2 tokens |
| Build 10 · respuesta larga | 8.695 | 7.680 | 1,10 s | 2.416 tokens · 14,6 tok/s |
| Build 10 · petición sin prefijo reutilizado | 7.279 | 0 | 21,13 s | 90 tokens |
| Build 10 · siguiente petición | 7.347 | 7.168 | 36,5 ms | 64 tokens |

En la comparación controlada de la build 10, ambas continuaciones respondieron `LISTO`. El primer texto pasó de 104,04 s a 2,65 s. La API contó 30.253 tokens de entrada en ambos casos. La caché evitó evaluar el 98,2 % del prompt, que siguió ocupando el mismo espacio de contexto. El log tampoco identifica qué cambió entre la petición de 13.958 tokens y la posterior de 7.279, que perdió la reutilización del prefijo.

La salida de 2.416 tokens tomó unos 165 s de generación pese al prefill de 1,10 s. Los logs de la build 10 registran el presupuesto de pensamiento. Las builds con el contador nuevo registran también los tokens generados dentro del bloque de pensamiento con presupuesto, incluidos en el total de salida. Para medir ahorro de tokens, repite una misma tarea de OpenCode en sesiones equivalentes con **Medio** y **Bajo**. Comparte el GGUF, contexto, herramientas y límite de salida entre pruebas. Registra entrada, tokens reutilizados, pensamiento, salida y tiempo total por tarea. Comprueba que ambas ejecuciones completaron la tarea y cuenta las llamadas y reintentos, incluidos los turnos fallidos.

En Metal, la reserva KV a 4.096 tokens pasó de 128 MiB en FP16 a 68 MiB en Q8_0. A 131.072 tokens, Q8_0 reservó 2.176 MiB. La build 10 registró hasta 2,48 GiB de huella del proceso y 7,58 GiB de Metal durante la prueba de 30K. La reserva KV, la huella y el uso de Metal se registran por separado.

## Captura desde Windows

### M5 y contexto de más de 100K

La build 11 detectó `Apple M5 GPU` con `has tensor = true` y descargó las 33 capas de Qwen 3.5 9B a Metal. El backend fijado incluye Metal 4 para los kernels que usan la API de tensores. El indicador confirma disponibilidad, y la ganancia de cada GGUF se mide con la misma carga. Apple informa más de 4× en cómputo pico de GPU para IA al comparar M5 con M4. [Metal 4 y aceleradores neuronales del M5](https://developer.apple.com/videos/play/tech-talks/111432/)

| Configuración de la build 11 | Entrada | Reutilizados | Primer texto |
| --- | ---: | ---: | ---: |
| 32K, Metal, Q8_0 con prefijo | 29.386 | 29.184 | 1,00 s |
| 32K, Metal, Q8_0 en frío | 29.386 | 0 | 103,95 s |
| 64K, Metal, Q8_0 en frío | 29.386 | 0 | 110,48 s |
| 64K, Metal, FP16 en frío | 29.386 | 0 | 107,76 s |
| 64K, Metal, Q8_0 en frío | 60.006 | 0 | 272,61 s |

Todas estas peticiones respondieron `LISTO`. En el ensayo de 60K, Q8_0 reservó 1.088 MiB de KV. El diagnóstico registró 6,38 GiB de Metal sobre 8,00 GiB recomendados, 1,43 GiB de huella y temperatura moderada. Las muestras individuales de FP16 y Q8_0 a 64K dieron tiempos cercanos. Para contextos largos, la ventaja observada de Q8_0 es el espacio de memoria. Con esta familia, los 2.176 MiB de KV Q8_0 de la prueba anterior a 131.072 tokens permiten reservar salida por encima de 100K de entrada.

En la build 12, sube de 64K a 96K, 112K y 128K con Metal y Q8_0. **Ajustes de inferencia → Lote de entrada** permite comparar 256, 512 y 1.024. Empieza con el ajuste de referencia de 512 e hilos automáticos. Para evaluar 1.024, conserva el mismo GGUF, contexto, KV e historial y mide prefill, memoria mínima disponible y estado térmico. Un lote mayor también aumenta el trabajo que debe terminar antes de que la app pueda cancelar. Comprueba cancelación y que la continuación reutilice el prefijo con cada configuración.

### Ejecutar la captura

Con Python 3.8 o posterior, ejecuta el script desde el repositorio usando la dirección que muestra el iPad. Deja CodeCrisol visible y pausa otras peticiones durante cada captura.

```powershell
$CrucibleUrl = 'http://192.168.1.62:8080/v1'
python Benchmark-CodeCrisol.py $CrucibleUrl --label metal-q8-32k-medio --target-tokens 30000
```

El script registra `GET /v1/models`, el calentamiento y tres respuestas cortas. Calibra el historial con los tokens que devuelve la API, envía una petición para guardar el prefijo y compara la misma continuación con `cache_prompt` activado y desactivado. El resultado esperado en ambas es `LISTO`. Los JSON y CSV de `capture-codecrisol/` se actualizan después de cada petición. Incluyen hora UTC, ID de respuesta, tiempo al primer texto, duración, tokens de entrada y salida, tokens reutilizados, errores y comprobaciones. El objetivo de entrada es aproximado y el script exige que deje al menos 1.024 tokens libres en el contexto anunciado.

Para comparar **Metal con Q8_0 y FP16**, usa el mismo GGUF, contexto y objetivo de entrada y cambia solo la etiqueta y el ajuste de caché. Repite en **32K y 64K** con un objetivo común de 30.000 para medir el efecto de reservar más contexto. Para probar una carga de 64K, sube el objetivo a 60.000 después de confirmar la estabilidad. Prueba cerca de 128K con un objetivo de 120.000 después de pasar las pruebas anteriores. Esas peticiones en frío pueden tardar varios minutos.

Para la referencia en **CPU**, empieza con `--short-only` y luego usa una carga moderada. En **Modelo → Hilos de CPU**, ajusta prefill y generación por separado y pulsa **Aplicar y recargar**. Compara **Automático** con un valor fijo en cada fase manteniendo fija la otra. Usa un historial con caché desactivada para evaluar prefill y la mediana de las respuestas cortas para evaluar generación. Etiqueta cada configuración medida e incluye la build, la versión de iPadOS y si el equipo estaba cargando.

Añade `--check-cancellation` a una captura con el iPad al alcance para detener la generación durante el prefill. El script espera cinco segundos antes de iniciar esa petición y comprueba la cancelación y la respuesta siguiente. Al terminar todas las configuraciones, comparte el archivo de **Diagnóstico → Compartir log** con los informes de Windows. Si CodeCrisol se reinició, comparte también los archivos de esas sesiones desde **Archivos → En mi iPad → CodeCrisol → Logs**. Empareja las peticiones por ID de respuesta o por hora UTC para los fallos anteriores al primer evento SSE. Usa el tiempo del cliente para la experiencia por LAN y el prefill y los tokens por segundo de Diagnóstico para comparar el motor. Compara también el mínimo de memoria disponible, la huella del proceso, el pico de Metal y el estado térmico de cada fase en el log del iPad.

### Calidad y tokens con OpenCode

Usa un proyecto de prueba y una sesión nueva para cada combinación de skills y nivel de pensamiento. Para la referencia con **Medio**, sincroniza el cliente con `-WithoutSkills`. Repite con las skills activas en **Medio** y después en **Bajo**. Repite un fallo con prueba existente, un cambio pequeño con resultado comprobable y una revisión de diff con un defecto conocido. Mantén el mismo modelo, contexto, código inicial, permisos y enunciado. Ejecuta las pruebas fuera de la conversación para confirmar el resultado. Guarda por tarea la hora de inicio y fin, el resultado de las pruebas, las llamadas a herramientas y los reintentos. Suma entrada, caché, pensamiento y salida de las peticiones del intervalo con el registro de Diagnóstico. Incluye los turnos que fallaron.

## Contexto para programación

1. Selecciona **8.192** tokens en la tarjeta del modelo y pulsa **Aplicar y recargar**. Luego inicia la API y verifica el contexto activo en la app o en `GET /v1/models`, campo `context_length`.
2. Iguala `providers.ipad.models.local.limit.context` en OpenCode al contexto activo. Si cambia el puerto, usa la dirección nueva en `providers.ipad.settings.baseURL`. El reinicio del servidor intenta reutilizar el último puerto disponible.
3. Repite con **16.384** y **32.768**. En cada paso repite el prompt corto y una petición con aproximadamente la mitad de ese contexto ocupado. Anota tiempo de carga, latencia, tok/s y si hubo fallos de memoria. Prueba **65.536** y **131.072** solo después de confirmar que los pasos anteriores son estables. Cada GGUF tiene su propio límite.

---
name: codecrisol-revision-diff
description: Revisa un diff en busca de errores y regresiones verificables.
---

1. Lee el diff y el contexto inmediato. Prioriza errores de comportamiento, pérdida de datos y contratos entre capas.
2. Sigue las llamadas y comprueba los casos límite antes de reportar. Busca una prueba existente que confirme el caso.
3. Ordena los hallazgos por impacto. Da archivo y línea, condición que reproduce el problema y efecto observable.
4. Si no hay hallazgos, dilo y señala las comprobaciones que falten.

---
name: codecrisol-cambio-acotado
description: Aplica un cambio de código pequeño con una comprobación reproducible.
---

1. Revisa el estado del repositorio y las reglas del área. Identifica el comportamiento esperado y quién lo invoca.
2. Edita el punto responsable con las funciones y convenciones existentes. Conserva los cambios locales.
3. Ejecuta la prueba más cercana al comportamiento solicitado. Revisa el diff para detectar efectos en llamadas vecinas.
4. Indica qué cambió y qué comprobación ejecutaste. Si quedó algo sin verificar, señala el paso concreto.

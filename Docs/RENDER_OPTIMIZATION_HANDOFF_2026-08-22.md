# Handoff — Optimización del render nativo — 2026-08-22

## Propósito y límite

Este documento conserva el estado operativo al cerrar la sesión. No cambia ningún
contrato ni sustituye los documentos normativos de `Docs/architecture/`.

La meta de esta serie es reducir el tiempo del render nativo y de Render Queue sin
reducir muestras, alterar el modelo físico, reutilizar resultados de otro instante
temporal ni introducir una ruta 2D aproximada.

## Última fase cerrada limpiamente

El último commit limpio es:

```text
04043f2 Remove unused source row-prefix preparation
```

El cambio elimina la preparación de prefijos por fila de `source_acescg`: el kernel
óptico no integra nunca esa textura. Sólo integra las señales de Device y emisión
lineal preparada. Eliminar ese recurso evita una asignación y un escaneo completo
por muestra preparada, sin modificar el resultado.

Las fases inmediatamente anteriores que permanecen cerradas son:

| Commit | Optimización exacta | Resultado conocido |
|---|---|---|
| `4716ec8` | Stripe lógico de 128 filas | Conserva el límite de progreso/cancelación y comparte planificación horizontal. |
| `b34ff79` | Acumulación temporal dentro de stripes | Mantiene el orden de muestras temporal. |
| `34d1cf2` | Reutilización de la reducción de veiling por señal preparada idéntica | Sólo evita repetir la reducción invariante. |
| `9fb1176` | Inversión radial especializada | Sólo para el caso contractual radial de grado dos; el resto conserva el solver general. |
| `903390a` | Un command buffer por stripe temporal | No publicó muestras intermedias ni cambió su orden. |
| `20a0b3e` | Uniformity por componente RGB | Preserva muestras de lattice, ecuación y orden aritmético. |
| `63ed0a1` | Kernel temporal fusionado para preparaciones idénticas | La prueba de paridad devuelve desviación máxima cero en las rutas cubiertas. |
| `04043f2` | Sin prefijo de Source no consumido | Reduce trabajo de preparación sin cambiar ningún artefacto. |

La referencia de rendimiento real disponible antes de esta parada fue un trabajo
histórico de 100 fotogramas, 8 muestras temporales, Device ARRI a 3840×2160 y salida
WIP ProRes a 1920×1080. Su media medida sigue alrededor de **17.6–17.7 s/fotograma**;
la mejora respecto al valor inicial observado de aproximadamente 21–22 s/fotograma
es real, pero aún insuficiente. Las últimas fusiones de dispatch redujeron overhead
de comandos y no produjeron una mejora apreciable de ese caso: el coste dominante
sigue siendo la óptica espacial repetida por muestra.

## Validación ya ejecutada sobre la serie cerrada

- `cargo test -p screen-platform -- --nocapture`: 48 pruebas correctas.
- Paridad de kernel temporal fusionado frente a ejecución ordenada: desviación máxima
  cero en los casos animados cubiertos.
- Paridad CPU/Metal de Uniformity: desviación máxima `0.0000028014183`.
- El máximo observado del conjunto CPU/Metal de óptica completa fue
  `0.000016212463`, dentro de la tolerancia contractual.
- La validación de arquitectura pasó.
- La app fue compilada y empaquetada en `dist/Screen Simulation Native.app` tras la
  fase temporal fusionada. La última modificación descrita abajo todavía no se ha
  compilado, probado, empaquetado ni incluido en un commit.

## Estado pendiente exacto — no cerrado

Además de este documento de handoff, el árbol de trabajo contiene una única
modificación de implementación no comprometida:

```text
crates/screen-platform/shaders/physical_pipeline.metal
```

Añade `PhysicalAreaSamplePair` y `area_sample_pair(...)`. Es una ayuda sin conexiones
desde el kernel: integra dos texturas con los mismos límites de Device en una sola
recorrida de filas, leyendo ambos prefijos y conservando una suma independiente para
cada textura. No se ha cambiado ninguna llamada existente a `area_sample(...)`.

Por tanto el comportamiento efectivo de la aplicación todavía corresponde exactamente
a `04043f2`; el helper no se invoca y no puede producir mejora ni regresión por sí
solo.

## Siguiente fase propuesta

Terminar la optimización de integración doble **sin cambiar la matemática**:

1. En `evaluate_physical_pipeline_pixel`, sustituir únicamente los pares de
   integrales centrales con límites idénticos:
   - `device_signal` + `native_emission_signal`;
   - el par equivalente del detalle carrier cuando ese término está activo.
2. Mantener las rutas individuales cuando sólo se necesita una de las dos señales.
   No emparejar el muestreo de matte ni los taps desplazados de spread/glow: sus
   límites no son el mismo artefacto ni siempre coinciden.
3. Preservar el orden de acumulación de cada señal, los límites, cobertura de panel,
   EOTF, alpha y todas las condiciones de etapa tal como están.
4. Compilar Metal, ejecutar como mínimo la paridad CPU/Metal espacial y las pruebas
   temporal fusionada/animada, después `scripts/check_architecture.py` y
   `git diff --check`.
5. Medir el mismo trabajo real. Si no reduce el tiempo de forma material, conservar
   sólo el resultado si simplifica trabajo demostrablemente; de otro modo revertir
   únicamente esta ayuda no comprometida y documentar el resultado. No afirmar una
   mejora por reducción teórica de lecturas.
6. Si pasa, crear un commit independiente y empaquetar de nuevo.

## Qué investigar después, antes de una aproximación

La auditoría independiente localizó el coste principal en la óptica espacial repetida
para cada una de las ocho muestras temporales: rayos, integración de entorno GGX,
proyección/footprint, estructura de panel y óptica. Antes de pasar a una ruta 2D, la
siguiente investigación debe ser una optimización exacta y medible de invariantes de
GGX/entorno dentro de la muestra espacial. Debe demostrar paridad y no asumir que el
compilador mueve esas invariantes automáticamente.

No están autorizadas todavía estas alternativas: bajar muestras de GGX o PSF, reducir
muestras temporales, reutilizar una imagen espacial de una cámara/Device animados, o
una aproximación 2D para sustituir la ruta física. Requieren una decisión de producto
y comparación explícita de desviación visual y numérica.

## Disciplina para retomar

- Leer `AGENTS.md`, `Docs/architecture/README.md` y el owner
  `native.compute-boundary` antes de editar.
- Trabajar una fase por commit: implementar, comparar con el oracle, medir el render
  real, documentar desviación y sólo entonces avanzar.
- Mantener el queue cancelable: el stripe de 128 filas sigue siendo el límite lógico
  de progreso/cancelación aunque el dispatch abarque su anchura completa.
- No descartar ni sobrescribir el helper pendiente con comandos de restauración. Se
  debe integrar o retirar mediante un cambio explícito y revisable.

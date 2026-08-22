# Handoff — Entrega editorial Device Core + Spill v1

## Objetivo

Añadir a la aplicación un nuevo tipo de entrega editorial formado por dos archivos ProRes sincronizados:

1. **Core / Occlusion**: RGB del dispositivo con alpha convencional para componer mediante `Over`.
2. **Spill / Additive**: contribución RGB restante sobre negro para componer mediante `Add`.

La combinación de ambos debe reconstruir el resultado físico actual de la aplicación:

```text
Resultado = DeviceRGB + PlateRGB × (1 − Matte)
```

El plate no se incluye en ninguno de los archivos.

Este formato es una entrega derivada. No modifica el modelo físico, el checkpoint canónico `DeviceRGB + Matte` ni el Fusion Scene Package.

## Contrato matemático

Entradas canónicas en ACEScg lineal:

```text
D = DeviceRGB
A = Matte de oclusión, entre 0 y 1
P = PlateRGB
```

Resultado actual de referencia:

```text
C = D + P × (1 − A)
```

### Archivo 1: Core

Alpha:

```text
Core.A = A
```

RGB straight:

```text
Core.RGB = D, cuando A > 0
Core.RGB = 0, cuando A = 0
```

Interpretación obligatoria:

```text
Alpha association: Straight
Operación: Over
```

Después del `Over`:

```text
Core over P = D × A + P × (1 − A)
```

La puesta a cero cuando `A = 0` evita RGB oculto en un archivo que editorial entenderá como alpha convencional. No se debe utilizar un epsilon ni un umbral configurable.

### Archivo 2: Spill

```text
Spill.RGB = D × (1 − A)
Spill.A   = 1
```

Interpretación obligatoria:

```text
Operación: Add
Alpha: Opaque
Fondo: Black
```

El alpha debe ser `1`, no `0`. Muchos decodificadores, caches y aplicaciones descartan o alteran el RGB cuando el alpha es cero.

### Reconstrucción

```text
Over(Core, P) + Spill
=
D × A + P × (1 − A) + D × (1 − A)
=
D + P × (1 − A)
```

La fórmula también es válida para mattes degradados.

## Orden obligatorio de procesamiento

La separación debe realizarse en **ACEScg scene-linear**, antes de cualquier conversión de entrega:

```text
Checkpoint DeviceRGB + Matte
          │
          ├── CoreRGB = A > 0 ? D : 0
          │   CoreA   = A
          │
          └── SpillRGB = D × (1 − A)
              SpillA   = 1
```

Después, cada RGB se transforma independientemente:

```text
ACEScg lineal
→ VFX Log/Gamut seleccionado
→ ProRes 4444 o ProRes 4444 XQ
```

El alpha no atraviesa ninguna transformación de color.

No aplicar:

- Display transform.
- View transform.
- ODT Rec.709, P3, HDR o ACES.
- Tone mapping.
- Gamut compression de visualización.
- Clamp a `0–1`.
- Premultiplicación antes de la transformación Log/Gamut.

Los valores negativos y superiores a `1` se conservan hasta donde lo permita el formato y su codificación.

## Formatos admitidos

El selector de codec debe ofrecer solamente:

- ProRes 4444.
- ProRes 4444 XQ.

Ambos archivos de una entrega deben compartir:

- Codec.
- Resolución.
- Pixel aspect.
- Frame rate racional.
- Rango de fotogramas.
- Timecode.
- VFX Log/Gamut encoding.
- Metadatos de color.
- Duración.

Se debe reutilizar el catálogo existente `StudioVFXInterchangeEncoding.catalog`. No crear nombres ni identificadores alternativos de Log/Gamut.

ACEScg y ACES2065-1 continúan siendo interpretaciones exclusivas de OpenEXR. Un ProRes nunca debe etiquetarse como ACEScg.

## Interfaz propuesta

Nuevo tipo de salida:

```text
Pases editoriales Device
```

Controles visibles:

```text
Codec:
  - ProRes 4444
  - ProRes 4444 XQ

Codificación VFX:
  - Selector existente de Log/Gamut
```

Información fija mostrada, pero no editable:

```text
Core: Straight Alpha · Over
Spill: Opaque · Add
Working space: ACEScg scene-linear
Display transform: None
Plate included: No
```

No mostrar selectores de:

- Display.
- View.
- Peak nits.
- Rec.709.
- Alpha premultiplicado/straight.
- Operación de composición.

Las asociaciones y operaciones forman parte del contrato; no son preferencias del usuario.

## Paquete de salida

```text
<nombre>_EditorialDevicePasses/
├── <nombre>_core.mov
├── <nombre>_spill.mov
├── delivery.json
└── README_CONFORM.txt
```

Los dos vídeos son la entrega visual. El manifiesto y las instrucciones evitan que editorial tenga que adivinar espacios de color, alpha u orden de composición.

### Manifiesto mínimo

```json
{
  "schemaVersion": 1,
  "contractId": "editorial-device-passes-v1",
  "sourceColorSpace": "ACEScg",
  "sourceTransfer": "scene-linear",
  "displayTransformApplied": false,
  "codec": "prores-4444-xq",
  "vfxInterchangeEncodingId": "<stable-catalog-id>",
  "frameRate": {
    "numerator": 24000,
    "denominator": 1001
  },
  "raster": {
    "width": 3840,
    "height": 2160,
    "pixelAspectNumerator": 1,
    "pixelAspectDenominator": 1
  },
  "core": {
    "file": "<nombre>_core.mov",
    "alphaAssociation": "straight",
    "operation": "over",
    "rgb": "A > 0 ? DeviceRGB : 0",
    "alpha": "Matte"
  },
  "spill": {
    "file": "<nombre>_spill.mov",
    "alphaAssociation": "opaque",
    "operation": "add",
    "rgb": "DeviceRGB * (1 - Matte)",
    "alpha": "1"
  },
  "reconstruction": "over(core, plate) + spill"
}
```

El manifiesto debe incluir también el rango de frames, el timecode inicial y hashes si el sistema actual de paquetes los soporta.

Los datos obligatorios ausentes, desconocidos o incompatibles deben producir un error explícito. No se debe inferir Rec.709 ni seleccionar automáticamente otra codificación.

## Instrucciones entregadas a conform

Contenido recomendado para `README_CONFORM.txt`:

```text
EDITORIAL DEVICE PASSES — CONFORM

1. Interpretar CORE y SPILL con la codificación Log/Gamut indicada
   en delivery.json.

2. Convertir ambos al espacio scene-linear de composición del proyecto.

3. Componer:
      CORE Over PLATE

4. Añadir:
      SPILL Add resultado anterior

5. Aplicar el output/display transform del proyecto únicamente después
   de la composición.

CORE:
- Straight alpha
- Operación Over

SPILL:
- Alpha opaco
- Operación Add
- No utilizar Over, Screen ni Plus en espacio de display

No se ha aplicado ninguna ODT ni transformación de display.
Los archivos no deben interpretarse automáticamente como Rec.709.
```

En Resolve Color Managed o ACES, los dos archivos deben recibir el mismo Input Color Space correspondiente al Log/Gamut elegido. El `Add` tiene que suceder en el espacio lineal común del proyecto.

## Integración arquitectónica

Esta decisión necesita un propietario registrado. Propuesta:

```text
Decision id: output.editorial-device-passes
Scope: generación y conformado de la entrega Core + Spill
Canonical owner: Docs/architecture/current_system.md
Anchor sugerido: Editorial Device pass delivery
```

En la misma revisión deben actualizarse:

- `architecture/decision-authority.json`.
- El propietario canónico en `current_system.md`.
- Las referencias marcadas necesarias.
- Los contratos de salida.
- La implementación.
- La validación enfocada.

No reutilizar ni ampliar semánticamente `output.fusion-scene-package`. Debe ser un nuevo output explícito, por ejemplo:

```swift
case editorialDevicePasses
```

El empaquetador consume una única evaluación aceptada de `DeviceRGB + Matte` y genera los dos derivados. No debe volver a evaluar el modelo por separado para cada archivo.

Archivos probablemente implicados:

- `StudioMedia/OutputContracts.swift`.
- `StudioColorContracts.swift`, reutilizando el catálogo existente.
- `WorkspaceModel.swift`.
- `ContentView.swift`.
- `NativeOutputRenderer.swift`.
- Adaptador AVFoundation.
- Tests de contratos y encoding.

## Validación requerida

### Pruebas algebraicas

Probar al menos:

```text
A = 0
A = 0.25
A = 0.5
A = 1
```

Con `D` que incluya:

- Valores negativos.
- Valores entre `0–1`.
- Valores superiores a `1`.
- RGB no neutro.

Verificar en ACEScg lineal:

```text
Over(Core, Plate) + Spill
≈
D + Plate × (1 − A)
```

### Pruebas del codec

Decodificar los dos ProRes, aplicar la transformación inversa del Log/Gamut y comparar en ACEScg lineal.

La comparación debe utilizar una tolerancia documentada para ProRes, no igualdad bit a bit.

Cubrir:

- ProRes 4444.
- ProRes 4444 XQ.
- Alpha degradado.
- `Core.RGB = 0` exactamente donde `A = 0`, antes del encoding.
- `Spill.A = 1`.
- Spill negro donde no existe contribución.
- Valores negativos y superiores a uno.
- Coincidencia temporal y de raster.
- Ausencia de ODT.
- Persistencia exacta del ID Log/Gamut.
- Rechazo de encoding ausente o desconocido.
- Escritura completa y atómica del paquete.
- Una colisión de nombre no puede borrar archivos ajenos.

### Prueba visual de aceptación

Componer los archivos entregados sobre:

- Negro.
- Blanco.
- Gris medio.
- El plate original.
- Un plate de color saturado.

Comparar contra el resultado directo de la aplicación después de aplicar en ambos casos el mismo display transform.

La entrega se considera válida cuando las diferencias permanecen dentro de la tolerancia del round-trip ProRes y no aparecen halos, dobles contribuciones, pérdida de spill ni cambios indebidos al sustituir el plate.

## Criterio final de aceptación

El contrato queda cumplido si editorial puede hacer únicamente:

```text
Core Over Plate
Spill Add resultado
Output Transform
```

y obtiene la misma imagen que la aplicación, sin conocer la física interna, sin acceder al EXR y sin compensaciones manuales de exposición, gamma, premultiplicación o color.

# Validación VFX iPhone ↔ ASUS

La autoridad ejecutable de la comparación actual es
`iphone-asus-current.json`. El diagnóstico no acepta ajustes físicos sueltos
desde el entorno: carga el fixture completo, rechaza campos desconocidos y
comprueba por SHA-256 cada recurso antes de renderizar.

El fixture actual fija:

- ASUS PA329CV, 3840×2160, sRGB, 120 cd/m² y patrón VFX 6 a escala 1:1.
- Cámara a 0,11 m, órbita X 0°, órbita Y 12° y objetivo desplazado
  −0,06424 m en X y +0,06074 m en Y.
- iPhone 16e, 5712×4284, lente integrada de 4,2 mm, VFX 2D DOF,
  foco 0,11 m y f/1,64.
- 1/25 s, EI 200, ND 0, revelado 0 EV y ocho exposiciones separadas 1 EV.
- Cristal `cover-matte-ar` completamente materializado en el fixture, con
  roughness GGX 0,18, haze 0,03 y visibilidad celular reflectante de
  irregularidad RMS 0,030 a 60 µm, sin perturbación de normal ni relieve en la
  emisión del panel.
- HDRI sintético mixed-light, Linear Rec.709, 100 cd/m² por unidad y −1 EV.
  El recurso permanente incorpora una rotación de −25° sobre X y el entorno
  aplica −57,3° sobre Y. La luz de techo entre los dos cuadros queda en el
  cuadrante superior derecho.
- Checkpoint acumulativo `developed-acescg` y PNG de salida de 16 bits.

## Ejecución repetible

El HDRI permanente debe existir bajo el root explícito indicado al runner:

```text
<resource-root>/hdr-environments/rustic_mixed_light_hdri_4k-rx-minus25.exr
```

Ejemplo:

```bash
python3 scripts/run_vfx_reference.py \
  --fixture validation/vfx/iphone-asus-current.json \
  --resource-root /Users/jorgetorrenslage/.codex/visualizations/2026/08/10/019fec62-f755-74f1-869d-04f82107b943 \
  --output-dir /ruta/nueva/para/la/prueba
```

Cada salida contiene el PNG16 y `resolved-settings.json`. Este último conserva
el fixture, su hash, los recursos resueltos, el Device, el pipeline y todos los
controles que realmente recibió el evaluador.

## Variaciones y aceptación

Una prueba que cambie un parámetro usa un fixture completo nuevo; no se admiten
overrides de línea de comandos ni herencia parcial. El fixture candidato debe
nombrar el parámetro en su descripción. Si se acepta, sustituye íntegramente a
`iphone-asus-current.json`, se actualiza este documento y se elimina el fixture
candidato. `acceptedOutput` contiene los hashes RGBA8 y RGBA16 del resultado
aceptado.

Así, el repositorio solo describe el ajuste vigente y no conserva valores
anteriores que puedan volver a seleccionarse accidentalmente.

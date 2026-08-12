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
- Cristal `cover-matte-ar` completamente materializado en el fixture;
  su rugosidad actual es 0,65 y su haze 0,03.
- HDRI sintético mixed-light, Linear Rec.709, 100 cd/m² por unidad, −3 EV
  y rotación horizontal 12°. El centro útil del panorama es la región que
  debe reflejarse en esta pose.
- Checkpoint acumulativo `developed-acescg` y PNG de salida de 16 bits.

## Ejecución repetible

El HDRI permanente debe existir bajo el root explícito indicado al runner:

```text
<resource-root>/hdr-environments/rustic_mixed_light_hdri_4k.exr
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
candidato. `acceptedOutput` permanece `null` mientras el resultado no haya sido
aceptado visualmente; al aceptarlo contiene los hashes RGBA8 y RGBA16 actuales.

Así, el repositorio solo describe el ajuste vigente y no conserva valores
anteriores que puedan volver a seleccionarse accidentalmente.

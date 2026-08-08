# Handoff autoritativo — Screen Simulation

Fecha de corte: **2026-08-08**  
Producto activo: **Screen Simulation Native (macOS)**  
Estado del handoff: **discusión y decisión; no ejecución**

---

## 0. Instrucción obligatoria para el nuevo chat

> **DETENTE ANTES DE IMPLEMENTAR.**
>
> Este documento sirve para continuar la conversación en un chat nuevo. La
> primera fase en ese chat es exclusivamente revisar el estado, discutir las
> prioridades y acordar con el usuario el siguiente corte. No se debe editar
> código, modificar contratos, crear ramas o tareas, compilar, empaquetar,
> ejecutar migraciones, hacer commits ni hacer push hasta que el usuario diga
> explícitamente **«implementa»**, **«hazlo»** o una autorización equivalente.
>
> Los comentarios, dudas y propuestas del usuario son material de discusión; no
> son órdenes de ejecución. Esta regla tiene precedencia sobre la costumbre de
> avanzar autónomamente.

Se permite únicamente inspección no destructiva necesaria para orientarse:

- leer este handoff y los documentos marcados como vigentes;
- consultar `git status`, `git log`, ramas y diffs sin alterarlos;
- leer código, tests y resultados ya existentes;
- devolver un resumen de comprensión, opciones y decisiones pendientes.

No se debe comenzar una auditoría nueva ni abrir otro chat/subagente sin que el
usuario lo solicite expresamente.

### Texto recomendado para iniciar el nuevo chat

```text
Lee completamente Docs/HANDOFF_SCREEN_SIMULATION_2026-08-08.md.
No implementes ni modifiques nada todavía. Comprueba solo en lectura el estado
actual, resume lo que entiendes y discutimos qué corte abordar primero. Espera
a que yo diga explícitamente «implementa» antes de ejecutar cambios.
```

---

## 1. Objetivo del producto

Screen Simulation simula cómo una pantalla física que reproduce una imagen o
vídeo es observada y registrada por una cámara. El objetivo no es un modelo
académico espectral perfecto, sino una aproximación física convincente y útil
para VFX que reproduzca de forma creíble:

- emisión y estructura de píxel/subpíxel;
- black matrix, fill factor, trama, aliasing y moiré;
- contaminación óptica entre píxeles (`Panel Light Spread`);
- comportamiento temporal de la pantalla;
- cristal y reflejos del entorno;
- geometría pantalla-cámara;
- lente, foco, profundidad de campo, distorsión y aberración cromática;
- exposición, obturación global/rolling y movimiento;
- sensor, CFA, ruido, RAW, demosaic, balance de blancos y revelado;
- salida desarrollada lineal ACEScg, antes de preview/output.

El resultado debe ser práctico para composición, con Draft fluido para
navegación/animación y calidades Media, Alta y Nativa para evaluación o salida.

El producto es **Mac-first**. Windows queda aplazado. La arquitectura debe seguir
permitiendo un futuro adaptador OFX sin convertirlo ahora en otro producto ni
crear rutas paralelas.

---

## 2. Reglas de colaboración y arquitectura

### 2.1 Forma de trabajar con el usuario

1. Primero se discute y afina una propuesta.
2. Solo se implementa tras autorización explícita.
3. Al terminar cualquier tarea se entrega siempre una lista concreta de cosas
   que el usuario debe revisar visual o funcionalmente.
4. No se declaran cerradas verificaciones visuales que no hayan podido hacerse.
5. No se amplía el alcance por iniciativa propia cuando implique otra decisión
   de producto.

### 2.2 Política de cambios

- Una sola versión vigente de cada contrato.
- Migraciones atómicas, sin fallback, sin lector legacy permanente y sin rutas
  paralelas.
- Durante desarrollo se aceptan cambios de resultado: no se conserva
  compatibilidad visual con versiones anteriores.
- Una ruptura actualiza contrato, modelos, fixtures, tests, UI y documentación
  como un único corte.
- Lo obsoleto se retira de documentación activa y se mueve a `Old` solo cuando
  sea necesario conservarlo como archivo; no debe seguir disponible como
  contexto operativo confuso.
- Un preset es una plantilla de autoría. Al seleccionarlo se materializan sus
  valores; el render no consulta dinámicamente el preset después.
- Los presets son globales. El proyecto o trabajo guarda los valores resueltos
  que usa, no rutas o referencias frágiles a una versión del preset.

### 2.3 Propiedad por dominio

- **Rust + Metal:** física, unidades, evaluación, CPU oracle, diagnósticos y ABI.
- **SwiftUI/AppKit:** shell nativo, autoría, orquestación, presentación y estado.
- **StudioColor:** interpretación de color, ACES/OCIO, transforms y publicación.
- **AVFoundation/VideoToolbox/ImageIO:** I/O nativo macOS.
- **StudioVideoOutput:** salida DeckLink compartida con CREDITOS-HDR.

La app nativa no puede introducir física Swift, shaders Swift paralelos,
fallback CPU de producto ni otra implementación de color.

### 2.4 Prohibiciones explícitas

- No FFmpeg/libav en el grafo, bundle o binario nativo.
- No usar el checkout de CREDITOS-HDR como dependencia por ruta.
- No duplicar StudioColor ni StudioVideoOutput dentro de otra app.
- No hacer que una ODT de preview altere la captura física.
- No simular emisión sobre el entorno con un halo 2D de postproducción.
- No crear dos modos internos para Look At/free camera que diverjan en física.
- No reactivar la app Slint antigua como fallback.

---

## 3. Repositorio, rama y aplicación exactos

### 3.1 Worktree autoritativo actual

```text
/Users/jorgetorrenslage/Documents/Codex/2026-08-06/
screen-simulation-macos-native/work/screen-simulation-radiometric
```

### 3.2 Git

```text
Rama: feature/radiometric-calibration
HEAD: 2d1e9f7020b270c24a58672ecfefd6a0bedc38d9
Commit: fix(camera): restore look-at orbit controls
Remoto: origin/feature/radiometric-calibration en el mismo SHA
Estado al escribir este handoff: limpio
```

La rama `feature/native-macos-shell` permanece en `f8702d7` y es una base
anterior. **No continuar desde ella** salvo decisión expresa; faltan allí todos
los cortes radiométricos y de UX posteriores.

### 3.3 Bundle que debe probarse

```text
/Users/jorgetorrenslage/Documents/Codex/2026-08-06/
screen-simulation-macos-native/work/screen-simulation-radiometric/
dist/Screen Simulation Native.app
```

Antes de una futura prueba, confirmar que el bundle se ha reconstruido desde el
HEAD acordado. No asumir que una instancia abierta corresponde al último commit.

### 3.4 Ubicación futura

El usuario había propuesto concentrar el proyecto en `/Volumes/SD_02/PROYECTOS`,
pero el desarrollo nativo actual vive en el worktree anterior. No mover ni
duplicar el repositorio hasta decidir en el nuevo chat el corte de traslado. Un
traslado debe mantener una sola autoridad y actualizar el proyecto de Codex.

---

## 4. Estado operativo de tareas/agentes

Al generar este handoff, el árbol real de colaboración solo contiene al agente
raíz activo. Las siete entradas que la interfaz mostró como «Trabajando»
(`Calibration handoff`, `Calibration radiometrica`, `Auditoria fisica`, etc.)
son estados visuales antiguos, no siete agentes ejecutando trabajo actual.

No hay que esperar sus resultados ni continuar esas tareas. Sus conclusiones
útiles ya están integradas en código o documentos.

---

## 5. Arquitectura física vigente

La ruta única actual es:

```text
media / patrón sintético
  → decode nativo e interpretación explícita
    (matriz YUV, rango, IDT y alpha independientes)
  → Source ACEScg lineal
  → StudioColor Source-to-Device
  → Device Signal no lineal
  → ABI física v2 Rust/Metal
      1. Emission
      2. Subpixel Geometry
      3. Panel Light Spread
      4. Temporal Emission
      5. Cover Glass
      6. Environment Reflection
      7. Camera/Screen Geometry
      8. Lens
      9. Global/Rolling Shutter + Motion
     10. Sensor + CFA + Noise
     11. RAW + Demosaic + White Balance + Develop
  → Developed ACEScg lineal e inmutable
  ├→ Preview ODT + ColorSync/perfil de monitor
  ├→ Render/output ODT
  └→ DeckLink ODT independiente
```

El ABI vigente es exclusivamente `SCREEN_PHYSICAL_FRAME_ABI_VERSION 2` y el
único entry point de producto es `screen_physical_frame_submit`. No hay ABI v1,
adaptador, selector de backend, física Swift ni fallback.

El input opaco contiene de forma tipada:

- textura Source ACEScg;
- textura Device Signal resuelta por StudioColor;
- placement explícito `Fit`, `FillCrop`, `Stretch` o `OneToOne`;
- muestras temporales y tracks de pose cuando corresponda;
- snapshot completo e inmutable de los modelos físicos.

Los diagnósticos/intermedios permiten observar Source, Device Signal, Emission,
Subpixel, Spread, RAW, Developed y los grupos físicos conectados. Los tiempos
Metal de etapas fusionadas se reportan como grupo; no se inventa un reparto.

---

## 6. Color, media y output ya resueltos

### 6.1 Color

- El working space físico es ACEScg lineal.
- ACES SDR y DaVinci Color Managed SDR son contratos diferentes.
- Media display-referred Rec.709 para roundtrip ACES usa el Inverse Display
  exacto `Display - Rec.709 (ACES 2.0 SDR)` antes de ACEScg.
- DCM Rec.709 Gamma 2.4 representa el handoff DCM/DWG correspondiente y no se
  trata como ACES SDR.
- Matriz YUV, rango, IDT y asociación alpha son decisiones independientes.
- `Ignore / Opaque` es una interpretación alpha explícita; no se autoelige.
- Preview ODT se aplica solo después de Developed ACEScg.
- El perfil ICC/ColorSync del monitor pertenece a publicación, no a la física.
- Preview y render/DeckLink pueden tener ODT distintas sin recalcular captura.

### 6.2 I/O nativo

- AVFoundation/VideoToolbox/ImageIO son la única ruta I/O nativa.
- ProRes, H.264/H.265, stills y EXR tienen contratos y pruebas de identidad o
  tolerancia documentados.
- Existe un gate que rechaza FFmpeg/libav en source graph, Mach-O, rpaths,
  símbolos, strings y recursos del bundle.
- El último rendimiento documentado del golden ProRes real fue suficiente para
  reproducción interactiva en el tamaño probado; no reabrir el decoder sin un
  fallo reproducible actual.

### 6.3 Outputs

- Los presets de render heredan el modelo de CREDITOS-HDR: formato, codec, ODT,
  peak, rango legal/full y notas de uso editables como valores resueltos.
- DeckLink usa `StudioVideoOutput` compartido y una ODT independiente.
- La app no dispone del hardware DeckLink en estas pruebas: solo se verificó
  contrato/build/error explícito, nunca éxito simulado.
- `Save current frame`/`Guardar frame` produce PNG de chequeo con la
  transformación seleccionada y metadata física estructurada.
- Importar settings desde PNG aplica los campos físicos compatibles y conserva
  ODT y calidad actuales.

---

## 7. Modelos físicos ya migrados y conectados

No repetir esta migración. El trabajo físico anterior se reutilizó dentro de la
ruta Rust/Metal única.

| Fase | Estado actual |
|---|---|
| Emisión | Conectada; EOTF, negro/blanco, colorimetría y respuesta angular |
| Geometría subpíxel | Conectada; RGB/BGR, pitch, fill y black matrix |
| Panel Light Spread | Conectada; bloom/contaminación óptica del panel |
| Temporal | Conectada; flicker residual y banding creativo separado |
| Cristal | Conectado; transmisión, Fresnel, absorción, AR, roughness, haze |
| Entorno HDR | Conectado; HDR sintético en ACEScg lineal |
| Geometría cámara-pantalla | Conectada; pose, proyección y escala física |
| Lente | Conectada; foco, apertura, distorsión, CA, viñeta y PSF |
| Shutter/motion | Conectado; global/rolling, tiempos racionales, filas y motion |
| Sensor/CFA/ruido | Conectado; well, ADC, clipping y ruido determinista |
| RAW/develop | Conectado; demosaic, WB, EI/exposición, tint/temperatura y ACEScg |

Semántica de contribución:

- `0`: identidad/bypass del modelo correspondiente;
- `1`: modelo físico calibrado;
- `>1`: extrapolación artística de la misma operación, dentro del límite seguro;
- un toggle permite bypass temporal conservando el valor almacenado;
- CFA y Develop son operaciones discretas, no amounts continuos falsos.

### 7.1 Corrección radiométrica integrada

Cada cámara tiene una `CameraRadiometricCalibration` obligatoria. La frontera
panel-sensor usa explícitamente:

```text
L_panel [cd/m²]
× π / (4 × T-stop²)
× shutter [s]
× 2^(-ND)
× C_camera
```

`C_camera` expresa la calibración efectiva del sensor cuando los fabricantes no
publican QE, microlentes, transmisión de stack y ganancia analógica completas.
No es un ajuste de preview ni un segundo multiplicador de lente.

Pruebas vigentes verifican:

- blancos de 100, 350, 625 y 1000 nit;
- ±1 stop en shutter e EI/ISO;
- ND;
- Emission, RAW y Developed por separado;
- monotonía y clipping;
- todos los presets de cámara presentes.

Resultado actual documentado:

- ARRI ALEXA 35 conserva margen medible hasta 1000 nit en el fixture.
- iPhone 16e con lente rápida y los settings ensayados satura ya con 100 nit.
  Esto es físicamente plausible: una captura móvil necesita menor exposición,
  menor gain o procesamiento computacional para proteger highlights.
- Developed ACEScg puede ser mayor que 1; no es un código display.
- Una vez clipeado el sensor, ninguna ODT recupera la información.

El informe reproducible es `Docs/RADIOMETRIC_PATCH_VALIDATION.md`.

### 7.2 Corrección angular de cristal y entorno

Ya está integrada la corrección P0 que faltaba:

- Fresnel usa el ángulo real del rayo;
- Beer/transmisión usa el ángulo refractado;
- el HDR se consulta con la dirección de reflexión real;
- CPU y Metal tienen tests de paridad.

No volver a tratar el cristal como incidencia frontal fija ni el HDR como una
dirección constante.

### 7.3 Qué no pretende todavía el modelo

- física espectral completa;
- polarización o thin-film interference;
- multi-bounce interno del cristal;
- computational photography del iPhone;
- sensor bloom/crosstalk avanzado;
- iluminación de objetos externos por la pantalla;
- CRT, OLED o MicroLED bajo el evaluador LCD actual.

---

## 8. UX/UI nativa actual

La app usa controles/vistas nativas de macOS y sigue el lenguaje general de
CREDITOS-HDR.

### 8.1 Navegación

- Páginas inferiores con icono y nombre: Principal, Modelo, Settings.
- Ámbar indica selección/acento de UI.
- Azul se reserva para estado operativo activo, por ejemplo Play o DeckLink.
- Settings tiene sidebar redimensionable con Aplicación, Biblioteca y Monitor.
- Biblioteca contiene patrones/imágenes, presets de render, devices y cover
  glass con CRUD nativo; los presets sembrados pueden desbloquearse/duplicarse.

### 8.2 Página Modelo

- Inspector izquierdo redimensionable y preview compartido a la derecha.
- Tabs actuales: General, Pantalla y Captura.
- Cards expandibles en orden físico.
- Cabecera de cada card: toggle o enable, nombre, amount y resumen del efecto.
- Al expandir: todos los parámetros autorables, unidades, control, input y
  restauración individual al preset.
- Los inputs numéricos se editan como texto temporal y solo hacen commit cuando
  la entrada es válida; admiten signo, decimales y selección interna.
- Sliders sin ticks, pasos razonables y detente en `1` físico.
- Círculos de preparación para futura animación aparecen junto a valores
  autorables, pero la página de animación aún no está implementada.
- Sección de diagnóstico muestra estados físicos; confirmar en QA si todos los
  warnings/errores son seleccionables y copiables como pidió el usuario.

### 8.3 Cámara y Look At

El último corte `2d1e9f7` restaura el comportamiento solicitado:

- `Look At ON`: el target es interno y oculto, situado en el centro físico de la
  pantalla; se editan posición XYZ de cámara y rotaciones X/Y/Z;
- X/Y orbitan alrededor del target manteniendo radio/distancia;
- Z conserva roll;
- mover cámara o pantalla recalcula orientación sin abrir otra ruta física;
- `Look At OFF`: rotación XYZ libre.

La transformación de pantalla pertenece a Pantalla; la cámara a Captura.

Este comportamiento está automatizado, pero todavía requiere revisión humana
tras el último rebuild.

### 8.4 Preview

- Calidades Draft, Media, Alta y Nativa.
- Fit y 1:1, campo de porcentaje editable y pan.
- Nativa es explícita, cancelable y conserva/stalea el resultado anterior.
- El zoom/pan fue corregido en `5046c41`, `434e1fc` y commits relacionados para
  anclar al cursor y permitir pan simétrico.
- Cambiar únicamente zoom/pan no debe invalidar ni recalcular la física.
- El viewport debe mostrar la proporción efectiva del sensor de captura.
- Timeline/transporte de la fuente permanece visible aunque no haya keyframes
  físicos; la fuente animada debe poder navegarse y reproducirse.

Como hubo varias regresiones visuales, no dar por cerrado zoom/pan solo por los
tests: hacer QA manual antes del próximo corte funcional.

---

## 9. Evidencia de validación disponible

En los hitos inmediatamente anteriores se reportaron:

- Rust workspace: 199 tests antes de la ampliación radiométrica.
- Corte radiométrico: 59 application, 8 conformance, 8 bridge y 30 platform.
- Swift llegó posteriormente a 68 tests en los cortes de UX/cámara.
- `cargo fmt`, `clippy -D warnings`, arquitectura y `git diff --check`: verdes.
- ABI v2 gate: verde.
- gate no-FFmpeg: verde.
- Release empaquetada y `codesign --deep --strict`: verde.

Estas cifras corresponden a distintos commits sucesivos. Antes de declarar un
nuevo release, ejecutar el conjunto completo en el HEAD elegido y registrar una
sola tabla final, sin sumar resultados históricos como si fueran una misma run.

Benchmarks físicos previos en M3 Ultra muestran tiempos interactivos incluso en
Native para los devices probados, pero deben repetirse si cambia el kernel o el
contrato radiométrico. No confundir tiempo de física con publicación OCIO.

---

## 10. Referencias suministradas por el usuario

### 10.1 Comparación con la app antigua

```text
/Users/jorgetorrenslage/Desktop/test/screen-simulation-native.png
/Users/jorgetorrenslage/Desktop/test/ScreenSimulation-Nativa-00000000.png
```

La comparación ya mostró encuadre y textura muy similares; la diferencia
principal era luminancia. El usuario aceptó que el modelo nuevo sea más oscuro
si es físicamente más preciso. La app antigua puede retirarse cuando el nuevo
modelo sea creíble; no debe condicionar la física actual ni convertirse en
fallback.

### 10.2 Referencias iPhone de monitor HDR PQ 1000 nit

```text
/tmp/codex-remote-attachments/019fcd48-5f76-7cd2-b2e2-307d745ec42f/
FF1692D3-1002-4CCA-B9A2-2E01F1E979FD/1-Foto-1.jpg

/Users/jorgetorrenslage/Downloads/IMG_3897.HEIC
/Users/jorgetorrenslage/Downloads/IMG_3932.HEIC
/Users/jorgetorrenslage/Downloads/IMG_3935.HEIC
/Users/jorgetorrenslage/Downloads/IMG_3936.HEIC
/Users/jorgetorrenslage/Downloads/IMG_3937.HEIC
/Users/jorgetorrenslage/Downloads/IMG_3938.HEIC
```

El usuario indicó que el monitor era una salida HDR PQ 1000 nit. Estas fotos se
usan **solo para evaluar plausibilidad**, nunca para ajustar la constante del
modelo: se desconoce el valor PQ concreto fotografiado y los HEIC incorporan
procesamiento computacional/local tone mapping.

EXIF ya registrado:

| Archivo | Apertura | Focal | Exposición | ISO |
|---|---:|---:|---:|---:|
| IMG_3932 | f/1.64 | 4.2 mm | 1/60 s | 125 |
| IMG_3935 | f/1.64 | 4.2 mm | 1/82 s | 80 |
| IMG_3936 | f/1.64 | 4.2 mm | 1/76 s | 80 |
| IMG_3937 | f/1.64 | 4.2 mm | 1/48 s | 320 |
| IMG_3938 | f/1.64 | 4.2 mm | 1/60 s | 80 |

La dirección de estos datos coincide con la simulación: presión fuerte sobre
highlights con f/1.64, no una prueba de valores absolutos pixel a pixel.

---

## 11. Pendientes que requieren decisión

No implementar esta lista automáticamente. En el nuevo chat hay que ordenarla
con el usuario y escoger **un solo corte**.

### P0 — revisión inmediata antes de ampliar modelos

#### A. QA humana del último Look At y preview

Comprobar en la app exacta:

1. Look At ON: X/Y orbitan, Z hace roll, el centro de pantalla sigue siendo el
   objetivo oculto y la distancia se mantiene.
2. Mover cámara y pantalla recalcula la orientación esperada.
3. Look At OFF permite rotación XYZ libre.
4. Posiciones de pantalla solo aparecen en Pantalla y cámara en Captura.
5. 1:1 permite alcanzar con pan los cuatro bordes.
6. El anchor permanece bajo el cursor al cambiar zoom.
7. El campo de zoom permite edición completa y no actualiza por cada keystroke.
8. Zoom/pan no marca el render físico como desactualizado ni desplaza la imagen
   a la esquina inferior izquierda.
9. El viewport adopta la proporción/resolución efectiva de ARRI e iPhone.

#### B. Cierre radiométrico práctico

Los tests numéricos ya existen y pasan. Falta decidir qué evidencia necesita el
usuario en UI/flujo real:

- tabla visible o exportable de Emission, RAW, clipping y Developed;
- preset/escena canónica de patches 18 %, 100, 350 y 1000 nit;
- comparación ARRI/iPhone/ASUS sin ODT implicada;
- confirmación visual de que iPhone clipea donde el test predice;
- aclaración UI de T-stop, shutter angle/time, ND, EI/exposure y estado de clip.

No recalibrar contra un HEIC. Si se cambia `C_camera`, exigir una fuente de
medición o un golden físico explícito y actualizar todos los tests.

#### C. Warnings y errores de modelo

El usuario pidió un área permanente donde warnings/errores sean:

- visibles cerca del flujo de trabajo;
- seleccionables y copiables;
- asociados a la fase que falla;
- no mostrados únicamente en un modal genérico;
- diferenciados entre error bloqueante, warning y diagnóstico.

Verificar primero qué parte está ya implementada y cerrar solo lo que falte.

### P1 — siguientes cortes físicos/productivos posibles

#### D. Sensación de pantalla como fuente emisora

Es la preocupación perceptual principal pendiente. Hay dos fenómenos distintos:

1. `Panel Light Spread`: contaminación óptica dentro/de frente a la pantalla;
   ya está implementado.
2. Luz emitida por la pantalla sobre bisel, mesa, pared u objetos próximos;
   no está implementada porque requiere geometría externa/scene renderer.

No resolver el punto 2 con glow/bloom 2D. Decidir si el siguiente hito crea una
escena mínima física (plano/bisel/entorno receptor) o se aplaza hasta la vista
3D completa.

#### E. Nuevos presets de cámara

El usuario propuso:

- una RED moderna;
- una consumer antigua Full HD con más aberración/textura de vídeo.

Antes de implementarlas hay que decidir modelos exactos y fuentes de datos. Una
opción razonable para discutir es RED V-RAPTOR/KOMODO-X y una Canon/Sony/ Panasonic
consumer HD de generación anterior, pero no se debe inventar un perfil. Cada
nueva cámara debe incluir `CameraRadiometricCalibration` y pasar automáticamente
los goldens de stops y clipping.

#### F. HDR environment image-backed

Actualmente hay entornos HDR sintéticos analíticos. Falta decidir:

- importación EXR/HDR latitude-longitude;
- gestión/persistencia en Biblioteca;
- prefiltrado/roughness sin otra ruta de reflexión;
- HDRs open-source opcionales.

Debe entrar por el mismo límite `screen-cover`; nunca crear otro shader de
reflejo.

#### G. Sensor bloom/crosstalk

Es distinto de Panel Light Spread y está explícitamente pendiente. Implementar
solo tras definir si se busca difusión de carga, crosstalk óptico o ambos, y con
un test que no duplique lens bloom/PSF.

### P2 — producto y UX posteriores

#### H. Animación física

- Página de animación/timeline de parámetros.
- Keyframes de los campos marcados con círculo.
- Undo/redo y curvas.
- Tracks de cámara/pantalla ya tienen contrato temporal Rust; falta UX.
- Importadores posteriores: SynthEyes, Fusion y Alembic.

#### I. Vista de escena

- viewport 3D;
- gizmos de cámara/pantalla;
- timeline integrado;
- profundidad de campo y foco manipulables visualmente.

El usuario decidió hacer esto después de cerrar el modelo físico/óptico.

#### J. Stabilization/corner pin/baked device

Flujo futuro: estimar pose desde un frame con pantalla visible, generar la
captura del device estabilizada con distorsiones/moiré baked y recomponer con
corner pin/match move. Es una aproximación aceptable para VFX, pero no pertenece
al corte actual.

#### K. Render queue y outputs

- secuencia/película completa con modelos animados;
- presets globales materializados;
- ODT/codec/rango/peak editables;
- DeckLink con QA de hardware real;
- EXR/ProRes/H.264/H.265 según el contrato ya definido.

#### L. Tecnologías de panel adicionales

LCD es el evaluador actual. OLED, MicroLED y especialmente CRT requieren física
propia; no se implementan renombrando presets LCD.

#### M. Plataforma y extensiones

- OFX futuro como adaptador del mismo core.
- Windows/D3D12 solo cuando la fase Mac esté cerrada.
- posible reutilización de StudioColor y módulos compartidos en CREDITOS-HDR.

---

## 12. Elementos ya cerrados que no deben reabrirse sin evidencia

- Elección Mac-first y shell SwiftUI/AppKit nativo.
- Working space ACEScg.
- StudioColor como única autoridad OCIO/ACES.
- I/O nativo sin FFmpeg.
- StudioVideoOutput compartido para DeckLink.
- ABI física única v2 Rust/Metal.
- Ausencia de física Swift/fallback.
- ProRes 4444 recomendado pero inputs no limitados a ProRes/EXR.
- Alpha Auto/Straight/Premultiplied/Ignore explícito.
- Placements Fit/FillCrop/Stretch/OneToOne.
- Presets globales materializados y CRUD en Settings.
- Contributions 0/1/>1 y bypass no destructivo.
- Cover/HDR angular corregido.
- Calibración radiométrica explícita y goldens por cámara.
- Importar settings PNG conserva ODT y calidad.
- PNG de chequeo, no TIFF, para `Guardar frame`.

Reabrir cualquiera exige un fallo reproducible o una nueva decisión del usuario.

---

## 13. Documentación: vigencia y trampas de contexto

### Leer primero

1. `Docs/HANDOFF_SCREEN_SIMULATION_2026-08-08.md`
2. `Docs/CAPTURE_RADIOMETRIC_CALIBRATION.md`
3. `Docs/RADIOMETRIC_PATCH_VALIDATION.md`
4. `Docs/NATIVE_PHYSICAL_FRAME_CONTRACT.md`
5. `Docs/NATIVE_PHYSICAL_UI_FIELD_MATRIX.md`
6. `Docs/architecture/project_and_change_policy.md`
7. código y tests del HEAD actual.

### Documentos útiles pero potencialmente históricos

- `Docs/NATIVE_PHYSICAL_PARITY_AUDIT.md` describe carencias anteriores a la
  migración completa. **No representa el estado físico actual.**
- `Docs/NATIVE_PHYSICAL_INTEGRATION_REPORT.md` contiene evidencia de un HEAD
  previo y una cifra/test count anterior; usarlo como historia, no como release
  actual.
- `Docs/architecture/current_system.md` mezcla el producto técnico Rust/Slint
  histórico y el candidato nativo. Algunas secciones de composición root están
  desactualizadas respecto al corte nativo actual.
- `Docs/NATIVE_MACOS_CUTOVER.md` debe interpretarse junto al estado Git real.

Regla de autoridad cuando haya conflicto:

```text
HEAD actual + tests ejecutables + ABI/header
  > documentos normativos actualizados
  > informes de integración fechados
  > auditorías históricas
  > capturas o comentarios antiguos
```

Antes de la siguiente implementación conviene decidir una limpieza documental
atómica: actualizar lo vigente y mover informes superados a `Docs/Old`, sin
mantener explicaciones contradictorias accesibles como contexto principal.

---

## 14. Checklist estándar para cualquier tarea futura

Al terminar un corte, el nuevo chat debe entregar al usuario:

### Resultado

- qué cambió y qué no cambió;
- SHA(s), rama y estado del remoto;
- ruta exacta de la app reconstruida;
- limitaciones honestas.

### Gates

- Swift tests;
- Rust workspace tests;
- fmt/clippy;
- arquitectura y diff check;
- ABI v2 gate;
- no-FFmpeg gate;
- Release, bundle y codesign;
- benchmark proporcional al riesgo.

### Lista de revisión humana

Una lista breve y específica, por ejemplo:

1. abrir la app exacta indicada;
2. elegir patrón/device/cámara concretos;
3. modificar los controles afectados;
4. comprobar comportamiento esperado;
5. comprobar undo/restauración/bypass;
6. comparar Draft/Media/Alta/Nativa;
7. exportar PNG si la evaluación visual lo requiere;
8. copiar cualquier warning/error reproducible.

No basta con decir «todo pasa».

---

## 15. Primera conversación recomendada

El nuevo chat debería responder inicialmente, sin ejecutar cambios:

1. confirmar que entiende la regla de **no implementar todavía**;
2. confirmar worktree, rama y HEAD solo mediante inspección read-only;
3. resumir en pocas líneas qué está cerrado;
4. presentar estas tres opciones como siguiente decisión, sin asumir ninguna:
   - QA/cierre de Look At + zoom/pan;
   - cierre radiométrico visible y warnings;
   - diseño de una escena mínima para que la pantalla ilumine su entorno;
5. discutir con el usuario cuál es el corte y sus criterios de aceptación;
6. esperar la palabra **«implementa»**.

El objetivo del nuevo chat no es demostrar actividad, sino conservar todo lo
aprendido, reducir contexto contradictorio y ejecutar un único siguiente paso
bien definido.

# Calibración radiométrica de captura

La frontera Panel → Sensor no acepta nits como si fueran directamente
lux·segundo. Cada preset de cámara declara una `CameraRadiometricCalibration`
obligatoria y trazable. La ancla de referencia es una carta Lambertiana del
18 % bajo una iluminancia conocida.

Para la carta de referencia:

`L = E × rho / pi`  (cd/m²)

Para una pantalla Lambertiana observada por una lente expresada en T-stop:

`E_sensor = pi × L / (4 × T²)`  (lux)

El pipeline aplica una única vez, en la frontera de sensor:

`H_effective = L_panel × pi/(4T²) × shutter × 2^-ND × C_camera`

`C_camera` convierte la exposición física en lux·segundo al dominio efectivo
del perfil de sensor (full well/ADC). Es explícito y calibrable porque QE,
microlentes, transmisión de la pila óptica y ganancia analógica no suelen ser
datos públicos completos. El T-stop ya contiene transmisión de lente: no se
vuelve a aplicar una ganancia de lente ni un multiplicador de preview.

## Contrato de validación

Los goldens de `screen-application` comprueban, antes de clipping:

- panel blanco 100, 350 y 1000 nits;
- un stop de obturación arriba y abajo;
- un stop de ganancia/ISO arriba y abajo;
- ND de dos stops;
- emisión normalizada, RAW y Developed por separado;
- monotonía Developed y ausencia de clipping en el fixture.

La EOTF de entrada se resuelve antes del modelo de pantalla y la ODT de
preview se aplica después de Developed ACEScg. Ninguna de las dos participa
en los ratios radiométricos.

## Límites declarados

La constante efectiva no afirma una calibración absoluta de cada cuerpo sin
medición de laboratorio. Los presets documentan su escena de anclaje y
proveniencia; una medición ISO/grey-card puede sustituir `C_camera` sin crear
una ruta de render distinta.

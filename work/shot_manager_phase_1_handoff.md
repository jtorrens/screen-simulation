# Handoff — Shot Manager · Fase 1

Estado: propuesta funcional para iniciar un proyecto independiente.

## 1. Objetivo

Construir la primera fase de una aplicación web local llamada provisionalmente
**Shot Manager**.

Esta fase crea y administra únicamente:

- una Producción;
- su nombre visible y código corto;
- su número de temporada;
- sus Episodios;
- los Workstreams disponibles en la Producción;
- la estructura inicial de directorios;
- el inventario mínimo de planos;
- un estado manual por plano.

La aplicación todavía no integra, abre ni controla Mockups, Screen Simulation,
SynthEyes o Fusion. Tampoco crea composiciones de Fusion, escanea renders o
prepara paquetes de entrega.

## 2. Unidad raíz: Producción

Aunque el encargo pueda ser una nueva temporada de una serie existente, para
Shot Manager cada encargo se trata como una Producción nueva e independiente.

Ejemplo inicial:

```text
Nombre visible: FOQ · Temporada 2
Código corto:   FOQ2
Temporada:      2
Episodios:      8
```

El código corto es un valor técnico explícito. No se deriva del nombre visible
ni del número de temporada.

Al crear la Producción, el usuario selecciona una carpeta raíz existente. Shot
Manager crea dentro de ella una carpeta cuyo nombre es el código corto:

```text
<raíz seleccionada>/FOQ2/
```

La creación debe rechazar un destino ya existente. No debe abrirlo, mezclarlo,
vaciarlo, repararlo ni sobrescribirlo como parte de `Crear Producción`.

## 3. Episodios

El asistente de creación solicita un número positivo de Episodios. En el caso
inicial se crean ocho.

Los Episodios se materializan como registros ordenados y directorios:

```text
FOQ2/
├── EP01/
├── EP02/
├── EP03/
├── EP04/
├── EP05/
├── EP06/
├── EP07/
└── EP08/
```

Los códigos se generan en esta fase como `EP` más un número con dos dígitos.
Después de crear la Producción, cada Episodio conserva su código
exacto; no se vuelve a calcular a partir de su orden.

El número de Episodios mostrado por la UI se deriva de la colección persistida.
No se guarda un segundo contador independiente.

## 4. Workstreams

Un Workstream representa una zona de trabajo dentro de cada Episodio. En esta
fase no representa dependencias, capacidades, flujos entre aplicaciones ni un
sistema de plugins.

Cada Workstream declara solamente:

```text
id estable
nombre visible
nombre de su carpeta
lista ordenada de subcarpetas
```

Ejemplo de selección para FOQ2:

```text
MOCKUPS
├── WORK
└── RENDERS

SCREEN_SIMULATION
├── WORK
└── RENDERS

SYNTHEYES
├── WORK
└── EXPORTS

REFERENCES
└── SOURCES

FUSION
├── COMPS
└── DELIVERIES
    ├── WIP
    ├── FINAL
    └── GFX
```

Fusion se incluye como Workstream de la estructura, pero en esta fase no tiene
comportamiento especial.

Los Workstreams seleccionados se crean por igual dentro de todos los Episodios:

```text
FOQ2/
└── EP01/
    ├── MOCKUPS/
    │   ├── WORK/
    │   └── RENDERS/
    ├── SCREEN_SIMULATION/
    │   ├── WORK/
    │   └── RENDERS/
    ├── SYNTHEYES/
    │   ├── WORK/
    │   └── EXPORTS/
    ├── REFERENCES/
    │   └── SOURCES/
    └── FUSION/
        ├── COMPS/
        └── DELIVERIES/
            ├── WIP/
            ├── FINAL/
            └── GFX/
```

Esta misma estructura se repite en `EP02` a `EP08`.

No se crean todavía proyectos de aplicaciones, composiciones, renders,
secuencias ni carpetas específicas de plano.

## 5. Planos

Un plano pertenece exactamente a un Episodio y contiene en esta fase:

```text
id estable
episodeId
código técnico exacto
nombre o descripción opcional
estado
orden de presentación
```

Ejemplo de código técnico:

```text
FOQ2_201_005_010
```

Shot Manager almacena ese código como un valor explícito. No interpreta ni
regenera sus segmentos.

El código debe ser único dentro de la Producción. Se admiten letras ASCII,
números, guion y guion bajo. Los espacios, separadores de ruta y valores vacíos
son inválidos.

Añadir un plano en la fase 1 crea únicamente su registro. No crea proyectos o
carpetas adicionales dentro de los Workstreams.

## 6. Estado manual por plano

Cada fila de plano presenta un combo persistente con exactamente estos cuatro
estados:

| ID persistente | Etiqueta visible |
| --- | --- |
| `not-started` | Sin iniciar |
| `wip` | WIP |
| `in-review` | En revisión |
| `completed` | Finalizado |

El estado inicial de un plano nuevo es `not-started`.

Cambiar el combo actualiza sólo el estado del plano seleccionado. No crea
archivos, no mueve carpetas y no ejecuta ninguna aplicación.

No se infiere el estado leyendo el filesystem. En esta fase es completamente
manual.

## 7. Niveles de vistas

### 7.1 Producciones

Pantalla de entrada con:

- acción `Crear Producción`;
- acción `Abrir Producción`;
- lista de Producciones abiertas recientemente, si se decide persistir ese
  estado local.

Los recientes son estado local de la aplicación y no forman parte del archivo
de la Producción.

### 7.2 Vista de Producción

Cabecera con:

```text
nombre visible
código corto
temporada
ruta raíz
número derivado de Episodios
número derivado de planos
```

Navegación primaria de la fase 1:

```text
Resumen
Episodios
Workstreams
Planos
```

No se muestra todavía una sección funcional de Deliveries.

### 7.3 Resumen

Muestra:

- identidad de la Producción;
- Episodios creados;
- Workstreams asociados;
- recuento de planos por estado.

Los recuentos por estado son derivados, no persistidos.

### 7.4 Episodios

Lista ordenada de Episodios. Al seleccionar uno se muestra:

- código y nombre del Episodio;
- Workstreams materializados en ese Episodio;
- tabla de sus planos;
- acción `Añadir plano`.

Cada fila de plano contiene como mínimo:

```text
código
nombre/descripción
combo de estado
```

### 7.5 Workstreams

Vista de la definición global de Workstreams y sus subcarpetas. También muestra
su estructura resuelta por Episodio.

No muestra estados de ejecución, aplicaciones conectadas, dependencias ni
artifacts.

### 7.6 Planos

Vista transversal de todos los planos de la Producción, agrupable o filtrable
por Episodio.

Columnas mínimas:

```text
Episodio
Código de plano
Nombre/descripción
Estado
```

Filtros mínimos:

```text
Episodio
Estado
Texto por código o nombre
```

El mismo combo de estado se utiliza en la vista del Episodio y en la vista
global. Ambas escriben el mismo campo persistente.

## 8. Asistente `Crear Producción`

Orden propuesto:

1. Seleccionar carpeta raíz existente.
2. Introducir nombre visible.
3. Introducir código corto.
4. Introducir número de temporada.
5. Introducir número de Episodios.
6. Seleccionar o definir Workstreams y sus subcarpetas.
7. Revisar la estructura que se va a crear.
8. Confirmar `Crear Producción`.

La revisión final muestra el árbol completo antes de escribir.

La creación debe ser una operación única:

- validar primero todos los campos y rutas;
- construir el contenido en un directorio temporal hermano;
- escribir el documento de Producción;
- crear Episodios y Workstreams;
- validar el resultado completo;
- publicar mediante un único rename a `FOQ2/`;
- eliminar el temporal si la operación falla.

## 9. Persistencia mínima

La Producción tiene un único documento raíz:

```text
FOQ2/production.json
```

Forma conceptual:

```json
{
  "schema": "ShotManager.Production",
  "schemaVersion": 1,
  "productionId": "production-uuid",
  "displayName": "FOQ · Temporada 2",
  "shortCode": "FOQ2",
  "seasonNumber": 2,
  "episodes": [
    {
      "id": "episode-uuid",
      "code": "EP01",
      "name": "Episode 1",
      "order": 0
    }
  ],
  "workstreams": [
    {
      "id": "mockups",
      "displayName": "Mockups",
      "folderName": "MOCKUPS",
      "subfolders": ["WORK", "RENDERS"]
    }
  ],
  "shots": [
    {
      "id": "shot-uuid",
      "episodeId": "episode-uuid",
      "code": "FOQ2_201_005_010",
      "name": "",
      "status": "not-started",
      "order": 0
    }
  ]
}
```

El ejemplo es ilustrativo, pero los nombres de schema, versión, campos y estados
deben quedar cerrados antes de implementar lectores o escritores.

El lector acepta sólo el contrato actual exacto. Campos desconocidos, versiones
desconocidas, ids duplicados, referencias de Episodio inexistentes, códigos de
plano duplicados o rutas inválidas deben fallar explícitamente.

Abrir una Producción existente es de sólo lectura respecto a su documento y
directorios. No crea carpetas ausentes, no repara estructura y no convierte
schemas.

Las modificaciones explícitas de planos y estados escriben `production.json`
atómicamente.

## 10. Fuera de alcance de la fase 1

- Integración con Mockups.
- Integración con Screen Simulation.
- Integración con SynthEyes.
- Integración o scripting de Fusion.
- Creación de una comp base.
- Underlays, Loaders, Savers o nodos gestionados.
- Apertura o lanzamiento de aplicaciones externas.
- Dependencias entre Workstreams.
- Escaneo de `RENDERS` o `DELIVERIES`.
- Detección automática del estado de un plano.
- Revisión o versionado de comps y renders.
- Selección o copia de entregas.
- Paquetes por fecha.
- FTP u otros métodos de publicación.
- Registro de artifacts, manifests de render o hashes.
- Migraciones o compatibilidad con schemas anteriores.

## 11. Criterios de aceptación

1. Crear FOQ2 con temporada 2 y ocho Episodios produce `EP01` a `EP08`.
2. Cada Episodio contiene exactamente los Workstreams y subcarpetas elegidos.
3. `production.json` representa exactamente la estructura creada.
4. Un destino existente se rechaza sin modificarlo.
5. Un fallo durante creación no deja una Producción parcialmente publicada.
6. La aplicación puede cerrar y volver a abrir FOQ2 sin modificar bytes ni
   directorios durante Open.
7. Se puede añadir un plano a un Episodio con un código técnico explícito.
8. Un código de plano duplicado se rechaza antes de escribir.
9. Todo plano nuevo empieza en `Sin iniciar`.
10. El combo permite solamente `Sin iniciar`, `WIP`, `En revisión` y
    `Finalizado`.
11. Cambiar el estado persiste y se refleja igual en las vistas Episodio y
    Planos.
12. Resumen deriva correctamente los recuentos por estado.
13. No existe código que invoque o inspeccione aplicaciones externas.
14. No existe escaneo de renders, deliveries o archivos por plano.

## 12. Resultado esperado del proyecto receptor

Al completar esta fase debe existir una aplicación web local capaz de crear,
abrir y presentar una Producción como FOQ2, con sus Episodios, Workstreams,
estructura física y planos con estado manual.

La arquitectura debe permitir añadir posteriormente creación de comps Fusion,
publicaciones de Workstreams y gestión de entregas, pero esta fase no debe
implementar anticipadamente ninguna de esas funciones.

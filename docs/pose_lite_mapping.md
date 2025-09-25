# Mapeo de articulaciones del stream «lite»

El backend expone un stream de pose «lite» que sólo incluye las articulaciones
necesarias para validar hombros, codos, muñecas, caderas, rodillas y tobillos.
La siguiente tabla documenta el orden exacto en el que llegan esos puntos y la
correspondencia con los índices oficiales de MediaPipe Pose (versión de 33
landmarks):

| `liteIndex` | Articulación           | `mediaPipeIndex` |
|------------:|------------------------|-----------------:|
| 0           | Hombro izquierdo       | 11 |
| 1           | Hombro derecho         | 12 |
| 2           | Codo izquierdo         | 13 |
| 3           | Codo derecho           | 14 |
| 4           | Muñeca izquierda       | 15 |
| 5           | Muñeca derecha         | 16 |
| 6           | Cadera izquierda       | 23 |
| 7           | Cadera derecha         | 24 |
| 8           | Rodilla izquierda      | 25 |
| 9           | Rodilla derecha        | 26 |
| 10          | Tobillo izquierdo      | 27 |
| 11          | Tobillo derecho        | 28 |

Todos los remapeos de este PR rellenan arreglos de 33 puntos (MediaPipe Pose
completo) con `NaN` y escriben cada punto del stream «lite» en la posición que
le corresponde según esta tabla. De este modo se preserva la compatibilidad con
las métricas existentes (que esperan índices MediaPipe) y con los overlays en
la UI.

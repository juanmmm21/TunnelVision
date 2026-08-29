# Tools/Screenshots — las fotos, tomadas conduciendo la app

`capture.py` escribe las veinte capturas de [`../../docs/screenshots`](../../docs/screenshots)
recorriendo la app en el Simulator: instala, siembra, va pantalla por pantalla y fotografía.

```bash
python3 Tools/Screenshots/capture.py \
  --app <derivedData>/Build/Products/Debug-iphonesimulator/TunnelVision.app \
  --udid <UDID del Simulator arrancado>            # --appearances light dark por defecto
```

Necesita el `idb` del entorno (`~/.local/bin/idb` y el companion escuchando en el 10882; la receta
está en [`../../docs/development/01-environment-and-project-setup.md`](../../docs/development/01-environment-and-project-setup.md)).

**Por qué un guion y no veinte fotos hechas a mano.** Una captura es la única documentación de este
repo que nadie puede revisar leyéndola: si el diseño se mueve, no hay diff que lo delate. Con el
recorrido escrito, rehacerlas cuesta un comando y la foto vieja no puede sobrevivir a la pantalla que
retrata.

**Los elementos se buscan por su etiqueta de accesibilidad**, la misma que lee VoiceOver, no por
coordenadas: un rediseño rompe el guion en el punto exacto y con el nombre de lo que ya no está, en
vez de fotografiar en silencio el sitio equivocado. Las dos excepciones son la barra de pestañas y el
botón de filtros de la Timeline, que el árbol no publica como hijos.

Cuatro cosas que el recorrido tuvo que aprender y que están escritas en el propio fichero, porque
cada una costó un intento en falso:

- **Cada apariencia parte de una instalación limpia**, porque la intro sólo sale en el primer arranque
  y porque desinstalar es lo único que devuelve los ajustes a los de fábrica — un tope de retención
  que dejó otra sesión saldría en la foto de *Captures*.
- **El llavero sobrevive a desinstalar la app**, así que el flujo de la CA aparece en la etapa que
  dejó la sesión anterior: el guion borra el certificado antes de fotografiar su primera etapa.
- **El buscador de la Timeline vive en el cajón de la barra de navegación**: sólo está montado con la
  lista en su tope, y no filtra hasta que se envía con Return.
- **Una pantalla con barra de acciones fija abajo no se desplaza** si el arrastre empieza sobre ella,
  así que la banda del gesto es un parámetro y no una constante.

No entra en ningún target: `project.yml` lista las fuentes una a una y esta carpeta no está en
ninguna.

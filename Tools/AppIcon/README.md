# Tools/AppIcon — el icono, dibujado desde código

`RenderAppIcon.swift` escribe los tres PNG de 1024×1024 del icono de la app (el de siempre, el de
oscuro y el teñido en grises) directamente en el set del catálogo:

```bash
swift Tools/AppIcon/RenderAppIcon.swift TunnelVision/Resources/Assets.xcassets/AppIcon.appiconset
```

Es **reproducible byte a byte**: volver a ejecutarlo sin tocar el fichero no cambia los PNG, así que
un render de más no ensucia el diff.

**Por qué un renderizador y no tres PNG versionados.** Un binario opaco no se revisa en un diff, no
se retoca y no se vuelve a derivar cuando la marca se mueva. Aquí las medidas y los hexadecimales
están escritos, y el que manda es este fichero: para cambiar el icono se cambian sus números y se
vuelve a renderizar.

- Qué dibuja y por qué esa marca: [`../../docs/ux/design-system.md`](../../docs/ux/design-system.md)
  § *App icon*.
- Qué se le afirma: `TunnelVisionTests/Presentation/AppIconTests.swift` (que el bundle traiga icono,
  que sea opaco, que se aclare hacia el centro y que esté en el tono de la marca).

No entra en ningún target: `project.yml` lista las fuentes una a una, y esta carpeta no está en
ninguna. Corre en macOS con el `swift` del sistema, sin dependencias.

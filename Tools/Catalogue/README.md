# Tools/Catalogue — el catálogo, comprobado contra el documento

`verify.py` compara un catálogo de requisitos (`Shared/Audit/Requirements/*.json`) con el PDF
oficial del que dice salir:

```bash
python3 Tools/Catalogue/verify.py Shared/Audit/Requirements/tr-03161-1_3.0.json <BSI-TR-03161-1.pdf>
```

Afirma dos cosas: que el PDF es exactamente el que el catálogo cita (su SHA-256), y que el
identificador, la «Kurzfassung des Prüfaspekts» y la «Prüftiefe» de cada requisito están en las
tablas de «Testcharakteristik» del documento (capítulo 4.3), palabra por palabra. Necesita PyMuPDF
(`pip install pymupdf`).

**Por qué un guion y no un test.** El PDF es del BSI y no está en el repositorio, así que la suite
no puede leerlo. Lo que la suite sí sujeta es qué regla lleva cada requisito
(`RequirementCatalogueLibraryTests`); que el requisito exista y se llame así lo dice este guion, y
hay que pasarlo cada vez que se toque un catálogo o el BSI publique una versión nueva.

El documento se descarga de
<https://www.bsi.bund.de/SharedDocs/Downloads/DE/BSI/Publikationen/TechnischeRichtlinien/TR03161/BSI-TR-03161-1.pdf?__blob=publicationFile>.
Esa dirección sirve siempre la versión vigente: si el SHA-256 ya no coincide, hay versión nueva y
el catálogo que toca es otro fichero, no una corrección de éste.

**Lo que no comprueba**: qué clases de hallazgo se ligan a cada requisito. Eso es una lectura de
este proyecto (`docs/spec/audit.md` § *The catalogue that ships*), no un dato del documento, y
tampoco comprueba el mínimo de TLS, que sale de la TR-02102-2.

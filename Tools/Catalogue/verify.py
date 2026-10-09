#!/usr/bin/env python3
"""Comprueba un catálogo de requisitos contra el PDF oficial del que dice salir.

    python3 Tools/Catalogue/verify.py <catálogo.json> <BSI-TR-03161-1.pdf>

Afirma que el PDF es exactamente el que el catálogo cita (SHA-256) y que cada requisito —su
identificador, su «Kurzfassung des Prüfaspekts» y su «Prüftiefe»— está en la tabla de
«Testcharakteristik» del documento, palabra por palabra. Necesita PyMuPDF (`pip install pymupdf`).
"""

import hashlib
import json
import re
import sys

import fitz

DEPTHS = ("CHECK", "EXAMINE")


def squash(text: str) -> str:
    # El PDF parte las líneas por donde le cabe y corta palabras con guion; un título solo se
    # puede comparar quitando de los dos lados el blanco y los guiones.
    return re.sub(r"[\s\-]+", "", text)


def test_characteristics(pdf: "fitz.Document") -> dict[str, tuple[str, str]]:
    """Identificador → (Kurzfassung sin blancos, Prüftiefe), leído del capítulo 4.3."""
    lines: list[str] = []
    in_chapter = False
    for page in pdf:
        text = page.get_text()
        # El índice también nombra el capítulo; la tabla de verdad es la que lleva su cabecera.
        if "Kurzfassung des Prüfaspekts" in text:
            in_chapter = True
        if in_chapter:
            lines.extend(line.strip() for line in text.splitlines())
    found: dict[str, tuple[str, str]] = {}
    index = 0
    while index < len(lines):
        if re.fullmatch(r"O\.[A-Za-z]+_\d+", lines[index]):
            identifier = lines[index]
            title: list[str] = []
            index += 1
            while index < len(lines) and lines[index] not in DEPTHS:
                title.append(lines[index])
                index += 1
            if index < len(lines) and identifier not in found:
                found[identifier] = (squash(" ".join(title)), lines[index])
        index += 1
    return found


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    catalogue_path, pdf_path = sys.argv[1], sys.argv[2]
    with open(catalogue_path, encoding="utf-8") as handle:
        catalogue = json.load(handle)
    with open(pdf_path, "rb") as handle:
        digest = hashlib.sha256(handle.read()).hexdigest()

    problems: list[str] = []
    if digest != catalogue["source"]["sha256"]:
        problems.append(f"el PDF no es el que cita el catálogo: sha256 {digest}")

    with fitz.open(pdf_path) as pdf:
        official = test_characteristics(pdf)
    for requirement in catalogue["requirements"]:
        identifier = requirement["id"]
        if identifier not in official:
            problems.append(f"{identifier}: no está en el documento")
            continue
        title, depth = official[identifier]
        if squash(requirement["title"]) != title:
            problems.append(f"{identifier}: el título no es el del documento")
        if requirement["testDepth"] != depth:
            problems.append(f"{identifier}: Prüftiefe {requirement['testDepth']}, el documento dice {depth}")

    for problem in problems:
        print(f"✗ {problem}")
    if problems:
        return 1
    print(f"✓ {len(catalogue['requirements'])} requisitos de {catalogue['identifier']} coinciden con el documento")
    return 0


if __name__ == "__main__":
    sys.exit(main())

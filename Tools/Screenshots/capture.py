#!/usr/bin/env python3
"""Las fotos del showcase, tomadas conduciendo la app en el Simulator.

    python3 Tools/Screenshots/capture.py --app <ruta>/TunnelVision.app

Escribe `docs/screenshots/<apariencia>/<pantalla>.png`. Cada apariencia parte de una instalación
limpia, porque la intro sólo aparece en el primer arranque.

El recorrido no usa coordenadas salvo donde la barra de navegación no publica su botón: los
elementos se buscan por su etiqueta de accesibilidad, que es la misma que lee VoiceOver, así que una
pantalla que se rediseña rompe el guion en el sitio exacto y con el nombre de lo que ya no está.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys
import time

BUNDLE_ID = "com.juanmmm21.tunnelvision"

# Las cuatro pestañas, en su orden. Dónde cae cada una se calcula sobre el ancho de la barra: es el
# reparto de un `TabView`, y así el guion vale igual en un 6,3" que en un 6,9".
TABS = ["dashboard", "timeline", "captures", "settings"]

# La franja del alto de pantalla en la que un elemento se considera alcanzable por el dedo: por
# debajo de la barra de navegación y por encima de la de pestañas. En fracciones y no en puntos,
# porque una pantalla más alta mueve el suelo pero no el techo.
REACHABLE_TOP = 120
REACHABLE_BOTTOM_MARGIN = 180

# El campo de búsqueda de la Timeline vive en el cajón de la barra de navegación, que no publica sus
# hijos: se sondea por punto. Estas son las alturas donde puede caer, de más a menos probable.
SEARCH_FIELD_PROBES = (190, 170, 210, 145)


class Simulator:
    """Lo que se le puede hacer a un Simulator arrancado: mirarlo, tocarlo y arrastrarlo."""

    def __init__(self, udid: str, idb: str) -> None:
        self.udid = udid
        self.idb = idb
        self._size: tuple[int, int] | None = None

    @property
    def size(self) -> tuple[int, int]:
        """El tamaño de la pantalla en puntos, leído del propio árbol y cacheado."""
        if self._size is None:
            root = self.tree()[0]["frame"]
            self._size = (round(root["width"]), round(root["height"]))
        return self._size

    # MARK: Mirar

    def tree(self) -> list[dict]:
        out = self._idb("ui", "describe-all")
        return json.loads(out)

    def find(self, label: str, exact: bool = True) -> dict | None:
        for element in self.tree():
            found = element.get("AXLabel") or ""
            if found == label if exact else label in found:
                return element
        return None

    def element_at(self, x: int, y: int) -> dict:
        return json.loads(self._idb("ui", "describe-point", str(x), str(y)))

    def shot(self, path: pathlib.Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["xcrun", "simctl", "io", self.udid, "screenshot", "--type=png", str(path)],
            capture_output=True, check=True,
        )
        print(f"    {path}")

    # MARK: Tocar

    def tap(self, x: int, y: int, settle: float = 1.5) -> None:
        self._idb("ui", "tap", str(x), str(y))
        time.sleep(settle)

    def tap_label(self, label: str, exact: bool = True, settle: float = 1.5) -> dict:
        element = self.find(label, exact)
        if element is None:
            raise LookupError(f"no está en pantalla: {label}")
        frame = element["frame"]
        self.tap(round(frame["x"] + frame["width"] / 2),
                 round(frame["y"] + frame["height"] / 2), settle)
        return element

    def tab(self, name: str, settle: float = 2.0) -> None:
        """Toca una pestaña, situándola sobre la barra real en vez de sobre una constante.

        La barra sí aparece en el árbol —aunque sin hijos, que es el límite conocido de
        `describe-all`—, así que su marco da la altura, y el ancho repartido entre cuatro da la
        columna de cada pestaña.
        """
        bar = self.find("Tab Bar")
        if bar is None:
            raise LookupError("esta pantalla no tiene barra de pestañas")
        frame = bar["frame"]
        column = TABS.index(name)
        x = frame["x"] + frame["width"] * (2 * column + 1) / (2 * len(TABS))
        self.tap(round(x), round(frame["y"] + frame["height"] / 2), settle)

    def filters_button(self) -> tuple[int, int]:
        """El botón de filtros de la Timeline: esquina superior derecha, sondeada por punto.

        La barra de navegación no publica sus botones como hijos, así que la única forma de dar con
        él es preguntar por el punto — y comprobar que lo que hay allí es de verdad el botón, para
        que un cambio de sitio no acabe tocando el título.
        """
        width, _ = self.size
        point = (width - 38, 84)
        element = self.element_at(*point)
        if (element.get("AXLabel") or "") != "Filters":
            raise LookupError(f"en {point} no está el botón de filtros sino {element.get('AXLabel')!r}")
        return point

    def type_text(self, text: str) -> None:
        self._idb("ui", "text", text)
        time.sleep(1.0)

    def press_return(self) -> None:
        self._idb("ui", "key", "40")  # HID keycode de Return
        time.sleep(1.5)

    def swipe(self, x1: int, y1: int, x2: int, y2: int,
              duration: float = 0.25, settle: float = 0.6) -> None:
        self._idb("ui", "swipe", "--duration", str(duration), str(x1), str(y1), str(x2), str(y2))
        time.sleep(settle)

    def reachable(self) -> tuple[int, int]:
        _, height = self.size
        return (REACHABLE_TOP, height - REACHABLE_BOTTOM_MARGIN)

    def scroll_to(self, label: str, exact: bool = True, tries: int = 25,
                  band: tuple[int, int] = (200, 500)) -> dict:
        """Arrastra dentro de `band` hasta que la etiqueta quede al alcance del dedo.

        La banda es un parámetro porque una pantalla con barra de acciones fija abajo no se desplaza
        si el arrastre empieza sobre ella: el gesto se lo queda la barra y el guion se cuelga sin
        decir por qué.
        """
        top, bottom = self.reachable()
        middle = self.size[0] // 2
        for _ in range(tries):
            element = self.find(label, exact)
            if element is not None and top < element["frame"]["y"] < bottom:
                return element
            self.swipe(middle, band[1], middle, band[0])
        raise LookupError(f"no aparece tras {tries} arrastres: {label}")

    def _idb(self, *args: str) -> str:
        result = subprocess.run([self.idb, *args, "--udid", self.udid],
                                capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"idb {' '.join(args)} falló: {result.stderr.strip()}")
        return result.stdout


def install(sim: Simulator, app: pathlib.Path) -> None:
    """Instalación limpia y siembra. Desinstalar es lo que devuelve los ajustes a los de fábrica."""
    subprocess.run(["xcrun", "simctl", "uninstall", sim.udid, BUNDLE_ID], capture_output=True)
    subprocess.run(["xcrun", "simctl", "install", sim.udid, str(app)],
                   capture_output=True, check=True)
    subprocess.run(["xcrun", "simctl", "launch", sim.udid, BUNDLE_ID, "-TVSeedFixture"],
                   capture_output=True, check=True)
    time.sleep(6)  # la siembra escribe ~7.400 paquetes antes de que monte la primera pantalla


def appearance(sim: Simulator, mode: str) -> None:
    subprocess.run(["xcrun", "simctl", "ui", sim.udid, "appearance", mode],
                   capture_output=True, check=True)
    subprocess.run(["xcrun", "simctl", "ui", sim.udid, "content_size", "medium"],
                   capture_output=True, check=True)
    # La hora y la batería de una foto de producto no son las de la máquina que la toma.
    subprocess.run(["xcrun", "simctl", "status_bar", sim.udid, "override",
                    "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100",
                    "--wifiMode", "active", "--wifiBars", "3",
                    "--cellularMode", "active", "--cellularBars", "4",
                    "--dataNetwork", "wifi"], capture_output=True, check=True)


def leave_intro(sim: Simulator) -> None:
    """Sale de la intro por la puerta que no pide la VPN: *Start monitoring* no funciona aquí."""
    sim.tap_label("Continue")
    sim.tap_label("Continue")
    sim.tap_label("Not now", settle=2.5)


def search(sim: Simulator, text: str) -> None:
    """Escribe en el buscador de la Timeline y aplica.

    El campo vive en el cajón de la barra de navegación: sólo está montado con la lista en su tope,
    y no filtra hasta que se envía.
    """
    width, height = sim.size
    middle = width // 2
    # Arrastrar hacia abajo desde dentro de la lista: empezando sobre la tarjeta del eje, que no
    # se desplaza, el gesto no llega a la lista y el cajón nunca se monta.
    for _ in range(8):
        sim.swipe(middle, round(height * 0.46), middle, round(height * 0.89),
                  duration=0.2, settle=0.4)
    time.sleep(1.0)
    for y in SEARCH_FIELD_PROBES:
        if sim.element_at(middle, y)["type"] == "TextField":
            sim.tap(middle, y, settle=1.2)
            sim.type_text(text)
            sim.press_return()
            return
    raise LookupError("el buscador no aparece con la lista en su tope")


def back(sim: Simulator, settle: float = 2.0) -> None:
    """El botón de volver, buscado por dónde está y no por cómo se llama.

    Su etiqueta es el título de la pantalla anterior, así que nombrarla ataría el guion al camino
    por el que se llegó hasta aquí.
    """
    for element in sim.tree():
        frame = element["frame"]
        if element["type"] == "Button" and frame["x"] < 60 and frame["y"] < 110:
            sim.tap(round(frame["x"] + frame["width"] / 2),
                    round(frame["y"] + frame["height"] / 2), settle)
            return
    raise LookupError("esta pantalla no tiene botón de volver")


def clear_search(sim: Simulator) -> None:
    for label in ("Clear text", "Close"):
        try:
            sim.tap_label(label, settle=1.2)
        except LookupError:
            pass


def reset_certificate(sim: Simulator) -> None:
    """Deja el flujo de la CA en su primera etapa.

    Hace falta porque la clave vive en el llavero y **el llavero sobrevive a desinstalar la app**:
    sin esto la pantalla sale en la etapa que dejó la sesión anterior.
    """
    sim.tab("settings")
    sim.scroll_to("Set up secure traffic inspection", band=(200, 600))
    sim.tap_label("Set up secure traffic inspection", settle=2.5)
    if sim.find("Remove certificate from this device") is None:
        back(sim, settle=1.5)
        return
    # La barra de acciones fija ocupa el tercio inferior, así que el arrastre va por encima de ella.
    sim.scroll_to("Remove certificate from this device",
                  band=(220, round(sim.size[1] * 0.57)))
    sim.tap_label("Remove certificate from this device", settle=2)
    sim.tap_label("Remove certificate", settle=3)
    back(sim, settle=1.5)


def capture(sim: Simulator, out: pathlib.Path) -> None:
    """El recorrido, en el orden en que un lector del README los va a ver."""
    print("  intro")
    sim.shot(out / "01-intro.png")
    leave_intro(sim)

    print("  timeline")
    sim.tab("timeline")
    middle = sim.size[0] // 2
    # El título no se dibuja hasta que la lista se toca una vez: es una rareza de iOS, no del código.
    sim.swipe(middle, 500, middle, 520, duration=0.3, settle=1.2)
    sim.shot(out / "02-timeline.png")

    print("  flow inspector + conversación")
    search(sim, "api.example.com")
    sim.tap_label("api.example.com", settle=2.5)
    sim.shot(out / "03-flow-inspector.png")
    sim.tap_label("66 KB saved", settle=2.5)
    sim.shot(out / "04-conversation.png")
    back(sim)   # de la conversación al Flow Inspector
    back(sim)   # y de ahí a la Timeline

    print("  paquete con DNS")
    clear_search(sim)
    search(sim, "192.0.2.7")
    sim.tap_label("192.0.2.7", settle=2.5)
    reply = next(e for e in sim.tree() if (e.get("AXLabel") or "").startswith("Data. Received"))
    frame = reply["frame"]
    sim.tap(round(frame["x"] + frame["width"] / 2), round(frame["y"] + frame["height"] / 2),
            settle=2.5)
    sim.shot(out / "05-packet-dns.png")

    print("  captures")
    sim.tab("captures")
    sim.shot(out / "06-captures.png")

    print("  ajustes y diagnóstico")
    sim.tab("settings")
    sim.shot(out / "07-settings.png")
    sim.scroll_to("Session diagnostics", exact=False, band=(200, 600))
    sim.tap_label("Session diagnostics", settle=3)
    sim.shot(out / "08-session-diagnostics.png")
    back(sim)

    print("  flujo de la CA")
    reset_certificate(sim)
    sim.scroll_to("Set up secure traffic inspection", band=(200, 600))
    sim.tap_label("Set up secure traffic inspection", settle=2.5)
    sim.shot(out / "09-certificate-setup.png")
    # El flujo tiene tres etapas y la del medio —un titular y un botón— no cuenta nada que la
    # primera no diga ya, así que se atraviesa sin fotografiarla.
    sim.tap_label("Continue", settle=2.5)
    sim.tap_label("Create certificate", settle=3.5)
    sim.shot(out / "10-certificate-install.png")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=pathlib.Path,
                        help="TunnelVision.app compilada para Simulator")
    parser.add_argument("--udid", required=True, help="UDID del Simulator arrancado")
    parser.add_argument("--idb", default=str(pathlib.Path.home() / ".local/bin/idb"))
    parser.add_argument("--out", type=pathlib.Path, default=pathlib.Path("docs/screenshots"))
    parser.add_argument("--appearances", nargs="+", default=["light", "dark"])
    args = parser.parse_args()

    if not args.app.exists():
        print(f"no existe: {args.app}", file=sys.stderr)
        return 1

    sim = Simulator(args.udid, args.idb)
    for mode in args.appearances:
        print(f"{mode}:")
        appearance(sim, mode)
        install(sim, args.app)
        capture(sim, args.out / mode)
    return 0


if __name__ == "__main__":
    sys.exit(main())

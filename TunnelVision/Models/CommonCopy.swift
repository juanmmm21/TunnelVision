import Foundation

/// La copia que **no es de ninguna pantalla**: las palabras que la app repite igual en todas.
///
/// Existe por la regla de los estándares (`docs/development/02-coding-standards.md`, *Product copy*) de
/// que lo que se comparte se comparta **estructuralmente** —una propiedad que leen los dos sitios— y no
/// por coincidencia de literales. Un *Cancel* escrito cuatro veces son cuatro unidades de traducción
/// que pueden salir distintas en un idioma sin que nada avise, y cuatro sitios que revisar cuando una
/// de ellas se lea mal.
///
/// El listón para entrar aquí es alto y es el mismo que se aplicó al no fundir el título de esta
/// pantalla con la fila de Ajustes que lleva a ella: **solo entra lo que significa lo mismo en todos
/// los sitios donde aparece**. Cancelar un diálogo, cerrar una hoja terminada y descartar un aviso lo
/// hacen; casi nada más. Cualquier palabra que dependa de qué queda detrás —las cuatro formas de salir
/// del flujo de la CA son el ejemplo— es de su pantalla y se dice allí.
///
/// Se migró pantalla a pantalla, como el resto, y ya está cerrado: leen de aquí el flujo de la CA con
/// su hoja de entrega del perfil, Captures con la hoja del export y Ajustes, que era la última vista
/// que escribía estos literales a mano. Ninguna palabra de aquí está dos veces en el catálogo.
///
/// **Lo que se quedó fuera a conciencia** es *Try again*, que dicen seis pantallas: el listón no es
/// decir las mismas palabras sino significar lo mismo, y ahí se reintenta desde una consulta de
/// paquetes hasta encender el túnel — cada tarjeta dice **en su mensaje** qué falló, y el botón solo
/// repite eso. Seis claves le dan al traductor la libertad de decirlas igual o distinto; una sola se la
/// quitaría. Que hoy coincidan se afirma en `CommonCopyTests`, para que el día que una se reescriba la
/// decisión se vuelva a tomar a conciencia en vez de derivar sola.
public enum CommonCopy {

    /// La salida de un diálogo de confirmación, que **no hace nada**. No es "cerrar": cancelar es
    /// abandonar algo que se había pedido, y en las dos confirmaciones destructivas del flujo de la CA
    /// es lo único que deja el certificado como estaba.
    public static var cancel: String {
        String(
            localized: "common.action.cancel",
            defaultValue: "Cancel",
            comment: """
                Button that dismisses a confirmation dialog without doing anything. Shared by every \
                confirmation in the app, so it must read as 'do not do this after all' in all of \
                them; iOS has its own word for this in each language and it should be that one.
                """
        )
    }

    /// Cerrar algo que ya está hecho. Se distingue de cancelar en lo que deja detrás: aquí no hay nada
    /// que abandonar, solo una hoja que ya no hace falta.
    public static var done: String {
        String(
            localized: "common.action.done",
            defaultValue: "Done",
            comment: """
                Button that closes a sheet whose work is finished. Shared by every sheet in the \
                app. It must not collapse into the word used for Cancel: this one abandons nothing, \
                and iOS distinguishes the two in every language.
                """
        )
    }

    /// Lo que se oye de un aviso que se quita tocándolo. Los avisos de la app son información sobre lo
    /// que acaba de pasar y no diálogos, así que sin esta pista quien no ve la pantalla no tiene forma
    /// de saber que ese texto se puede tocar ni qué pasa si lo toca.
    public static var dismissNoticeHint: String {
        String(
            localized: "common.notice.dismissHint",
            defaultValue: "Dismisses this message",
            comment: """
                VoiceOver hint on a dismissible notice banner: what tapping it does. Shared by every \
                notice in the app. It describes the result, as VoiceOver hints do in this language, \
                and never gives an order ('Tap to dismiss').
                """
        )
    }
}

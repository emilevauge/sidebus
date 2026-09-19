import AppKit

/// Les deux gabarits de la barre de menus, chargés une fois depuis le bundle
/// de ressources du module.
///
/// Ce sont des PDF vectoriels marqués `isTemplate` : macOS les redessine en
/// noir ou en blanc selon le thème et selon la couleur de la barre de menus,
/// et les rend nets à toutes les échelles d'ecran.
enum MenuBarIcon {
    /// Au repos : la dalle du pare-brise est évidée.
    static let repos = charger("MenuBar")
    /// Partage en cours : la dalle est pleine, la différence se voit à 18 points.
    static let actif = charger("MenuBarActif")

    static func pour(partageEnCours: Bool) -> NSImage {
        partageEnCours ? actif : repos
    }

    private static func charger(_ nom: String) -> NSImage {
        let image: NSImage
        if let url = Bundle.module.url(forResource: nom, withExtension: "pdf"),
           let pdf = NSImage(contentsOf: url) {
            image = pdf
        } else {
            // Repli sur un symbole système : mieux vaut une icône approchante
            // qu'une barre de menus vide si la ressource manque.
            image = NSImage(systemSymbolName: "display", accessibilityDescription: "Sidebus")
                ?? NSImage()
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}

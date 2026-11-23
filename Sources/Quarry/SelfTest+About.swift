import AppKit

/// Self-test: the app icon and About Quarry (S-057).
extension SelfTest {
    static func about() {
        check("S-057 Quarry > About Quarry is in the app menu", menuItem("About Quarry") != nil)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        check("S-057 About shows the bundle's version and build",
              !version.isEmpty && AboutWindow.versionText.hasPrefix("Version \(version) ("), AboutWindow.versionText)
        check("S-057 About says what Quarry is and links its author",
              AboutWindow.summary.contains("SQLite") && AboutWindow.thanks.contains("Sequel Pro")
                  && AboutWindow.authorURL.host() == "www.linkedin.com", AboutWindow.authorURL.absoluteString)
        let text = AboutWindow.acknowledgements
        check("S-057 Acknowledgements hold Sequel Pro's and every package's license",
              text.contains("Sequel Pro") && text.contains("mysql-nio") && text.contains("swift-nio-ssl")
                  && text.contains("Apache License"), "\(text.count) characters")
        let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        check("S-057 the app has its own icon", icon != nil && Bundle.main.infoDictionary?["CFBundleIconName"] as? String == "AppIcon")
    }
}

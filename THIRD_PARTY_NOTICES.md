# Third party notices

pocahontas includes or adapts the following work:

- [baxian-app-ios](https://github.com/rockdai/baxian-app-ios): input key mappings, IME input view, modifier relay, XCFramework verification and terminal integration patterns. Apache-2.0; [license](Licenses/baxian-app-ios-Apache-2.0.txt). Modified files identify their origin.
- [Ghostty](https://github.com/ghostty-org/ghostty), through [madeye/ghostty](https://github.com/madeye/ghostty): terminal emulation and rendering. MIT; [license](Licenses/ghostty-MIT.txt). Engine source and additional dependency notices remain in `vendor/ghostty`.
- [Citadel](https://github.com/orlandos-nl/Citadel): OpenSSH Ed25519 key parsing and decryption. MIT; [license](Licenses/citadel-MIT.txt). Linked as a Swift package.
- [Contrail One](https://fonts.google.com/specimen/Contrail+One) by Riccardo De Franceschi / Sorkin Type Co: uppercase P glyph used in the logo. SIL Open Font License 1.1; [license](assets/logo/fonts/OFL.txt). The original font is bundled unchanged; the logo applies synthetic bold and oblique styling to its glyph outline.

Swift package dependencies and their revisions are recorded in `Packages/PocahontasKit/Package.resolved`. They retain their own licenses, including SwiftNIO / SwiftNIO SSH, Swift Crypto and their bundled dependencies. This prototype has not been packaged for App Store distribution; distribution must include the notices supplied with the engine and all linked dependencies.

SSH fixture keys in `Tests/PocahontasKitTests/Fixtures` inside the package are generated test-only material. Their public passphrase is `test-passphrase`; they must never be installed on a real server.

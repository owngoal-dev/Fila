import Foundation
import RunestoneLanguageSupport
import RunestoneThemeSupport
import UIKit

/// Which tree-sitter grammar a text file is parsed with — the only place the
/// mapping is written down.
///
/// Three questions, in order, and a legitimate fourth answer of "none":
///
/// 1. the extension, which settles almost every file with one;
/// 2. the shebang, which is not a nicety here. A jailbroken filesystem is full
///    of executable scripts with no extension at all — most of `/usr/bin`, and
///    the maintainer scripts in every package — and the first line is the only
///    thing that says what they are;
/// 3. a handful of names that never carry an extension and always mean the
///    same thing.
///
/// Nothing recognised is plain text. Forcing a grammar onto a file that has
/// none colours it wrong, which is worse than not colouring it at all.
enum TextSyntax {
    /// Every grammar a reader can pick by hand, for the file the three
    /// questions below have no answer to — `.conf`, a log, a script with no
    /// shebang. Names are the languages' own and are not translated. The
    /// grammars are computed on access, so a choice is remembered by name.
    static let choices: [(name: String, language: () -> TreeSitterLanguage)] = [
        ("Astro", { .astro }), ("Bash", { .bash }), ("C", { .c }), ("C#", { .cSharp }),
        ("C++", { .cpp }), ("CSS", { .css }), ("Elixir", { .elixir }), ("Elm", { .elm }),
        ("Go", { .go }), ("Haskell", { .haskell }), ("HTML / XML", { .html }), ("Java", { .java }),
        ("JavaScript", { .javaScript }), ("JSON", { .json }), ("JSON5", { .json5 }), ("JSX", { .jsx }),
        ("Julia", { .julia }), ("LaTeX", { .latex }), ("Lua", { .lua }), ("Markdown", { .markdown }),
        ("OCaml", { .ocaml }), ("Perl", { .perl }), ("PHP", { .php }), ("Python", { .python }),
        ("R", { .r }), ("Ruby", { .ruby }), ("Rust", { .rust }), ("SCSS", { .scss }),
        ("SQL", { .sql }), ("Svelte", { .svelte }), ("Swift", { .swift }), ("TOML", { .toml }),
        ("TSX", { .tsx }), ("TypeScript", { .typeScript }), ("YAML", { .yaml }),
    ]

    static func language(named name: String) -> TreeSitterLanguage? {
        choices.first { $0.name == name }?.language()
    }

    static func language(for path: String, text: String) -> TreeSitterLanguage? {
        let name = (path as NSString).lastPathComponent
        if let language = byExtension((name as NSString).pathExtension.lowercased()) { return language }
        if let language = byInterpreter(of: text) { return language }
        return byName(name, at: path)
    }

    /// XML has no grammar in the set, and `.plist`, `.entitlements` and `.xml`
    /// are files this app is opened for. They go to HTML: tree-sitter-html is a
    /// tag/attribute/string parser, which is exactly the shape of XML, so the
    /// colours land where a reader expects them. Where it disagrees with the
    /// document — a processing instruction, a namespace prefix — the text is
    /// left uncoloured rather than coloured wrongly, so the failure mode is the
    /// plain-text one we would have had anyway.
    private static func byExtension(_ ext: String) -> TreeSitterLanguage? {
        switch ext {
        case "c", "h", "m": return .c
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx", "mm": return .cpp
        case "cs": return .cSharp
        case "swift": return .swift
        case "py", "pyw": return .python
        case "rb", "gemspec", "podspec": return .ruby
        case "pl", "pm", "t": return .perl
        case "lua": return .lua
        case "sh", "bash", "zsh", "zshrc", "zshenv", "zprofile", "bashrc", "bash_profile", "profile": return .bash
        case "json": return .json
        case "json5": return .json5
        case "yml", "yaml": return .yaml
        case "toml": return .toml
        case "md", "markdown": return .markdown
        case "html", "htm", "xhtml": return .html
        case "xml", "plist", "entitlements", "mobileconfig", "svg", "storyboard", "xib": return .html
        case "css": return .css
        case "scss", "sass": return .scss
        case "js", "mjs", "cjs": return .javaScript
        case "jsx": return .jsx
        case "ts", "mts", "cts": return .typeScript
        case "tsx": return .tsx
        case "go": return .go
        case "rs": return .rust
        case "java": return .java
        case "sql": return .sql
        case "php": return .php
        case "tex", "sty", "cls": return .latex
        case "ex", "exs": return .elixir
        case "elm": return .elm
        case "hs": return .haskell
        case "jl": return .julia
        case "ml", "mli": return .ocaml
        case "r": return .r
        case "svelte": return .svelte
        case "astro": return .astro
        default: return nil
        }
    }

    /// `#!/bin/sh`, `#!/usr/bin/env python3`, `#!/usr/bin/env -S ruby -w`. The
    /// decision is the interpreter's basename, and `env` means the basename is
    /// the next word that is neither a flag nor a `VAR=value` assignment.
    private static func byInterpreter(of text: String) -> TreeSitterLanguage? {
        guard text.hasPrefix("#!") else { return nil }
        // CRLF is undone before the line is cut, because Swift reads "\r\n" as
        // one Character that is neither "\r" nor "\n": scanning for a newline
        // without this runs straight past the first line of a DOS-ended file
        // and takes the newline into the interpreter's name.
        var words = text
            .prefix(512)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .prefix(while: { $0 != "\n" && $0 != "\r" })
            .dropFirst(2)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard !words.isEmpty else { return nil }
        if (words[0] as NSString).lastPathComponent == "env" {
            words.removeFirst()
            while let word = words.first, word.hasPrefix("-") || word.contains("=") { words.removeFirst() }
            guard !words.isEmpty else { return nil }
        }
        switch (words[0] as NSString).lastPathComponent.lowercased() {
        case "sh", "bash", "zsh", "dash", "ash", "ksh", "mksh": return .bash
        case "python", "python2", "python3": return .python
        case "perl": return .perl
        case "ruby": return .ruby
        case "lua": return .lua
        case "node", "nodejs": return .javaScript
        case "php": return .php
        case "r", "rscript": return .r
        case "julia": return .julia
        case "swift": return .swift
        default: return nil
        }
    }

    /// Names that never carry an extension. `Makefile` and `Dockerfile` are
    /// shell for everything a reader looks at in them — the recipes and the
    /// `RUN` lines — and `.gitconfig` is an INI file, which is TOML's shape.
    /// Debian's `control` is a field list, which is YAML's.
    private static func byName(_ name: String, at path: String) -> TreeSitterLanguage? {
        switch name {
        case "Makefile", "makefile", "GNUmakefile", "Dockerfile", "Containerfile": return .bash
        case ".gitconfig", ".gitmodules": return .toml
        case "Gemfile", "Rakefile", "Podfile", "Brewfile": return .ruby
        default: break
        }
        guard path.contains("/DEBIAN/") || path.contains("/debian/") else { return nil }
        switch name {
        case "control": return .yaml
        case "preinst", "postinst", "prerm", "postrm": return .bash
        default: return nil
        }
    }
}

/// One of Runestone's themes with the app's own font in front of it.
///
/// The themes ship a fixed point size — 14 — and a code viewer that ignores
/// Dynamic Type is a code viewer half the people who need this app cannot read.
/// Everything that is not the font is the base theme's, forwarded, because the
/// palette is the part worth keeping.
final class ScaledEditorTheme: EditorTheme {
    /// Light and dark. Re-derive this whenever the trait collection changes: a
    /// theme chosen once at load leaves the editor in the wrong palette the
    /// moment the system flips.
    static func theme(for traits: UITraitCollection) -> ScaledEditorTheme {
        ScaledEditorTheme(
            base: traits.userInterfaceStyle == .dark ? OneDarkTheme() : TomorrowTheme(),
            pointSize: UIFontMetrics(forTextStyle: .body).scaledValue(for: FilaUI.Font.monospacedBodySize, compatibleWith: traits)
        )
    }

    let font: UIFont
    let lineNumberFont: UIFont

    private let base: EditorTheme

    private init(base: EditorTheme, pointSize: CGFloat) {
        self.base = base
        font = .monospacedSystemFont(ofSize: pointSize, weight: .regular)
        lineNumberFont = .monospacedSystemFont(ofSize: pointSize, weight: .regular)
    }

    var backgroundColor: UIColor { base.backgroundColor }
    var userInterfaceStyle: UIUserInterfaceStyle { base.userInterfaceStyle }
    var textColor: UIColor { base.textColor }
    var gutterBackgroundColor: UIColor { base.gutterBackgroundColor }
    var gutterHairlineColor: UIColor { base.gutterHairlineColor }
    var gutterHairlineWidth: CGFloat { base.gutterHairlineWidth }
    var lineNumberColor: UIColor { base.lineNumberColor }
    var selectedLineBackgroundColor: UIColor { base.selectedLineBackgroundColor }
    var selectedLinesLineNumberColor: UIColor { base.selectedLinesLineNumberColor }
    var selectedLinesGutterBackgroundColor: UIColor { base.selectedLinesGutterBackgroundColor }
    var invisibleCharactersColor: UIColor { base.invisibleCharactersColor }
    var pageGuideHairlineColor: UIColor { base.pageGuideHairlineColor }
    var pageGuideHairlineWidth: CGFloat { base.pageGuideHairlineWidth }
    var pageGuideBackgroundColor: UIColor { base.pageGuideBackgroundColor }
    var markedTextBackgroundColor: UIColor { base.markedTextBackgroundColor }
    var markedTextBackgroundCornerRadius: CGFloat { base.markedTextBackgroundCornerRadius }

    func textColor(for highlightName: String) -> UIColor? { base.textColor(for: highlightName) }
    func fontTraits(for highlightName: String) -> FontTraits { base.fontTraits(for: highlightName) }
}

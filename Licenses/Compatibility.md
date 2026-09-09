# Dependency license review — 2026-09-05

Scope: the Swift pins in `Fila.xcodeproj/.../Package.resolved`, WebUI's production
npm dependencies, and the contents of libarchive 0.1.1, Runestone 0.3.1 and
libghostty-spm 1.5.20260903. Exact wrapper revisions and notice hashes are in
`review.json`. This is a source/notice audit, not legal certification.

The 2026-09-06 wrapper review advances libghostty-spm from `a2565cc` to
`733ae3b` (1.5.20260906). The diff changes only terminal configuration-file
placement, its lifecycle test and agent notes. `Package.swift`, the XCFramework
URL and checksum, bundled resources and all license files are unchanged; the
existing binary component inventory and notice hashes still apply.

The 2026-09-09 wrapper review advances libghostty-spm from `733ae3b`
(1.5.20260906) to `7e45d27` (1.6.20260909), and with it the upstream Ghostty ref
from `c4e1697` to `82938b6`. The wrapper's own Swift sources and its XCFramework
URL and checksum change; its LICENSE does not. Upstream's `build.zig.zon` moves
exactly two entries: the lazy `translate_c` build-time tool, now taken from
Codeberg, which produces no shipped code, and the `iterm2_themes` data archive.
The theme data does reach the app, but not from that archive — it arrives as
libghostty-spm's own generated `GhosttyTheme` catalogue, whose
iTerm2-Color-Schemes MIT notice is collected from the checkout as
`libghostty-spm/Sources/GhosttyTheme/LICENSE` and whose text is unchanged
across this bump. Every other dependency, and every notice hash, is unchanged.

No mandatory GPL/AGPL-only runtime component was identified that would require
relicensing Fila's own source away from MIT. This does **not** relicense the
whole application binary or its third-party components as MIT.

| Component | Finding and distribution action |
| --- | --- |
| Swift packages, React, React DOM, scheduler | MIT, BSD, ISC or Apache-2.0 notices retained in full, including NOTICE files and llhttp. Apache's terms continue to apply to its code. |
| libarchive.xcframework | Its composite LICENSE already includes libarchive, xz/liblzma, zstd and lz4, in addition to wrapper MIT. Retain the whole file. Apple SDK compression libraries are system dependencies. No liblzo2 is built by this wrapper. |
| Runestone | Include the editor's MIT notice, Tree-sitter runtime, language bindings, individual grammar notices and nvim-treesitter queries. Do not treat wrapper MIT as covering all grammars: Elixir and query sources include Apache-2.0. |
| Ghostty z2d | MPL-2.0, file-level copyleft. Its unchanged source remains MPL, and its exact source archive URL is shown in the bundled notice. Fila adds no modifications to z2d. MPL allows linking into a larger work under other terms. |
| Ghostty glslang | Its composite notice includes BSD/MIT/Apache terms and old Bison GPL text **with the Bison exception**. The exception permits a larger work under other terms. Preserve it with the full notice; a bare GPL keyword is not a conflict finding. |
| Ghostty fonts | JetBrains Mono has OFL-1.1. Nerd Fonts includes MIT and OFL notices; retain both the released font archive notice and Ghostty's vendor notice. Font licenses stay in force; bundling does not require the app's source to become OFL. |
| Other Ghostty components | Include libpng, zlib, Oniguruma, SPIRV-Cross, Highway, simdutf, Wuffs, libxev, vaxis, z2d, zig-objc, uucode and zf. simdutf's embedded header says **9.0.0**, despite an outdated 5.2.8 package field; the notice follows the actual header. Some composite source notices conservatively include optional upstream files. |
| Swift Crypto / BoringSSL | Include BoringSSL's exact pinned upstream LICENSE as well as Swift Crypto's Apache notice. System CryptoKit is used on supported Apple platforms; retaining the fallback's notices also covers its source distribution. |

## Remaining provenance limitation: Lua grammar

The vendored TreeSitterLanguages README points at `tjdevries/tree-sitter-lua`.
That repository has no standalone LICENSE file; Cargo.toml declares MIT, while
package.json declares ISC. Both declarations describe permissive terms, but this
is an upstream attribution/metadata inconsistency, **not a verified single
license grant for the exact generated parser**. The import stripped individual
revision provenance. We preserve both actual declarations and the standard
texts, and do not invent a copyright statement or substitute another author's
Lua grammar license. Obtain upstream clarification / exact import provenance
before describing this dependency audit as completely cleared for release.

Other grammar notices were recovered from their attributed upstreams; the
wrapper does not identify each imported parser commit. `notice.json` records
where each notice was recovered, rather than claiming a matching parser version.

## Primary references

- [Apache-2.0 redistribution terms, section 4](https://www.apache.org/licenses/LICENSE-2.0)
- [Mozilla MPL FAQ, Q8 and Q11: source availability and larger works](https://www.mozilla.org/en-US/MPL/2.0/FAQ/)
- [Bison output licensing exception](https://www.gnu.org/software/bison/manual/html_node/Conditions.html)
- [OFL FAQ: software bundling](https://openfontlicense.org/ofl-faq/)
- glslang's own pinned composite license and z2d's MPL text are included locally.

Future upgrades must repeat this audit. Matching a license name or scanning for
"GPL" cannot verify provenance, source availability, exceptions or compatibility.

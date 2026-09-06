# Bundled notices

Settings → About Fila → Licenses follows iGhostVT's component list and selectable
full-text reader, adapted to UIKit. Fila's own code stays MIT; third-party code
and fonts retain their respective licenses.

`Scripts/collect-licenses.py` runs after Build Web UI, offline, on every app
build. It collects Fila's LICENSE, notices in every resolved Swift checkout
(including nested notices), WebUI's production npm dependencies, and these
vendored notices. The generated `Fila.app/Licenses.json` travels in all four
wrappers. It is not linked into filad.

Each subdirectory has the full notice and `notice.json` with its source URL,
content hash and, where available, version. Ghostty's version comes from the
resolved wrapper's `Ghostty.version`. Archive URLs identify the exact dependency
sources from Ghostty's pinned `build.zig.zon`; Runestone's editor notice comes
from its pinned `Upstream.versions`. Grammar source URLs follow the vendored
TreeSitterLanguages attribution list. Those grammar imports do not record
individual upstream revisions; their recovered notices are snapshots, not a
claim that current upstream HEAD is the parser revision. Lua's missing license
file and contradictory metadata are documented explicitly in its notice and
in the review below.

`review.json` records the reviewed text hash and display label of every notice,
and the three reviewed XCFramework wrapper revisions. A changed or missing
notice, a newly discovered component, or a binary upgrade fails collection.
Recheck the component inventory and conditions before updating this file. The
labels are reviewed descriptions, not a keyword-based compatibility verdict.

See [Compatibility review](Compatibility.md) for the findings and their limits.

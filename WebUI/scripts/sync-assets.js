// Pulls everything the page shares with the app out of the app's own sources,
// so there is one accent colour and one extension table in the repository.
// Row icons are not here: the server draws the device's own at runtime
// (`/_fila/icon-…png`). Runs before every webpack build; output lives in
// src/generated and is not checked in.
const fs = require('fs');
const path = require('path');

const repo = path.resolve(__dirname, '..', '..');
const assets = path.join(repo, 'Fila/Resources/Assets.xcassets');
const out = path.join(__dirname, '..', 'src', 'generated');
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });

// Accent colour: AccentColor.colorset, light and dark appearances.
const colorset = JSON.parse(fs.readFileSync(path.join(assets, 'AccentColor.colorset/Contents.json'), 'utf8'));
const hex = (c) =>
  '#' +
  ['red', 'green', 'blue']
    .map((k) => Math.round(parseFloat(c.components[k]) * 255).toString(16).padStart(2, '0'))
    .join('');
const light = colorset.colors.find((c) => !c.appearances);
const dark = colorset.colors.find((c) => c.appearances?.some((a) => a.value === 'dark'));
if (!light || !dark) throw new Error('AccentColor.colorset needs a light and a dark colour');
const accentLight = hex(light.color);
const accentDark = hex(dark.color);
fs.writeFileSync(
  path.join(out, 'accent.css'),
  `/* generated from Assets.xcassets/AccentColor.colorset */\n:root { --accent: ${accentLight}; }\n@media (prefers-color-scheme: dark) { :root { --accent: ${accentDark}; } }\n`,
);

// The app mark, light and dark, from Scripts/make-app-mark.swift's output.
// Renamed without the "@": the server serves /_fila/ files by a plain name.
for (const appearance of ['light', 'dark']) {
  for (const scale of [2, 3]) {
    fs.copyFileSync(
      path.join(assets, 'AppIconMark.imageset', `mark-${appearance}@${scale}x.png`),
      path.join(out, `mark-${appearance}-${scale}x.png`),
    );
  }
}

// Extension → format, read off FileFormat.swift's own switch so the two never drift.
const swift = fs.readFileSync(path.join(repo, 'Packages/FilaKit/Sources/FilaFormats/FileFormat.swift'), 'utf8');
const table = swift.slice(swift.indexOf('func extensionMatch'));
const formats = {};
for (const m of table.matchAll(/case\s+((?:"[^"]+",?\s*)+):\s*(?:return\s+)?\.(\w+)/g)) {
  for (const ext of m[1].match(/"([^"]+)"/g)) formats[ext.slice(1, -1)] = m[2];
}
if (!formats.plist || !formats.zip) throw new Error('could not read extensionMatch from FileFormat.swift');
fs.writeFileSync(path.join(out, 'formats.json'), JSON.stringify(formats, null, 2) + '\n');

console.log(`synced accent ${accentLight}/${accentDark}, ${Object.keys(formats).length} extensions`);

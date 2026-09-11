import formats from './generated/formats.json';
import { Item } from './dav';

function extensionOf(name: string): string {
  const dot = name.lastIndexOf('.');
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : '';
}

const formatOf = (item: Item) => (formats as Record<string, string>)[extensionOf(item.name)];

/// The picture the app draws for the item, served by the app itself: the page
/// ships no artwork, and the server answers `/_fila/icon-<dir|file>[-<ext>].png`
/// with the device's own icon for that type. One URL per type, so the browser
/// caches it once for every file that shares it.
export function iconFor(item: Item): string {
  const type = extensionOf(item.name).replace(/[^a-z0-9]/g, '');
  return `/_fila/icon-${item.isFolder ? 'dir' : 'file'}${type ? '-' + type : ''}.png`;
}

/// What QuickLook can turn into a picture: images, video and PDF.
export function hasThumbnail(item: Item): boolean {
  const format = formatOf(item);
  return !item.isFolder && (format === 'image' || format === 'video' || format === 'pdf');
}

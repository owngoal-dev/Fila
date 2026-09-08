import formats from './generated/formats.json';
import { Item } from './dav';
import folder from './generated/icons/folder.png';
import application from './generated/icons/application.png';
import document from './generated/icons/document.png';
import plist from './generated/icons/plist.png';
import executable from './generated/icons/executable.png';
import archive from './generated/icons/archive.png';
import image from './generated/icons/image.png';
import audio from './generated/icons/audio.png';
import video from './generated/icons/video.png';
import pdf from './generated/icons/pdf.png';
import text from './generated/icons/text.png';

/// The same artwork the app draws, chosen the same way `FilePresentation` chooses it
/// from the name alone. The PNGs are emitted beside app.js by webpack.
const artwork: Record<string, string> = {
  folder,
  application,
  document,
  plist,
  executable,
  archive,
  image,
  audio,
  video,
  pdf,
  text,
};

const byFormat: Record<string, string> = {
  propertyList: 'plist',
  machO: 'executable',
  archive: 'archive',
  image: 'image',
  audio: 'audio',
  video: 'video',
  pdf: 'pdf',
  text: 'text',
};

function extensionOf(name: string): string {
  const dot = name.lastIndexOf('.');
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : '';
}

const formatOf = (item: Item) => (formats as Record<string, string>)[extensionOf(item.name)];

export function iconFor(item: Item): string {
  if (item.isFolder) return artwork[extensionOf(item.name) === 'app' ? 'application' : 'folder'];
  return artwork[byFormat[formatOf(item)] ?? 'document'];
}

/// What QuickLook can turn into a picture: images, video and PDF.
export function hasThumbnail(item: Item): boolean {
  const format = formatOf(item);
  return !item.isFolder && (format === 'image' || format === 'video' || format === 'pdf');
}

import { t } from './i18n';

/// The WebDAV client side. Every path handled here is an encoded, origin-relative
/// pathname; folders end in `/`. Nothing else in the UI builds a URL.

export interface Item {
  path: string;
  name: string;
  isFolder: boolean;
  size: number;
  modified: string;
}

export class DavError extends Error {
  status?: number;
}

export function canonical(raw: string, directory = false): string {
  const u = new URL(raw, location.origin);
  if (u.origin !== location.origin || u.username || u.password || u.search || u.hash) {
    throw new DavError(t('invalidListing'));
  }
  const parts = u.pathname
    .split('/')
    .filter(Boolean)
    .map((p) => {
      const decoded = decodeURIComponent(p);
      if (decoded.includes('/') || decoded.includes('\0') || decoded === '.' || decoded === '..') {
        throw new DavError(t('invalidListing'));
      }
      return encodeURIComponent(decoded);
    });
  return '/' + parts.join('/') + (directory && parts.length ? '/' : '');
}

export function folder(path: string): string {
  return path === '/' ? '/' : path.replace(/\/$/, '') + '/';
}

export function display(path: string): string {
  return path.split('/').map(decodeURIComponent).join('/');
}

export function parent(path: string): string {
  const parts = path.split('/').filter(Boolean);
  parts.pop();
  return parts.length ? '/' + parts.join('/') + '/' : '/';
}

export function validateName(name: string): void {
  if (!name || name === '.' || name === '..' || name.includes('/') || name.includes('\0')) {
    throw new DavError(t('invalid'));
  }
}

export function child(path: string, name: string, isFolder = false): string {
  validateName(name);
  return folder(path) + encodeURIComponent(name) + (isFolder ? '/' : '');
}

function errorFor(status: number): DavError {
  const known: Record<number, string> = {
    403: t('denied'),
    404: t('notfound'),
    409: t('conflict'),
    412: t('conflict'),
    423: t('locked'),
    507: t('space'),
  };
  const e = new DavError(known[status] || t('failed', status));
  e.status = status;
  return e;
}

export async function request(
  path: string,
  method: string,
  options: { headers?: Record<string, string>; body?: BodyInit; signal?: AbortSignal } = {},
): Promise<Response> {
  let response: Response;
  try {
    response = await fetch(path, {
      method,
      body: options.body,
      signal: options.signal,
      headers: options.headers,
      credentials: 'same-origin',
      cache: 'no-store',
      redirect: 'error',
    });
  } catch (e) {
    if ((e as Error).name === 'AbortError') throw e;
    throw new DavError(t('network'));
  }
  if (!response.ok) throw errorFor(response.status);
  // 202 and a non-PROPFIND 207 both mean "accepted, outcome unknown".
  if (response.status === 202 || (response.status === 207 && method !== 'PROPFIND')) {
    throw new DavError(t('uncertain'));
  }
  return response;
}

export async function list(path: string, signal?: AbortSignal): Promise<Item[]> {
  const response = await request(path, 'PROPFIND', { signal, headers: { Depth: '1' } });
  if (response.status !== 207) throw new DavError(t('invalidListing'));
  const doc = new DOMParser().parseFromString(await response.text(), 'application/xml');
  if (doc.getElementsByTagName('parsererror').length) throw new DavError(t('invalidListing'));
  const items: Item[] = [];
  const seen = new Set<string>();
  for (const node of Array.from(doc.getElementsByTagNameNS('DAV:', 'response'))) {
    const text = (name: string) => node.getElementsByTagNameNS('DAV:', name)[0]?.textContent || '';
    const href = text('href');
    if (!href) continue;
    const isFolder = node.getElementsByTagNameNS('DAV:', 'collection').length > 0;
    const pathValue = canonical(href, isFolder);
    if (folder(pathValue) === folder(path) || parent(pathValue) !== folder(path) || seen.has(pathValue)) continue;
    const status = text('status');
    if (status && !/^HTTP\/\S+ 2\d\d\b/.test(status)) continue;
    seen.add(pathValue);
    items.push({
      path: pathValue,
      name: decodeURIComponent(pathValue.split('/').filter(Boolean).pop()!),
      isFolder,
      size: Number(text('getcontentlength')) || 0,
      modified: text('getlastmodified'),
    });
  }
  return items.sort(
    (a, b) =>
      Number(b.isFolder) - Number(a.isFolder) ||
      a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' }),
  );
}

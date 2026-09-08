import { DragEvent, Fragment, useCallback, useEffect, useRef, useState } from 'react';
import { DavError, Item, canonical, child, list, parent, request } from './dav';
import { DeleteDialog, Destination, DestinationDialog, NameDialog } from './Dialogs';
import { bytes, date, t } from './i18n';
import { hasThumbnail, iconFor } from './icons';
import markLight from './generated/mark-light-2x.png';
import markDark from './generated/mark-dark-2x.png';

type Dialog =
  | { kind: 'name'; title: string; label: string; value: string; message?: string; resolve: (v: string | null) => void }
  | { kind: 'delete'; items: Item[]; resolve: (v: boolean) => void }
  | { kind: 'destination'; items: Item[]; action: string; resolve: (v: Destination | null) => void };

type Notice = { text: string; error: boolean };

/// The app's own artwork for the file's kind; media rows ask the server for a
/// QuickLook thumbnail (`?thumbnail=<px>`) instead, lazily as they scroll into
/// view, and fall back to the artwork when it has none. HEIC and video are why
/// this is not an <img> of the file itself.
function Thumb({ item }: { item: Item }) {
  const [failed, setFailed] = useState(false);
  if (failed || !hasThumbnail(item)) return <img className="fileicon" src={iconFor(item)} alt="" />;
  return <img className="thumb" src={item.path + '?thumbnail=64'} alt="" loading="lazy" decoding="async" onError={() => setFailed(true)} />;
}

export function App() {
  const [path, setPath] = useState('/');
  const [items, setItems] = useState<Item[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [filter, setFilter] = useState('');
  const [selection, setSelection] = useState<Set<string>>(new Set());
  const [notice, setNotice] = useState<Notice | null>(null);
  const [dialog, setDialog] = useState<Dialog | null>(null);
  const [menuFor, setMenuFor] = useState<string | null>(null);
  const [dropping, setDropping] = useState(false);

  // Async guards live in refs: a click handler needs the value now, not the
  // value the render it was created in had.
  const busyRef = useRef(false);
  const pathRef = useRef('/');
  const listID = useRef(0);
  const listAbort = useRef<AbortController | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);

  const setBusyState = (value: boolean) => {
    busyRef.current = value;
    setBusy(value);
  };

  const navigate = useCallback(async (raw: string, options: { preserve?: boolean; history?: boolean } = {}) => {
    if (busyRef.current) return;
    let target: string;
    try {
      target = canonical(raw, true);
    } catch (e) {
      setNotice({ text: (e as Error).message, error: true });
      return;
    }
    const id = ++listID.current;
    listAbort.current?.abort();
    const abort = new AbortController();
    listAbort.current = abort;
    setLoading(true);
    try {
      const entries = await list(target, abort.signal);
      if (id !== listID.current) return;
      const same = pathRef.current === target;
      pathRef.current = target;
      setPath(target);
      setItems(entries);
      setLoaded(true);
      setSelection((s) => (same && options.preserve ? new Set([...s].filter((p) => entries.some((i) => i.path === p))) : new Set()));
      if (!same) setFilter('');
      if (options.history !== false && location.pathname !== target) history.pushState(null, '', target);
    } catch (e) {
      if ((e as Error).name !== 'AbortError' && id === listID.current) {
        setNotice({ text: (e as Error).message, error: true });
        if (options.history === false) history.replaceState(null, '', pathRef.current);
      }
    } finally {
      if (id === listID.current) setLoading(false);
    }
  }, []);

  useEffect(() => {
    navigate(location.pathname, { history: false });
    const pop = () => {
      if (busyRef.current) history.pushState(null, '', pathRef.current);
      else navigate(location.pathname, { history: false });
    };
    window.addEventListener('popstate', pop);
    return () => window.removeEventListener('popstate', pop);
  }, [navigate]);

  useEffect(() => {
    if (!menuFor) return;
    const close = () => setMenuFor(null);
    document.addEventListener('click', close);
    return () => document.removeEventListener('click', close);
  }, [menuFor]);

  // Dialogs are promises so the operations below read top to bottom.
  const ask = <T,>(make: (resolve: (v: T) => void) => Dialog) =>
    new Promise<T>((resolve) => {
      setDialog(make((v) => (setDialog(null), resolve(v))));
    });

  /// One mutation after another, then a refresh that keeps whatever survived.
  const runBatch = async (names: string[], action: (index: number) => Promise<unknown>, done: (index: number) => void) => {
    if (busyRef.current) return;
    listID.current++;
    listAbort.current?.abort();
    setBusyState(true);
    setMenuFor(null);
    let completed = 0;
    let failure: Error | null = null;
    try {
      for (let i = 0; i < names.length; i++) {
        setNotice({ text: t('batch', i + 1, names.length, names[i]), error: false });
        await action(i);
        completed++;
        done(i);
      }
    } catch (e) {
      failure = e as Error;
    } finally {
      setBusyState(false);
      await navigate(pathRef.current, { preserve: true });
      setNotice({ text: failure ? `${t('partial', completed)} ${failure.message}` : t('done', completed), error: !!failure });
    }
  };

  const operate = async (key: 'rename' | 'copy' | 'move' | 'delete', targets: Item[]) => {
    if (busyRef.current || !targets.length || dialog) return;
    const forget = (i: number) => setSelection((s) => (s.delete(targets[i].path), new Set(s)));
    const names = targets.map((i) => i.name);
    if (key === 'delete') {
      if (await ask<boolean>((resolve) => ({ kind: 'delete', items: targets, resolve }))) {
        await runBatch(names, (i) => request(targets[i].path, 'DELETE'), forget);
      }
      return;
    }
    if (key === 'rename') {
      const item = targets[0];
      const name = await ask<string | null>((resolve) => ({ kind: 'name', title: t('rename'), label: t('filename'), value: item.name, resolve }));
      if (name === null || name === item.name) return;
      await runBatch(
        [item.name],
        () =>
          request(item.path, 'MOVE', {
            headers: { Destination: new URL(child(parent(item.path), name, item.isFolder), location.origin).href, Overwrite: 'F' },
          }),
        forget,
      );
      return;
    }
    const destination = await ask<Destination | null>((resolve) => ({ kind: 'destination', items: targets, action: t(key), resolve }));
    if (!destination) return;
    await runBatch(
      names,
      (i) =>
        request(targets[i].path, key === 'copy' ? 'COPY' : 'MOVE', {
          headers: {
            Destination: new URL(child(destination.path, destination.name ?? targets[i].name, targets[i].isFolder), location.origin).href,
            Overwrite: 'F',
            Depth: 'infinity',
          },
        }),
      forget,
    );
  };

  const newFolder = async () => {
    if (busyRef.current || dialog) return;
    const where = pathRef.current;
    const name = await ask<string | null>((resolve) => ({ kind: 'name', title: t('newfolder'), label: t('foldername'), value: '', resolve }));
    if (name !== null) await runBatch([name], () => request(child(where, name, true), 'MKCOL'), () => {});
  };

  const upload = async (files: File[]) => {
    if (!files.length || busyRef.current || dialog) return;
    const where = pathRef.current;
    listID.current++;
    listAbort.current?.abort();
    setBusyState(true);
    let completed = 0;
    let failure: Error | null = null;
    try {
      for (let i = 0; i < files.length; i++) {
        let name: string | null = files[i].name;
        while (name !== null) {
          setNotice({ text: t('uploading', i + 1, files.length, name), error: false });
          try {
            await request(child(where, name), 'PUT', {
              headers: { 'If-None-Match': '*', 'Content-Type': 'application/octet-stream' },
              body: files[i],
            });
            completed++;
            break;
          } catch (e) {
            if ((e as DavError).status !== 412) throw e;
            const taken: string = name;
            name = await ask<string | null>((resolve) => ({ kind: 'name', title: t('uploadName'), label: t('filename'), value: taken, message: t('exists'), resolve }));
          }
        }
      }
    } catch (e) {
      failure = e as Error;
    } finally {
      setBusyState(false);
      await navigate(where, { preserve: true });
      setNotice({ text: failure ? `${t('partial', completed)} ${failure.message}` : t('done', completed), error: !!failure });
    }
  };

  /// One browser download per selected file, spaced so the browser's
  /// multiple-download prompt sees them as one batch. Folders are skipped:
  /// there is no archive endpoint, and inventing one here would put a tree
  /// walk in the server.
  const download = (targets: Item[]) => {
    targets
      .filter((i) => !i.isFolder)
      .forEach((item, index) => {
        setTimeout(() => {
          const a = document.createElement('a');
          a.href = item.path;
          a.download = item.name;
          a.click();
        }, index * 300);
      });
  };

  const onDrop = (e: DragEvent) => {
    e.preventDefault();
    setDropping(false);
    upload(Array.from(e.dataTransfer.files));
  };

  const shown = items.filter((i) => i.name.toLocaleLowerCase().includes(filter.toLocaleLowerCase()));
  const selected = items.filter((i) => selection.has(i.path));
  const allShown = shown.length > 0 && shown.every((i) => selection.has(i.path));
  const someShown = shown.some((i) => selection.has(i.path));
  const toggle = (item: Item) => setSelection((s) => (s.has(item.path) ? s.delete(item.path) : s.add(item.path), new Set(s)));
  const toggleAll = () =>
    setSelection((s) => {
      for (const i of shown) allShown ? s.delete(i.path) : s.add(i.path);
      return new Set(s);
    });

  const crumbs = path.split('/').filter(Boolean);

  return (
    <>
      <header className="header">
        <a className="brand" href="/" onClick={(e) => (e.preventDefault(), navigate('/'))}>
          <picture>
            <source srcSet={markDark} media="(prefers-color-scheme: dark)" />
            <img className="brand-mark" src={markLight} alt="" />
          </picture>
          Fila
        </a>
        <span className="muted mono">{location.host}</span>
      </header>

      <main className="main">
        <div className="toolbar">
          <nav className="crumbs" aria-label={t('path')}>
            <button type="button" onClick={() => navigate('/')}>
              {t('root')}
            </button>
            {crumbs.map((part, i) => (
              <Fragment key={i}>
                <span className="sep">/</span>
                <button type="button" onClick={() => navigate('/' + crumbs.slice(0, i + 1).join('/') + '/')}>
                  {decodeURIComponent(part)}
                </button>
              </Fragment>
            ))}
          </nav>
          <input className="filter" placeholder={t('filter')} aria-label={t('filter')} value={filter} onChange={(e) => setFilter(e.target.value)} />
          <button type="button" className="btn icon" aria-label={t('refresh')} title={t('refresh')} disabled={busy} onClick={() => (setNotice(null), navigate(path, { preserve: true }))}>
            ↻
          </button>
          <button type="button" className="btn" disabled={busy} onClick={newFolder}>
            {t('newfolder')}
          </button>
          <button type="button" className="btn primary" disabled={busy} onClick={() => fileInput.current?.click()}>
            {t('upload')}
          </button>
          <input ref={fileInput} type="file" multiple hidden onChange={(e) => (upload(Array.from(e.target.files || [])), (e.target.value = ''))} />
        </div>

        {notice && (
          <div className={notice.error ? 'notice error' : 'notice'} role="status">
            <span>{notice.text}</span>
            {!busy && (
              <button type="button" aria-label={t('dismiss')} onClick={() => setNotice(null)}>
                ✕
              </button>
            )}
          </div>
        )}

        <section
          className={dropping ? 'panel dropping' : 'panel'}
          data-drop={t('drop')}
          onDragOver={(e) => (e.preventDefault(), !busy && setDropping(true))}
          onDragLeave={() => setDropping(false)}
          onDrop={onDrop}
        >
          {(loading || busy) && <div className="progress" aria-hidden="true" />}
          <table>
            <thead>
              <tr>
                <th className="col-check">
                  <input type="checkbox" aria-label={t('selectall')} checked={allShown} ref={(el) => {
                      if (el) el.indeterminate = someShown && !allShown;
                    }} disabled={busy || !shown.length} onChange={toggleAll} />
                </th>
                {selected.length ? (
                  <th colSpan={4}>
                    <div className="bulk">
                      <span className="count">{t('selected', selected.length)}</span>
                      <button type="button" className="btn" disabled={busy || !selected.some((i) => !i.isFolder)} onClick={() => download(selected)}>
                        {t('download')}
                      </button>
                      <button type="button" className="btn" disabled={busy} onClick={() => operate('copy', selected)}>
                        {t('copy')}
                      </button>
                      <button type="button" className="btn" disabled={busy} onClick={() => operate('move', selected)}>
                        {t('move')}
                      </button>
                      <button type="button" className="btn danger" disabled={busy} onClick={() => operate('delete', selected)}>
                        {t('delete')}
                      </button>
                    </div>
                  </th>
                ) : (
                  <>
                    <th>{t('name')}</th>
                    <th className="col-size">{t('size')}</th>
                    <th className="col-date">{t('modified')}</th>
                    <th className="col-more" />
                  </>
                )}
              </tr>
            </thead>
            <tbody className={loading ? 'loading' : undefined}>
              {shown.map((item) => (
                <tr key={item.path} className={selection.has(item.path) ? 'selected' : undefined}>
                  <td className="col-check">
                    <input type="checkbox" aria-label={t('select', item.name)} checked={selection.has(item.path)} disabled={busy} onChange={() => toggle(item)} />
                  </td>
                  <td>
                    <div className="name">
                      <Thumb item={item} />
                      {item.isFolder ? (
                        <button type="button" title={item.name} onClick={() => navigate(item.path)}>
                          {item.name}
                        </button>
                      ) : (
                        <a href={item.path} download={item.name} title={item.name}>
                          {item.name}
                        </a>
                      )}
                    </div>
                  </td>
                  <td className="col-size muted">{item.isFolder ? '—' : bytes(item.size)}</td>
                  <td className="col-date muted">{date(item.modified)}</td>
                  <td className="col-more">
                    <span className="menu-anchor" onClick={(e) => e.stopPropagation()}>
                      <button type="button" className="btn plain" aria-label={t('more', item.name)} aria-expanded={menuFor === item.path} onClick={() => setMenuFor(menuFor === item.path ? null : item.path)}>
                        ⋯
                      </button>
                      {menuFor === item.path && (
                        <div className="menu" role="menu">
                          {!item.isFolder && (
                            <a href={item.path} download={item.name} onClick={() => setMenuFor(null)}>
                              {t('download')}
                            </a>
                          )}
                          {(['rename', 'copy', 'move'] as const).map((key) => (
                            <button type="button" key={key} disabled={busy} onClick={() => operate(key, [item])}>
                              {t(key)}
                            </button>
                          ))}
                          <hr />
                          <button type="button" className="danger" disabled={busy} onClick={() => operate('delete', [item])}>
                            {t('delete')}
                          </button>
                        </div>
                      )}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {shown.length === 0 && <div className="empty">{!loaded ? t('loading') : items.length ? t('nomatch') : t('empty')}</div>}
          <div className="footer">{t('items', items.length)}</div>
        </section>
      </main>

      {dialog?.kind === 'name' && <NameDialog title={dialog.title} label={dialog.label} value={dialog.value} message={dialog.message} onDone={dialog.resolve} />}
      {dialog?.kind === 'delete' && <DeleteDialog items={dialog.items} onDone={dialog.resolve} />}
      {dialog?.kind === 'destination' && <DestinationDialog items={dialog.items} action={dialog.action} start={path} onDone={dialog.resolve} />}
    </>
  );
}

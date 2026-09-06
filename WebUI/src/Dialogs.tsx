import { FormEvent, ReactNode, useEffect, useRef, useState } from 'react';
import { Item, child, display, folder, list, parent, validateName } from './dav';
import { t } from './i18n';

/// A native <dialog>: focus trap, Escape and backdrop come from the browser.
function Modal({
  title,
  submit,
  danger,
  disabled,
  error,
  onSubmit,
  onCancel,
  children,
}: {
  title: string;
  submit: string;
  danger?: boolean;
  disabled?: boolean;
  error?: string | null;
  onSubmit: () => void;
  onCancel: () => void;
  children: ReactNode;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    ref.current?.showModal();
  }, []);
  const handle = (e: FormEvent) => {
    e.preventDefault();
    onSubmit();
  };
  return (
    <dialog ref={ref} className="modal" onCancel={(e) => (e.preventDefault(), onCancel())}>
      <form onSubmit={handle}>
        <h2>{title}</h2>
        <div className="modal-body">{children}</div>
        {error && (
          <p className="error" role="alert">
            {error}
          </p>
        )}
        <div className="modal-actions">
          <button type="button" className="btn" onClick={onCancel}>
            {t('cancel')}
          </button>
          <button type="submit" className={danger ? 'btn danger' : 'btn primary'} disabled={disabled}>
            {submit}
          </button>
        </div>
      </form>
    </dialog>
  );
}

export function NameDialog({
  title,
  label,
  value,
  message,
  onDone,
}: {
  title: string;
  label: string;
  value: string;
  message?: string;
  onDone: (name: string | null) => void;
}) {
  const [name, setName] = useState(value);
  const [error, setError] = useState<string | null>(null);
  const submit = () => {
    try {
      validateName(name);
      onDone(name);
    } catch (e) {
      setError((e as Error).message);
    }
  };
  return (
    <Modal title={title} submit={title} error={error} onSubmit={submit} onCancel={() => onDone(null)}>
      {message && <p>{message}</p>}
      <label>
        {label}
        <input autoFocus value={name} onChange={(e) => setName(e.target.value)} onFocus={(e) => e.target.select()} />
      </label>
    </Modal>
  );
}

export function DeleteDialog({ items, onDone }: { items: Item[]; onDone: (confirmed: boolean) => void }) {
  return (
    <Modal title={t('deleteTitle')} submit={t('delete')} danger onSubmit={() => onDone(true)} onCancel={() => onDone(false)}>
      <p>{t('deleteWarning')}</p>
      <ul className="namelist">
        {items.map((i) => (
          <li key={i.path}>{i.name}</li>
        ))}
      </ul>
    </Modal>
  );
}

export interface Destination {
  path: string;
  name?: string;
}

export function DestinationDialog({
  items,
  action,
  start,
  onDone,
}: {
  items: Item[];
  action: string;
  start: string;
  onDone: (destination: Destination | null) => void;
}) {
  const [current, setCurrent] = useState(start);
  const [folders, setFolders] = useState<Item[] | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [name, setName] = useState(items.length === 1 ? items[0].name : undefined);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const abort = new AbortController();
    setFolders(null);
    setLoadError(null);
    list(current, abort.signal)
      .then((entries) =>
        setFolders(
          entries.filter(
            (i) => i.isFolder && !items.some((s) => s.isFolder && i.path.startsWith(folder(s.path))),
          ),
        ),
      )
      .catch((e: Error) => {
        if (e.name !== 'AbortError') setLoadError(e.message);
      });
    return () => abort.abort();
  }, [current, items]);

  const submit = () => {
    try {
      if (name !== undefined) validateName(name);
      for (const item of items) {
        const target = child(current, name ?? item.name, item.isFolder);
        if (folder(target) === folder(item.path) || (item.isFolder && target.startsWith(folder(item.path)))) {
          throw new Error(t('same'));
        }
      }
      onDone({ path: current, name });
    } catch (e) {
      setError((e as Error).message);
    }
  };

  return (
    <Modal title={t('choose')} submit={action} disabled={!folders} error={error} onSubmit={submit} onCancel={() => onDone(null)}>
      <div className="picker">
        <div className="picker-path">
          <button type="button" className="btn icon" aria-label={t('up')} disabled={current === '/'} onClick={() => setCurrent(parent(current))}>
            ↑
          </button>
          <span className="mono">{display(current)}</span>
        </div>
        <div className="picker-list">
          {folders === null && !loadError && <p className="muted">{t('loading')}</p>}
          {loadError && <p className="error">{loadError}</p>}
          {folders && folders.length === 0 && <p className="muted">{t('folders')}</p>}
          {folders?.map((f) => (
            <button type="button" key={f.path} onClick={() => setCurrent(f.path)}>
              <FolderIcon /> {f.name}
            </button>
          ))}
        </div>
      </div>
      {name !== undefined && (
        <label>
          {t('filename')}
          <input value={name} onChange={(e) => setName(e.target.value)} />
        </label>
      )}
    </Modal>
  );
}

export function FolderIcon() {
  return (
    <svg className="glyph" viewBox="0 0 16 16" aria-hidden="true">
      <path d="M1.5 3.5A1.5 1.5 0 0 1 3 2h3.2l1.6 1.5H13a1.5 1.5 0 0 1 1.5 1.5v7A1.5 1.5 0 0 1 13 13.5H3A1.5 1.5 0 0 1 1.5 12z" />
    </svg>
  );
}

export function FileIcon() {
  return (
    <svg className="glyph" viewBox="0 0 16 16" aria-hidden="true">
      <path d="M3.5 2A1.5 1.5 0 0 1 5 .5h4.3L13.5 4.7V14A1.5 1.5 0 0 1 12 15.5H5A1.5 1.5 0 0 1 3.5 14zM9 1.5V5h3.5" />
    </svg>
  );
}

const en = {
  newfolder: 'New Folder',
  folder: 'Folder',
  upload: 'Upload',
  copy: 'Copy',
  move: 'Move',
  delete: 'Delete',
  name: 'Name',
  size: 'Size',
  modified: 'Modified',
  cancel: 'Cancel',
  root: 'Root',
  path: 'Path',
  refresh: 'Refresh',
  filter: 'Filter',
  selectall: 'Select All',
  download: 'Download',
  rename: 'Rename',
  choose: 'Choose Folder',
  foldername: 'Folder name',
  filename: 'Name',
  empty: 'This folder is empty. Upload a file or create a folder.',
  nomatch: 'No items match the filter. Try a different filter.',
  loading: 'Loading…',
  folders: 'This folder has no subfolders.',
  selected: (n: number) => `${n} selected`,
  items: (n: number) => (n === 1 ? `${n} item` : `${n} items`),
  done: (n: number) => `${n} completed.`,
  invalid: 'Enter a name that does not contain “/” and is not “.” or “..”.',
  deleteTitle: 'Delete Permanently?',
  deleteWarning:
    'This permanently deletes everything listed below, including folder contents. This cannot be undone.',
  destination: 'Destination',
  uploadName: 'Choose Another Name',
  exists: 'An item with this name already exists. Choose a different name, or cancel to skip this file.',
  network: 'The connection was interrupted. Refresh to see the result before trying again.',
  denied: 'You do not have permission for this operation. Check the item on your device and try again.',
  notfound: 'The item no longer exists. Refresh and try again.',
  conflict: 'The destination is unavailable or that name is in use. Choose a different name or folder.',
  locked: 'This item is locked. Try again later.',
  space: 'There is not enough space to complete this operation. Free up space on the device and try again.',
  failed: (n: number) => `The operation could not be completed. Try again.`,
  invalidListing: 'This folder could not be read. Refresh and try again.',
  partial: (n: number) => `${n} completed before the operation stopped.`,
  same: 'The item is already in this folder, or this folder is inside the item. Choose a different folder.',
  uploading: (n: number, total: number, name: string) => `Uploading ${n} of ${total}: ${name}…`,
  batch: (n: number, total: number, name: string) => `Processing ${n} of ${total}: ${name}…`,
  up: 'Parent Folder',
  uncertain: 'This operation may not have finished. Refresh before trying again.',
  select: (n: string) => `Select ${n}`,
  more: (n: string) => `Actions for ${n}`,
  drop: 'Drop files to upload',
  dismiss: 'Dismiss',
};

type Words = typeof en;

const zh: Words = {
  newfolder: '新建文件夹',
  folder: '文件夹',
  upload: '上传',
  copy: '复制',
  move: '移动',
  delete: '删除',
  name: '名称',
  size: '大小',
  modified: '修改时间',
  cancel: '取消',
  root: '根目录',
  path: '路径',
  refresh: '刷新',
  filter: '筛选',
  selectall: '全选',
  download: '下载',
  rename: '重命名',
  choose: '选择文件夹',
  foldername: '文件夹名称',
  filename: '名称',
  empty: '此文件夹为空。上传文件或新建文件夹。',
  nomatch: '没有符合筛选条件的项目。请尝试其他筛选条件。',
  loading: '正在加载…',
  folders: '此文件夹没有子文件夹。',
  selected: (n) => `已选择 ${n} 项`,
  items: (n) => `${n} 项`,
  done: (n) => `已完成 ${n} 项。`,
  invalid: '名称不能包含“/”，也不能为“.”或“..”。',
  deleteTitle: '永久删除？',
  deleteWarning: '这些项目及文件夹内的所有内容都将被永久删除。此操作无法撤销。',
  destination: '目标位置',
  uploadName: '选择其他名称',
  exists: '已存在同名项目。请选择其他名称，或取消以跳过此文件。',
  network: '连接已中断。请先刷新查看结果，再重试。',
  denied: '没有执行此操作的权限。请在设备上检查该项目后再试。',
  notfound: '此项目已不存在。请刷新后再试。',
  conflict: '目标不可用，或名称已被占用。请选择其他名称或文件夹。',
  locked: '此项目已锁定。请稍后再试。',
  space: '没有足够的空间来完成此操作。请在设备上腾出空间后再试。',
  failed: (n) => `无法完成此操作。请重试。`,
  invalidListing: '无法读取此文件夹。请刷新后再试。',
  partial: (n) => `操作停止前已完成 ${n} 项。`,
  same: '此项目已在该文件夹中，或该文件夹位于此项目内。请选择其他文件夹。',
  uploading: (n, total, name) => `正在上传 ${n}/${total}：${name}…`,
  batch: (n, total, name) => `正在处理 ${n}/${total}：${name}…`,
  up: '上级文件夹',
  uncertain: '此操作可能尚未完成。请先刷新再重试。',
  select: (n) => `选择 ${n}`,
  more: (n) => `${n} 的操作`,
  drop: '拖放文件以上传',
  dismiss: '关闭',
};

export const lang: 'en' | 'zh' = navigator.language.toLowerCase().startsWith('zh') ? 'zh' : 'en';
const words = lang === 'zh' ? zh : en;

type Args<K extends keyof Words> = Words[K] extends (...a: infer A) => string ? A : [];

export function t<K extends keyof Words>(key: K, ...args: Args<K>): string {
  const value = words[key];
  return typeof value === 'function' ? (value as (...a: unknown[]) => string)(...args) : value;
}

export function bytes(n: number): string {
  if (n < 1024) return `${n} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let i = -1;
  do {
    n /= 1024;
    i++;
  } while (n >= 1024 && i < units.length - 1);
  return `${new Intl.NumberFormat(lang, { maximumFractionDigits: 1 }).format(n)} ${units[i]}`;
}

export function date(value: string): string {
  const d = new Date(value);
  return Number.isNaN(d.getTime())
    ? '—'
    : new Intl.DateTimeFormat(lang, { dateStyle: 'medium', timeStyle: 'short' }).format(d);
}

import { createRoot } from 'react-dom/client';
import { App } from './App';
import { lang } from './i18n';
import markLight from './generated/mark-light-2x.png';
import markDark from './generated/mark-dark-2x.png';
import touchIcon from './generated/mark-light-3x.png';
import './styles.css';

document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';

// The favicon is the app icon, following the tab's colour scheme.
for (const [href, media, rel] of [
  [markLight, '(prefers-color-scheme: light)', 'icon'],
  [markDark, '(prefers-color-scheme: dark)', 'icon'],
  [touchIcon, '', 'apple-touch-icon'],
]) {
  const link = document.createElement('link');
  link.rel = rel;
  link.href = href;
  if (media) link.media = media;
  document.head.append(link);
}

createRoot(document.getElementById('root')!).render(<App />);

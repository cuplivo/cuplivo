/**
 * Hash 路由：`#/migrate`、`#/recover` 可分享直达；静态托管零配置
 */
import type { View } from './view';

const VALID: View[] = ['home', 'migrate', 'recover', 'compat'];

function fromHash(): View {
  const h = location.hash.replace(/^#\/?/, '');
  return (VALID as string[]).includes(h) ? (h as View) : 'home';
}

function hashFor(v: View): string {
  return `#/${v}`;
}

export const router = $state({ view: fromHash() as View });

export function navigate(next: View): void {
  if (location.hash === hashFor(next)) return;
  location.hash = hashFor(next);
}

window.addEventListener('hashchange', () => {
  router.view = fromHash();
});

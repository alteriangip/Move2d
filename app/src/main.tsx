import { createRoot } from 'react-dom/client';
import { App } from './editor/App';
import './editor/styles.css';

createRoot(document.getElementById('root')!).render(<App />);

// Installable/offline only when served as its own site (not inside claude.ai).
if (import.meta.env.MODE === 'pages' && 'serviceWorker' in navigator && window.top === window.self) {
  void navigator.serviceWorker.register('./sw.js');
  void navigator.storage?.persist?.();
}
document.addEventListener('gesturestart', (e) => e.preventDefault());

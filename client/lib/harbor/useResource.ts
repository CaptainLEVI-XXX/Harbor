'use client';

import { useEffect, useRef, useState } from 'react';
import { errorMessage } from './config';

/** One result belongs to one identity. Old wallet/route responses never win. */
export function useResource<T>(key: string, load: () => Promise<T>, interval = 15_000) {
  const loader = useRef(load);
  useEffect(() => { loader.current = load; }, [load]);
  const [revision, setRevision] = useState(0);
  const [result, setResult] = useState<{ key: string; data?: T; error?: string; loading: boolean }>({ key, loading: true });
  useEffect(() => {
    let cancelled = false;
    let running = false;
    async function refresh() {
      if (running) return;
      running = true;
      try {
        const data = await loader.current();
        if (!cancelled) setResult({ key, data, loading: false });
      } catch (error) {
        if (!cancelled) setResult({ key, error: errorMessage(error), loading: false });
      } finally { running = false; }
    }
    void refresh();
    const timer = setInterval(() => { void refresh(); }, interval);
    return () => { cancelled = true; clearInterval(timer); };
  }, [key, revision, interval]);
  const current = result.key === key ? result : { key, loading: true };
  return { ...current, refresh: () => setRevision(r => r + 1) };
}

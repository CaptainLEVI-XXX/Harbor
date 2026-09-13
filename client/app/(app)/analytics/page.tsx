import AnalyticsDashboard from '@/components/analytics/AnalyticsDashboard';
import { loadBenchmark } from '@/lib/analytics/server';
import styles from '@/components/analytics/analytics.module.css';
export const dynamic = 'force-dynamic';
export const metadata = { title: 'Analytics · Harbor', description: 'Historical pricing benchmarks for Harbor and three pricing baselines.' };

export default async function AnalyticsPage() {
  const data = await loadBenchmark().catch(() => null);
  if (data) return <AnalyticsDashboard data={data} />;
  return <section className={styles.page}><header className={styles.head}><h1>How harbor prices</h1></header><div className={styles.unavailable} role="status"><h2>Analytics is unavailable</h2><p>The dataset could not be verified. Try again later.</p><a href="/analytics">Try again</a></div></section>;
}

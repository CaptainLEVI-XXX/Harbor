import type { Fill } from '@/lib/earn/types';
import { timeOfDay } from '@/lib/charts/dates';

/** Issuer names, not tickers: this reads as evidence for the strategy table. */
export default function ActivityList({ fills }: { fills: Fill[] }) {
  return (
    <section className="modal">
      <div className="shead">
        <h2>Recent activity</h2>
        <span className="aside">last 24 hours</span>
      </div>
      <div className="list well">
        {fills.map(fill => (
          <div className="act-row" key={`${fill.at}-${fill.subject}`}>
            <span className="t">{timeOfDay(fill.at)}</span>
            <span>
              <em>{fill.action}</em> <span className="num">{fill.subject}</span> {fill.detail}
              {fill.counter && (
                <>
                  {' '}
                  <span className="num">{fill.counter}</span>
                </>
              )}
            </span>
            <span className="r">{fill.issuer}</span>
          </div>
        ))}
      </div>
    </section>
  );
}

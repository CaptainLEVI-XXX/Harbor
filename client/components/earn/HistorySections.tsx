'use client';
import { useEffect, useState } from 'react';
import { chain } from '@/lib/chain';
import { formatSigned, formatWei, tone } from '@/lib/format';
import type { History } from '@/lib/harbor/history';
import { COMPOSITION, compositionSeries, recentActivity, shareObservations, sharePct, strategyEvents } from '@/lib/harbor/analytics';
import { useDisplayPrice } from '@/lib/harbor/DisplayPriceProvider';
import TokenMark from '@/components/TokenMark';
import ReturnsChart from '@/components/charts/ReturnsChart';
import AllocationChart from '@/components/charts/AllocationChart';
import ShareValueChart from '@/components/charts/ShareValueChart';
import ActivityTimeline from '@/components/charts/ActivityTimeline';
import StrategyChart from '@/components/charts/StrategyChart';

type Props = { history: { data?: History; error?: string; refresh: () => void } };

const when = (seconds: string | number | bigint) => new Date(Number(seconds) * 1000).toLocaleString();
/** strategies are labelled "Issuer · asset"; the issuer names the mark */
const issuer = (label: string) => label.split(' · ')[0].toLowerCase();

/** Indexed history, stated by its figures. */
export default function HistorySections({ history: { data, error, refresh } }: Props) {
  const { usd } = useDisplayPrice();
  const [focus, setFocus] = useState<string | null>(null);
  // live windows are measured back from now, and now moves
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => { const id = setInterval(() => setNow(Date.now()), 60_000); return () => clearInterval(id); }, []);
  if (!data) return <section className="modal"><div className="shead"><h2>Vault analytics</h2>{error && <button type="button" className="ghost" onClick={refresh}>Retry</button>}</div><p role="status" className="empty">{error ?? 'Loading…'}</p></section>;

  const mark = data.pool.lastCheckpoint;
  const composition = compositionSeries(data);
  const shares = shareObservations(data).map(o => ({ at: Number(o.timestamp) * 1000, price: o.price }));
  const explorer = chain.blockExplorers.default.url;
  const activity = recentActivity(data).reverse().map(e => ({ id: e.id, at: Number(e.timestamp) * 1000, kind: e.kind, label: e.label, wei: BigInt(e.cash), href: `${explorer}/tx/${e.transactionHash}` }));
  const strategies = data.strategies.map(s => ({ id: s.id, label: s.label, issuer: issuer(s.label), result: BigInt(s.realizedResult), traded: BigInt(s.customerCashVolume), recovered: BigInt(s.recoveredCash), pending: BigInt(s.pendingBasis) }));
  const backing = mark ? [
    { id: 'inventory', label: 'Token inventory', wei: BigInt(mark.inventoryMark) },
    { id: 'claims', label: 'Pending claims', wei: BigInt(mark.claimMark) },
    { id: 'cash', label: 'Cash', wei: BigInt(mark.cash) },
  ] : [];
  const backed = backing.reduce((sum, b) => sum + b.wei, 0n);
  const money = (wei: bigint) => <>{formatWei(wei, 18)}<small className="usd">{usd(wei < 0n ? -wei : wei)}</small></>;

  return <>
    <section className="modal"><div className="shead"><h2>Returns</h2></div>
      {shares.length < 2 ? <p className="empty">Not enough checkpoints yet</p> : <ReturnsChart points={shares} now={now} />}
    </section>

    <section className="modal"><div className="shead"><h2>Vault backing</h2>{mark && <span className="status" data-tone="past">{when(mark.timestamp)}</span>}</div>
      {mark ? <>
        {composition.length > 0 && <AllocationChart points={composition} strategies={COMPOSITION} focus={focus} onFocus={setFocus} now={now} />}
        <div className="stats four">
          {backing.map(b => {
            const colour = COMPOSITION.find(c => c.id === b.id)!.colour;
            return <div className="stat" key={b.id} data-focused={focus === b.id ? '' : undefined}
              onPointerEnter={() => setFocus(b.id)} onPointerLeave={() => setFocus(null)}>
              <span><i className="swatch" style={{ background: colour }} />{b.label} <em className="pct">{sharePct(b.wei, backed).toFixed(1)}%</em></span>
              <b>{formatWei(b.wei, 18)}</b><i>WETH</i><small className="usd">{usd(b.wei)}</small>
            </div>;
          })}
          <div className="stat"><span>Reserved</span><b>{formatWei(BigInt(mark.reserved), 18)}</b><i>WETH</i><small className="usd">{usd(BigInt(mark.reserved))}</small></div>
        </div>
      </> : <p className="empty">No checkpoint yet</p>}
    </section>

    <section className="modal"><div className="shead"><h2>Strategy performance</h2></div>
      {strategies.length > 0 && <StrategyChart strategies={strategies} events={strategyEvents(data)} now={now} />}
      <div className="tablewrap"><table className="dtable"><thead><tr><th scope="col">Strategy</th><th scope="col">Traded · WETH</th><th scope="col">Realized P/L</th><th scope="col">Recovered</th><th scope="col">Pending cost</th></tr></thead>
        <tbody>{strategies.map(s => (
          <tr key={s.id}><th scope="row"><span className="strat-name"><TokenMark symbol={s.issuer} /><span>{s.label}<small>Aqua</small></span></span></th>
            <td className="num">{money(s.traded)}</td>
            <td className={`num ${tone(s.result)}`}>{formatSigned(s.result, 18, 6)}<small className="usd">{usd(s.result < 0n ? -s.result : s.result)}</small></td>
            <td className="num">{money(s.recovered)}</td>
            <td className="num">{money(s.pending)}</td></tr>
        ))}</tbody></table></div>
      {data.strategies.length === 100 && <p className="note">First 100 strategies</p>}
    </section>

    <section className="modal"><div className="shead"><h2>Share value</h2></div>
      {shares.length < 1 ? <p className="empty">Not enough checkpoints yet</p> : <ShareValueChart points={shares} now={now} />}
    </section>

    <section className="modal"><div className="shead"><h2>Recent activity</h2></div>
      {activity.length === 0 ? <p className="empty">No activity yet</p> : <ActivityTimeline events={activity} now={now} />}
    </section>

    <section className="modal"><div className="shead"><h2>Withdrawal queue</h2></div>{data.exitRequests.length===0 ? <p className="empty">No withdrawal requests yet</p> : <ul className="rows">{data.exitRequests.map(e=><li className="row" key={e.id}><a className="num" href={`${explorer}/tx/${e.requestTransaction}`} target="_blank" rel="noreferrer">{formatWei(BigInt(e.requestedShares),24)} hWETH ↗</a><span className="what end"><span className="num">{formatWei(BigInt(e.fundedAssets),18)} WETH funded <small className="usd">{usd(BigInt(e.fundedAssets))}</small></span><small>{BigInt(e.pendingShares)>0n ? 'Pending' : 'Funded'}</small></span></li>)}</ul>}</section>
  </>;
}

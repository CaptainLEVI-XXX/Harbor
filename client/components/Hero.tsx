import { DESIGN } from '@/lib/design';

export default function Hero() {
  return (
    <div className="col">
      <div className="colw">
        <h1 className="headline">{DESIGN.copy.headline.map(line => <span key={line}>{line}</span>)}</h1>
        <p className="subcopy">{DESIGN.copy.subcopy}</p>
      </div>
    </div>
  );
}

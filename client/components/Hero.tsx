import { DESIGN } from '@/lib/design';

export default function Hero() {
  return (
    <div className="col">
      <div className="colw">
        <h1 className="headline">{DESIGN.copy.headline}</h1>
        <p className="subcopy">{DESIGN.copy.subcopy}</p>
        <p className="availability">{DESIGN.copy.availability}</p>
      </div>
    </div>
  );
}

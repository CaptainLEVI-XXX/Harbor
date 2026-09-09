import { DESIGN } from '@/lib/design';
import HarborMark from './HarborMark';

type Props = { onConnect: () => void; connectLabel: string };

export default function Nav({ onConnect, connectLabel }: Props) {
  return (
    <nav className="nav">
      <div className="mark">
        <HarborMark />
        Harbor<sup>beta</sup>
      </div>

      {/* no aria-current: nothing is selected on the landing page */}
      <div className="navlinks">
        {DESIGN.copy.nav.map(item => (
          <a key={item} href="#">{item}</a>
        ))}
      </div>

      <button type="button" className="connect" onClick={onConnect}>
        {connectLabel}
      </button>
    </nav>
  );
}

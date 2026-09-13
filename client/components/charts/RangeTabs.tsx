import { RANGES } from '@/lib/charts/dates';

/** The same four windows on every live chart, so a reader sets them once in their head. */
export default function RangeTabs({ hours, onChange }: { hours: number; onChange: (hours: number) => void }) {
  return (
    <div className="seg glass" role="group" aria-label="Range">
      {RANGES.map(r => (
        <button key={r.label} type="button" aria-pressed={hours === r.hours} onClick={() => onChange(r.hours)}>{r.label}</button>
      ))}
    </div>
  );
}

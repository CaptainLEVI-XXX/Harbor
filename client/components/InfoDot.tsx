/**
 * The one-line explanation a step would otherwise have to state in prose.
 *
 * Hand-built rather than a tooltip dependency: the text is the button's
 * accessible name, so a screen reader gets it without ever opening anything,
 * and the bubble is decoration that hover or keyboard focus reveals.
 */
export default function InfoDot({ children }: { children: string }) {
  return (
    <span className="info">
      <button type="button" className="infodot" aria-label={children}>i</button>
      <span className="infobubble" aria-hidden="true">{children}</span>
    </span>
  );
}

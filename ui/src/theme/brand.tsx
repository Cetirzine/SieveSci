// Brand artwork from Sources/SieveSciApp/Brand.swift: the logo, the animated ghost, and each agent
// role's ghost (monoline icon, full-colour logo, and the "working" animation). Files come from
// public/brand (extracted from the Swift sources by scripts/brand.mjs).
import { L } from "../i18n";
import { reducedMotion, roleName, roleVar, type Role } from "./theme";

const url = (name: string) => `${import.meta.env.BASE_URL}brand/${name}.svg`;

export function BrandLogo({ size }: { size: number }) {
  return <img src={url("aurora")} width={size} height={size} alt="" aria-hidden draggable={false} className="brand-logo" />;
}

/** The animated ghost wherever SieveSci is working (static logo under reduced motion). */
export function GhostLoader({ size = 22 }: { size?: number }) {
  return <img src={url(reducedMotion() ? "aurora" : "auroraAnimated")} width={size} height={size} alt="" aria-hidden draggable={false} />;
}

/** Monoline role icon for 14–24 px slots, tinted with the role colour. */
export function RoleGhostIcon({ role, size = 16, tint }: { role: Role; size?: number; tint?: string }) {
  const color = tint ?? roleVar[role];
  return (
    <span className="role-icon" role="img" aria-label={roleName(role)}
          style={{ width: size, height: size, background: color, WebkitMaskImage: `url(${url(`${role}_line`)})`, maskImage: `url(${url(`${role}_line`)})` }} />
  );
}

/** Full-colour role ghost; while the agent works the ghost floats and its prop moves. */
export function RoleGhostBadge({ role, working = false, size = 28 }: { role: Role; working?: boolean; size?: number }) {
  const label = roleName(role) + (working ? " · " + L("working") : "");
  if (!working || reducedMotion()) {
    return <img src={url(`${role}_logo`)} width={size} height={size} alt={label} draggable={false} className="role-badge" />;
  }
  return (
    <span className={`ghost-rig role-${role}`} role="img" aria-label={label} style={{ width: size, height: size }}>
      <span className="rig">
        {role === "verifier" && <><i className="sonar" /><i className="sonar late" /></>}
        <img src={url(`${role}_base`)} alt="" draggable={false} />
        {role !== "verifier" && <img className="prop" src={url(`${role}_prop`)} alt="" draggable={false} />}
      </span>
    </span>
  );
}

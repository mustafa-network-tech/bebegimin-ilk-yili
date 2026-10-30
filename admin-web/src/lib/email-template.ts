// Placeholder rendering for the admin's manual e-mails. Plain text only: the
// text is never interpreted as HTML and unknown placeholders stay untouched
// (the database refuses to save templates that contain any).

export type TemplateVars = { ad: string; deneme_bitis: string };

export function renderTemplate(text: string, vars: TemplateVars): string {
  return text.replace(/\{\{\s*([A-Za-z0-9_]*)\s*\}\}/g, (whole, key: string) =>
    key === "ad" || key === "deneme_bitis" ? vars[key] : whole,
  );
}

/** mailto: links are length limited by mail clients; the copy buttons are the primary path. */
export function mailtoHref(to: string | null, subject: string, body: string): string | null {
  if (!to) return null;
  return `mailto:${encodeURIComponent(to)}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`;
}

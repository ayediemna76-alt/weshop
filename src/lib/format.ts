/** Prices are stored in TND with 3 decimals (millimes). */
export function formatTND(
  value: number | string | null | undefined,
  locale: "fr" | "ar" = "fr",
): string {
  const n = typeof value === "string" ? Number(value) : (value ?? 0);
  const formatted = new Intl.NumberFormat(locale === "ar" ? "ar-TN" : "fr-TN", {
    minimumFractionDigits: 3,
    maximumFractionDigits: 3,
  }).format(Number.isFinite(n) ? n : 0);
  return locale === "ar" ? `${formatted} د.ت` : `${formatted} DT`;
}

export function formatDate(
  value: string | Date | null | undefined,
  locale: "fr" | "ar" = "fr",
  withTime = false,
) {
  if (!value) return "—";
  const d = typeof value === "string" ? new Date(value) : value;
  return new Intl.DateTimeFormat(locale === "ar" ? "ar-TN" : "fr-FR", {
    dateStyle: "medium",
    ...(withTime ? { timeStyle: "short" } : {}),
  }).format(d);
}

/** URL-safe slug: lowercase ascii, hyphen-separated. */
export function slugify(input: string): string {
  return input
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80);
}

/** Attribute code: lowercase ascii, underscore-separated. */
export function codify(input: string): string {
  return slugify(input).replace(/-/g, "_").slice(0, 40);
}

/** Map database error codes raised by our functions to readable French messages. */
export function dbErrorMessage(error: unknown): string {
  const raw =
    error && typeof error === "object" && "message" in error
      ? String((error as { message: string }).message)
      : String(error);
  const map: Record<string, string> = {
    category_cycle: "Une catégorie ne peut pas être sa propre sous-catégorie.",
    category_too_deep: "Arborescence trop profonde.",
    forbidden: "Action réservée aux administrateurs.",
    not_authenticated: "Veuillez vous connecter.",
    uq_variant_combination: "Deux variantes ont la même combinaison d'options.",
    duplicate_combination: "Deux variantes ont la même combinaison d'options.",
    variants_required: "Ajoutez au moins une variante.",
    active_variant_required: "Au moins une variante doit rester active.",
    variant_options_required: "Chaque variante doit avoir ses options (taille, couleur…).",
    category_required: "Choisissez une catégorie.",
    invalid_attribute: "Une caractéristique ne correspond pas à la catégorie choisie.",
    invalid_option: "Une valeur choisie n'existe plus. Rechargez la page.",
    too_many_images: "20 photos maximum par produit.",
    too_many_variants: "200 variantes maximum par produit.",
    invalid_quantity: "Quantité invalide.",
    insufficient_stock: "Stock insuffisant pour cette opération.",
    reason_required: "Indiquez un motif.",
    invalid_action: "Opération inconnue.",
    product_variants_sku_key: "Une référence de variante est déjà utilisée par un autre produit.",
    products_sku_key: "Cette référence produit est déjà utilisée.",
    products_slug_key: "Cette adresse web est déjà utilisée par un autre produit.",
    duplicate_sku: "Cette référence produit est déjà utilisée.",
    duplicate_slug: "Cette adresse web est déjà utilisée par un autre produit.",
    product_not_found: "Produit introuvable.",
    product_in_orders: "Produit déjà commandé : il a été archivé.",
    invalid_payload: "Certaines données sont invalides. Vérifiez le formulaire.",
  };
  const missing = /missing_required:\s*([^\n"]+)/.exec(raw);
  if (missing) return `Caractéristiques obligatoires manquantes : ${missing[1]!.trim()}.`;
  for (const [code, msg] of Object.entries(map)) if (raw.includes(code)) return msg;
  if (raw.includes("duplicate key") && raw.includes("slug")) return "Ce slug est déjà utilisé.";
  if (raw.includes("duplicate key") && raw.includes("code"))
    return "Ce code d'attribut existe déjà dans cette catégorie.";
  if (raw.includes("duplicate key")) return "Cette valeur existe déjà.";
  if (raw.includes("violates foreign key") && raw.includes("categories"))
    return "Impossible : cette catégorie contient des sous-catégories ou des produits.";
  if (raw.includes("check constraint")) return "Valeur invalide.";
  return raw;
}

import { createServerFn, createServerOnlyFn } from "@tanstack/react-start";
import { queryOptions } from "@tanstack/react-query";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";
import type { Database, Json } from "@/integrations/supabase/types";
import { supabasePublishableKey, supabaseUrl } from "@/integrations/supabase/env";
import { createSupabaseFetch } from "@/integrations/supabase/fetch";
import type { PublicCategory } from "./catalog.functions";

/** Read-only client with the publishable key; RLS limits it to published catalog rows. */
const publicClient = createServerOnlyFn(() => {
  const key = supabasePublishableKey();
  return createClient<Database>(supabaseUrl(), key, {
    auth: { storage: undefined, persistSession: false, autoRefreshToken: false },
    global: { fetch: createSupabaseFetch(key) },
  });
});

type Sb = ReturnType<typeof publicClient>;

export type ProductCardData = {
  id: string;
  slug: string;
  name_fr: string;
  name_ar: string | null;
  brand: string | null;
  price: number;
  promo_price: number | null;
  image: string | null;
  rating_avg: number;
  rating_count: number;
  is_featured: boolean;
  in_stock: boolean;
};

export type FacetOption = {
  id: string;
  value: string;
  label_fr: string | null;
  label_ar: string | null;
  color_hex: string | null;
};
export type Facet = {
  id: string;
  name_fr: string;
  name_ar: string | null;
  type: string;
  options: FacetOption[];
};

const CARD_COLUMNS =
  "id, slug, name_fr, name_ar, brand, price, promo_price, rating_avg, rating_count, is_featured, product_images(url, position)";

async function loadCards(sb: Sb, ids: string[]): Promise<ProductCardData[]> {
  if (!ids.length) return [];
  const [{ data, error }, avail] = await Promise.all([
    sb.from("products").select(CARD_COLUMNS).in("id", ids).eq("status", "published"),
    sb.rpc("get_variant_availability", { _product_ids: ids }),
  ]);
  if (error) throw new Error(error.message);
  if (avail.error) throw new Error(avail.error.message);
  const stock = new Map<string, number>();
  for (const a of avail.data ?? [])
    stock.set(a.product_id, (stock.get(a.product_id) ?? 0) + Math.max(a.available, 0));
  const byId = new Map(
    (data ?? []).map((p) => {
      const imgs = [...(p.product_images ?? [])].sort((a, b) => a.position - b.position);
      const card: ProductCardData = {
        id: p.id,
        slug: p.slug,
        name_fr: p.name_fr,
        name_ar: p.name_ar,
        brand: p.brand,
        price: Number(p.price),
        promo_price: p.promo_price == null ? null : Number(p.promo_price),
        image: imgs[0]?.url ?? null,
        rating_avg: Number(p.rating_avg),
        rating_count: p.rating_count,
        is_featured: p.is_featured,
        in_stock: (stock.get(p.id) ?? 0) > 0,
      };
      return [p.id, card] as const;
    }),
  );
  return ids.map((id) => byId.get(id)).filter((x): x is ProductCardData => !!x);
}

/* ---------------- Home ---------------- */

export const getHomeProducts = createServerFn({ method: "GET" }).handler(async () => {
  const sb = publicClient();
  const [featured, newest, best, deals] = await Promise.all([
    sb
      .from("products")
      .select("id")
      .eq("status", "published")
      .eq("is_featured", true)
      .order("published_at", { ascending: false })
      .limit(8),
    sb
      .from("products")
      .select("id")
      .eq("status", "published")
      .order("published_at", { ascending: false })
      .limit(8),
    sb.rpc("get_best_sellers", { _limit: 8 }),
    sb
      .from("products")
      .select("id")
      .eq("status", "published")
      .not("promo_price", "is", null)
      .order("published_at", { ascending: false })
      .limit(8),
  ]);
  const hasSchemaError = [featured, newest, best, deals].some(
    (r) =>
      r.error &&
      (r.error.message?.includes("schema cache") ||
        r.error.message?.includes("does not exist") ||
        r.error.code === "PGRST205"),
  );
  if (hasSchemaError) {
    return {
      featured: [],
      newest: [],
      best: { kind: "best" as const, items: [] },
    };
  }

  for (const r of [featured, newest, best, deals]) if (r.error) throw new Error(r.error.message);
  const bestIds = (best.data ?? []).map((b) => b.product_id);
  const [f, n, b] = await Promise.all([
    loadCards(
      sb,
      (featured.data ?? []).map((x) => x.id),
    ),
    loadCards(
      sb,
      (newest.data ?? []).map((x) => x.id),
    ),
    loadCards(sb, bestIds.length >= 4 ? bestIds : (deals.data ?? []).map((x) => x.id)),
  ]);
  return {
    featured: f,
    newest: n,
    best: { kind: bestIds.length >= 4 ? ("best" as const) : ("deals" as const), items: b },
  };
});

export const homeProductsQuery = () =>
  queryOptions({
    queryKey: ["public", "home-products"],
    queryFn: () => getHomeProducts(),
    staleTime: 60_000,
  });

/* ---------------- Shop listing ---------------- */

export const SHOP_SORTS = [
  "relevance",
  "new",
  "price_asc",
  "price_desc",
  "popular",
  "rating",
] as const;
export type ShopSort = (typeof SHOP_SORTS)[number];
export const SHOP_PAGE_SIZE = 12;

const shopInput = z.object({
  c: z.string().max(120).optional(),
  q: z.string().max(120).optional(),
  sort: z.enum(SHOP_SORTS).optional(),
  page: z.number().int().min(1).max(500).optional(),
  min: z.number().min(0).max(1_000_000).optional(),
  max: z.number().min(0).max(1_000_000).optional(),
  f: z.record(z.string().uuid(), z.array(z.string().uuid()).max(30)).optional(),
});
export type ShopInput = z.input<typeof shopInput>;

export const listShopProducts = createServerFn({ method: "GET" })
  .inputValidator((input: ShopInput) => shopInput.parse(input))
  .handler(async ({ data }) => {
    const sb = publicClient();
    let category: PublicCategory | null = null;
    if (data.c) {
      const { data: cat, error } = await sb
        .from("categories")
        .select(
          "id,parent_id,name_fr,name_ar,slug,description_fr,description_ar,image_url,display_order",
        )
        .eq("slug", data.c)
        .eq("is_active", true)
        .maybeSingle();
      if (error) throw new Error(error.message);
      category = cat;
    }
    const page = data.page ?? 1;
    const args: Database["public"]["Functions"]["search_products"]["Args"] = {
      _filters: (data.f ?? {}) as Json,
      _sort: data.sort ?? "relevance",
      _limit: SHOP_PAGE_SIZE,
      _offset: (page - 1) * SHOP_PAGE_SIZE,
    };
    if (category) args._category_id = category.id;
    if (data.q?.trim()) args._q = data.q.trim();
    if (data.min != null) args._min_price = data.min;
    if (data.max != null) args._max_price = data.max;
    const { data: rows, error } = await sb.rpc("search_products", args);
    if (error) {
      if (
        error.message?.includes("schema cache") ||
        error.message?.includes("does not exist") ||
        error.code === "PGRST205"
      ) {
        return {
          items: [],
          total: 0,
          page,
          pageSize: SHOP_PAGE_SIZE,
          category,
          facets: [],
        };
      }
      throw new Error(error.message);
    }
    const items = await loadCards(
      sb,
      (rows ?? []).map((r) => r.product_id),
    );
    const total = Number(rows?.[0]?.total ?? 0);

    let facets: Facet[] = [];
    if (category) {
      const { data: attrs, error: ae } = await sb.rpc("get_category_attributes", {
        _category_id: category.id,
      });
      if (ae) throw new Error(ae.message);
      const usable = (attrs ?? []).filter(
        (a) => a.is_filterable && ["dropdown", "multi_select", "color"].includes(a.type),
      );
      if (usable.length) {
        const { data: opts, error: oe } = await sb
          .from("category_attribute_options")
          .select("id, attribute_id, value, label_fr, label_ar, color_hex, display_order")
          .in(
            "attribute_id",
            usable.map((a) => a.id),
          )
          .order("display_order");
        if (oe) throw new Error(oe.message);
        facets = usable
          .sort((a, b) => b.depth - a.depth || a.display_order - b.display_order)
          .map((a) => ({
            id: a.id,
            name_fr: a.name_fr,
            name_ar: a.name_ar,
            type: a.type,
            options: (opts ?? [])
              .filter((o) => o.attribute_id === a.id)
              .map((o) => ({
                id: o.id,
                value: o.value,
                label_fr: o.label_fr,
                label_ar: o.label_ar,
                color_hex: o.color_hex,
              })),
          }))
          .filter((f) => f.options.length > 0);
      }
    }
    return { items, total, page, pageSize: SHOP_PAGE_SIZE, category, facets };
  });

export const shopQuery = (input: ShopInput) =>
  queryOptions({
    queryKey: ["public", "shop", input],
    queryFn: () => listShopProducts({ data: input }),
    staleTime: 30_000,
  });

/* ---------------- Product page ---------------- */

export type VariantAxis = {
  id: string;
  name_fr: string;
  name_ar: string | null;
  type: string;
  options: FacetOption[];
};
export type PublicVariant = {
  id: string;
  sku: string;
  price: number;
  promo_price: number | null;
  available: number;
  options: Record<string, string>;
  label_fr: string;
  label_ar: string;
};
export type Spec = { name_fr: string; name_ar: string | null; value_fr: string; value_ar: string };

export const getProductBySlug = createServerFn({ method: "GET" })
  .inputValidator((input: { slug: string }) =>
    z.object({ slug: z.string().min(1).max(200) }).parse(input),
  )
  .handler(async ({ data }) => {
    const sb = publicClient();
    const { data: p, error } = await sb
      .from("products")
      .select(
        "id, category_id, name_fr, name_ar, slug, sku, description_fr, description_ar, brand, model, price, promo_price, warranty, has_variants, rating_avg, rating_count, published_at, product_images(id, url, alt, position)",
      )
      .eq("slug", data.slug)
      .eq("status", "published")
      .maybeSingle();
    if (error) throw new Error(error.message);
    if (!p) return null;

    const [attrsRes, valuesRes, variantsRes, availRes, reviewsRes, relatedRes] = await Promise.all([
      sb.rpc("get_category_attributes", { _category_id: p.category_id }),
      sb
        .from("product_attribute_values")
        .select("attribute_id, option_id, value_text, value_number, value_boolean, value_date")
        .eq("product_id", p.id),
      sb
        .from("product_variants")
        .select(
          "id, sku, price, promo_price, position, is_active, variant_attribute_values(attribute_id, option_id)",
        )
        .eq("product_id", p.id)
        .eq("is_active", true)
        .order("position"),
      sb.rpc("get_variant_availability", { _product_ids: [p.id] }),
      sb
        .from("reviews")
        .select("id, author_name, rating, comment, is_verified, created_at")
        .eq("product_id", p.id)
        .eq("status", "published")
        .order("created_at", { ascending: false })
        .limit(20),
      sb
        .from("products")
        .select("id")
        .eq("status", "published")
        .eq("category_id", p.category_id)
        .neq("id", p.id)
        .order("published_at", { ascending: false })
        .limit(4),
    ]);
    for (const r of [attrsRes, valuesRes, variantsRes, availRes, reviewsRes, relatedRes])
      if (r.error) throw new Error(r.error.message);
    const attrs = attrsRes.data ?? [];
    const optionIds = new Set<string>();
    for (const v of valuesRes.data ?? []) if (v.option_id) optionIds.add(v.option_id);
    for (const v of variantsRes.data ?? [])
      for (const o of v.variant_attribute_values ?? []) optionIds.add(o.option_id);
    const optsRes = optionIds.size
      ? await sb
          .from("category_attribute_options")
          .select("id, attribute_id, value, label_fr, label_ar, color_hex, display_order")
          .in("id", [...optionIds])
          .order("display_order")
      : { data: [], error: null };
    if (optsRes.error) throw new Error(optsRes.error.message);
    const optById = new Map((optsRes.data ?? []).map((o) => [o.id, o]));
    const label = (id: string, ar: boolean) => {
      const o = optById.get(id);
      return (ar ? o?.label_ar : null) || o?.label_fr || o?.value || "";
    };

    const specs: Spec[] = [];
    for (const a of [...attrs].sort(
      (x, y) => y.depth - x.depth || x.display_order - y.display_order,
    )) {
      if (a.is_variant) continue;
      const vals = (valuesRes.data ?? []).filter((v) => v.attribute_id === a.id);
      if (!vals.length) continue;
      const fmt = (ar: boolean) =>
        vals
          .map((v) => {
            if (v.option_id) return label(v.option_id, ar);
            if (v.value_boolean != null)
              return v.value_boolean ? (ar ? "نعم" : "Oui") : ar ? "لا" : "Non";
            if (v.value_number != null)
              return `${Number(v.value_number).toLocaleString(ar ? "ar-TN" : "fr-TN")}${a.unit ? ` ${a.unit}` : ""}`;
            if (v.value_date) return v.value_date;
            return v.value_text ?? "";
          })
          .filter(Boolean)
          .join(", ");
      specs.push({
        name_fr: a.name_fr,
        name_ar: a.name_ar,
        value_fr: fmt(false),
        value_ar: fmt(true),
      });
    }

    const avail = new Map((availRes.data ?? []).map((a) => [a.variant_id, a.available]));
    const variantAttrs = attrs
      .filter((a) => a.is_variant)
      .sort((x, y) => y.depth - x.depth || x.display_order - y.display_order);
    const variants: PublicVariant[] = (variantsRes.data ?? []).map((v) => {
      const options: Record<string, string> = {};
      for (const o of v.variant_attribute_values ?? []) options[o.attribute_id] = o.option_id;
      const ordered = variantAttrs.filter((a) => options[a.id]).map((a) => options[a.id]!);
      return {
        id: v.id,
        sku: v.sku,
        price: Number(v.price),
        promo_price: v.promo_price == null ? null : Number(v.promo_price),
        available: Math.max(avail.get(v.id) ?? 0, 0),
        options,
        label_fr: ordered.map((id) => label(id, false)).join(" / "),
        label_ar: ordered.map((id) => label(id, true)).join(" / "),
      };
    });
    const axes: VariantAxis[] = variantAttrs
      .map((a) => {
        const used = new Set(variants.map((v) => v.options[a.id]).filter(Boolean));
        const options = (optsRes.data ?? [])
          .filter((o) => o.attribute_id === a.id && used.has(o.id))
          .map((o) => ({
            id: o.id,
            value: o.value,
            label_fr: o.label_fr,
            label_ar: o.label_ar,
            color_hex: o.color_hex,
          }));
        return { id: a.id, name_fr: a.name_fr, name_ar: a.name_ar, type: a.type, options };
      })
      .filter((a) => a.options.length > 0);

    const related = await loadCards(
      sb,
      (relatedRes.data ?? []).map((r) => r.id),
    );
    const images = [...(p.product_images ?? [])].sort((a, b) => a.position - b.position);
    return {
      product: {
        id: p.id,
        category_id: p.category_id,
        name_fr: p.name_fr,
        name_ar: p.name_ar,
        slug: p.slug,
        sku: p.sku,
        description_fr: p.description_fr,
        description_ar: p.description_ar,
        brand: p.brand,
        model: p.model,
        warranty: p.warranty,
        price: Number(p.price),
        promo_price: p.promo_price == null ? null : Number(p.promo_price),
        rating_avg: Number(p.rating_avg),
        rating_count: p.rating_count,
      },
      images: images.map((i) => ({ id: i.id, url: i.url, alt: i.alt })),
      specs,
      axes,
      variants,
      reviews: reviewsRes.data ?? [],
      related,
    };
  });

export type ProductDetail = NonNullable<Awaited<ReturnType<typeof getProductBySlug>>>;

export const productQuery = (slug: string) =>
  queryOptions({
    queryKey: ["public", "product", slug],
    queryFn: () => getProductBySlug({ data: { slug } }),
    staleTime: 30_000,
  });

/* ---------------- Cart revalidation ---------------- */

export type CartLineInfo = {
  variant_id: string;
  product_id: string;
  slug: string;
  name_fr: string;
  name_ar: string | null;
  image: string | null;
  price: number;
  promo_price: number | null;
  available: number;
  label_fr: string;
  label_ar: string;
};

export const getCartLines = createServerFn({ method: "POST" })
  .inputValidator((input: { variantIds: string[] }) =>
    z.object({ variantIds: z.array(z.string().uuid()).max(50) }).parse(input),
  )
  .handler(async ({ data }): Promise<CartLineInfo[]> => {
    if (!data.variantIds.length) return [];
    const sb = publicClient();
    const { data: vars, error } = await sb
      .from("product_variants")
      .select(
        "id, product_id, price, promo_price, is_active, variant_attribute_values(attribute_id, option_id), products!inner(slug, name_fr, name_ar, status, product_images(url, position))",
      )
      .in("id", data.variantIds)
      .eq("is_active", true);
    if (error) throw new Error(error.message);
    const productIds = [...new Set((vars ?? []).map((v) => v.product_id))];
    const optionIds = [
      ...new Set(
        (vars ?? []).flatMap((v) => (v.variant_attribute_values ?? []).map((o) => o.option_id)),
      ),
    ];
    const [avail, opts] = await Promise.all([
      productIds.length
        ? sb.rpc("get_variant_availability", { _product_ids: productIds })
        : Promise.resolve({ data: [], error: null }),
      optionIds.length
        ? sb
            .from("category_attribute_options")
            .select("id, value, label_fr, label_ar")
            .in("id", optionIds)
        : Promise.resolve({ data: [], error: null }),
    ]);
    if (avail.error) throw new Error(avail.error.message);
    if (opts.error) throw new Error(opts.error.message);
    const a = new Map((avail.data ?? []).map((x) => [x.variant_id, x.available]));
    const o = new Map((opts.data ?? []).map((x) => [x.id, x]));
    return (vars ?? []).map((v) => {
      const prod = v.products as unknown as {
        slug: string;
        name_fr: string;
        name_ar: string | null;
        product_images: { url: string; position: number }[];
      };
      const imgs = [...(prod.product_images ?? [])].sort((x, y) => x.position - y.position);
      const ids = (v.variant_attribute_values ?? []).map((x) => x.option_id);
      return {
        variant_id: v.id,
        product_id: v.product_id,
        slug: prod.slug,
        name_fr: prod.name_fr,
        name_ar: prod.name_ar,
        image: imgs[0]?.url ?? null,
        price: Number(v.price),
        promo_price: v.promo_price == null ? null : Number(v.promo_price),
        available: Math.max(a.get(v.id) ?? 0, 0),
        label_fr: ids.map((id) => o.get(id)?.label_fr || o.get(id)?.value || "").join(" / "),
        label_ar: ids
          .map((id) => o.get(id)?.label_ar || o.get(id)?.label_fr || o.get(id)?.value || "")
          .join(" / "),
      };
    });
  });

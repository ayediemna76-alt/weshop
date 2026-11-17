import { createServerFn, createServerOnlyFn } from "@tanstack/react-start";
import { queryOptions } from "@tanstack/react-query";
import { createClient } from "@supabase/supabase-js";
import type { Database } from "@/integrations/supabase/types";
import { supabasePublishableKey, supabaseUrl } from "@/integrations/supabase/env";
import { createSupabaseFetch } from "@/integrations/supabase/fetch";

/** Read-only client with the publishable key; RLS limits it to public rows. */
const publicClient = createServerOnlyFn(() => {
  const key = supabasePublishableKey();
  return createClient<Database>(supabaseUrl(), key, {
    auth: { storage: undefined, persistSession: false, autoRefreshToken: false },
    global: { fetch: createSupabaseFetch(key) },
  });
});

export type PublicCategory = {
  id: string;
  parent_id: string | null;
  name_fr: string;
  name_ar: string | null;
  slug: string;
  description_fr: string | null;
  description_ar: string | null;
  image_url: string | null;
  display_order: number;
};

export const getPublicCategories = createServerFn({ method: "GET" }).handler(
  async (): Promise<PublicCategory[]> => {
    const sb = publicClient();
    const { data, error } = await sb
      .from("categories")
      .select(
        "id,parent_id,name_fr,name_ar,slug,description_fr,description_ar,image_url,display_order",
      )
      .eq("is_active", true)
      .order("display_order")
      .order("name_fr");
    if (error) {
      if (error.message?.includes("schema cache") || error.code === "PGRST205") {
        return [];
      }
      throw new Error(error.message);
    }
    // hide children whose parent is inactive (not returned)
    const ids = new Set((data ?? []).map((c) => c.id));
    return (data ?? []).filter((c) => !c.parent_id || ids.has(c.parent_id));
  },
);

const FALLBACK_SETTINGS: Database["public"]["Tables"]["store_settings"]["Row"] = {
  id: true,
  store_name: "weshop",
  currency: "TND",
  support_email: "contact@weshop.tn",
  support_phone: "+216 71 000 000",
  delivery_fee: 7,
  free_delivery_threshold: 150,
  delivery_cities: [
    "Tunis",
    "Ariana",
    "Ben Arous",
    "Manouba",
    "Nabeul",
    "Zaghouan",
    "Bizerte",
    "Béja",
    "Jendouba",
    "Le Kef",
    "Siliana",
    "Sousse",
    "Monastir",
    "Mahdia",
    "Sfax",
    "Kairouan",
    "Kasserine",
    "Sidi Bouzid",
    "Gabès",
    "Médenine",
    "Tataouine",
    "Gafsa",
    "Tozeur",
    "Kébili",
  ],
  announcement_fr: "Livraison offerte dès 150 DT — paiement à la livraison",
  announcement_ar: "توصيل مجاني ابتداءً من 150 د.ت — الدفع عند الاستلام",
  default_low_stock_threshold: 5,
  return_window_days: 14,
  updated_at: new Date().toISOString(),
};

export const getStoreSettings = createServerFn({ method: "GET" }).handler(async () => {
  const sb = publicClient();
  const { data, error } = await sb.from("store_settings").select("*").maybeSingle();
  if (error) {
    if (error.message?.includes("schema cache") || error.code === "PGRST205") {
      return FALLBACK_SETTINGS;
    }
    throw new Error(error.message);
  }
  return data ?? FALLBACK_SETTINGS;
});

export const publicCategoriesQuery = () =>
  queryOptions({
    queryKey: ["public", "categories"],
    queryFn: () => getPublicCategories(),
    staleTime: 60_000,
  });

export const storeSettingsQuery = () =>
  queryOptions({
    queryKey: ["public", "settings"],
    queryFn: () => getStoreSettings(),
    staleTime: 60_000,
  });

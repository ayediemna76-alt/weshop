import { createFileRoute, Link } from "@tanstack/react-router";
import { useSuspenseQuery } from "@tanstack/react-query";
import { Banknote, RotateCcw, Truck } from "lucide-react";
import { Button } from "@/components/ui/button";
import { StoreLayout } from "@/components/store/StoreLayout";
import { CategoryTile } from "@/components/store/CategoryTile";
import { publicCategoriesQuery, storeSettingsQuery } from "@/lib/catalog.functions";
import { homeProductsQuery, type ProductCardData } from "@/lib/shop.functions";
import { ProductGrid } from "@/components/store/ProductCard";
import { useI18n } from "@/lib/i18n";
import heroImage from "@/assets/hero-flatlay.jpg";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "weshop — Achetez en ligne, payez à la livraison en Tunisie" },
      {
        name: "description",
        content:
          "Mode, maison, électronique et plus. Livraison dans toute la Tunisie, paiement en espèces à la réception.",
      },
      { property: "og:title", content: "weshop — Achetez en ligne, payez à la livraison" },
      {
        property: "og:description",
        content: "Livraison dans toute la Tunisie, paiement en espèces à la réception.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  loader: async ({ context }) => {
    await Promise.all([
      context.queryClient.ensureQueryData(publicCategoriesQuery()),
      context.queryClient.ensureQueryData(storeSettingsQuery()),
      context.queryClient.ensureQueryData(homeProductsQuery()),
    ]);
  },
  component: Index,
});

function Index() {
  const { t, tr } = useI18n();
  const { data: categories } = useSuspenseQuery(publicCategoriesQuery());
  const { data: home } = useSuspenseQuery(homeProductsQuery());
  const roots = categories.filter((c) => !c.parent_id);

  const perks = [
    { icon: Banknote, title: t("home.perk.cod"), desc: t("home.perk.cod.desc") },
    { icon: Truck, title: t("home.perk.delivery"), desc: t("home.perk.delivery.desc") },
    { icon: RotateCcw, title: t("home.perk.returns"), desc: t("home.perk.returns.desc") },
  ];

  return (
    <StoreLayout>
      <section className="relative overflow-hidden border-b bg-primary-soft">
        <img
          src={heroImage}
          alt=""
          width={1600}
          height={1008}
          className="absolute inset-0 h-full w-full object-cover object-right rtl:-scale-x-100"
        />
        <div className="relative mx-auto max-w-7xl px-4 py-20 md:py-28">
          <div className="max-w-xl">
            <span className="inline-flex items-center gap-2 rounded-full border border-primary/20 bg-background/80 px-3 py-1 text-xs font-semibold text-primary">
              <Banknote className="h-3.5 w-3.5" /> {t("home.perk.cod")}
            </span>
            <h1 className="mt-5 text-4xl font-bold leading-[1.05] text-foreground md:text-6xl">
              {t("home.hero.title")}
            </h1>
            <p className="mt-5 max-w-md text-base text-muted-foreground md:text-lg">
              {t("home.hero.subtitle")}
            </p>
            <div className="mt-8 flex flex-wrap gap-3">
              <Button asChild size="lg">
                <Link to="/shop">{tr("Voir la boutique", "تصفح المتجر")}</Link>
              </Button>
              <Button asChild size="lg" variant="outline" className="bg-background/80">
                <Link to="/categories">{t("home.hero.cta")}</Link>
              </Button>
            </div>
          </div>
        </div>
      </section>

      <section className="mx-auto max-w-7xl px-4">
        <div className="-mt-8 grid gap-3 rounded-2xl border bg-card p-4 shadow-card sm:grid-cols-3 relative">
          {perks.map(({ icon: Icon, title, desc }) => (
            <div key={title} className="flex items-center gap-3 rounded-xl p-2">
              <span className="grid h-10 w-10 shrink-0 place-items-center rounded-lg bg-primary-soft text-primary">
                <Icon className="h-5 w-5" />
              </span>
              <div>
                <p className="text-sm font-semibold">{title}</p>
                <p className="text-xs text-muted-foreground">{desc}</p>
              </div>
            </div>
          ))}
        </div>
      </section>

      <section className="mx-auto max-w-7xl px-4 pt-16">
        <div className="flex items-end justify-between gap-4">
          <h2 className="text-2xl font-semibold md:text-3xl">{t("home.categories.title")}</h2>
          {roots.length > 0 && (
            <Link to="/categories" className="text-sm font-medium text-primary hover:underline">
              {t("categories.title")} →
            </Link>
          )}
        </div>
        {roots.length === 0 ? (
          <div className="mt-6 rounded-2xl border border-dashed p-12 text-center text-muted-foreground">
            {t("home.categories.empty")}
          </div>
        ) : (
          <div className="mt-6 grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-5">
            {roots.map((c) => (
              <CategoryTile
                key={c.id}
                category={c}
                count={categories.filter((x) => x.parent_id === c.id).length}
              />
            ))}
          </div>
        )}
      </section>

      <ProductSection
        title={tr("Coups de cœur", "اختياراتنا لك")}
        products={home.featured}
        search={{ sort: "relevance" }}
      />
      <ProductSection
        title={tr("Nouveautés", "وصل حديثاً")}
        products={home.newest}
        search={{ sort: "new" }}
      />
      <ProductSection
        title={
          home.best.kind === "best"
            ? tr("Meilleures ventes", "الأكثر مبيعاً")
            : tr("Bons plans", "عروض مميزة")
        }
        products={home.best.items}
        search={{ sort: home.best.kind === "best" ? "popular" : "price_asc" }}
      />
    </StoreLayout>
  );
}

function ProductSection({
  title,
  products,
  search,
}: {
  title: string;
  products: ProductCardData[];
  search: { sort: "relevance" | "new" | "popular" | "price_asc" };
}) {
  const { tr } = useI18n();
  if (!products.length) return null;
  return (
    <section className="mx-auto max-w-7xl px-4 pt-16">
      <div className="mb-6 flex items-end justify-between gap-4">
        <h2 className="text-2xl font-semibold md:text-3xl">{title}</h2>
        <Link
          to="/shop"
          search={search}
          className="text-sm font-medium text-primary hover:underline"
        >
          {tr("Tout voir", "عرض الكل")} →
        </Link>
      </div>
      <ProductGrid products={products.slice(0, 8)} />
    </section>
  );
}

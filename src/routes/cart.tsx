import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { useEffect } from "react";
import {
  AlertTriangle,
  Banknote,
  Loader2,
  Minus,
  Plus,
  ShoppingBag,
  Trash2,
  Truck,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { StoreLayout } from "@/components/store/StoreLayout";
import { getCartLines, type CartLineInfo } from "@/lib/shop.functions";
import { storeSettingsQuery } from "@/lib/catalog.functions";
import { MAX_LINE_QTY, useCart } from "@/lib/cart";
import { formatTND } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { computeCartTotals } from "@/lib/cart-totals";

export const Route = createFileRoute("/cart")({
  head: () => ({
    meta: [
      { title: "Mon panier — weshop" },
      {
        name: "description",
        content:
          "Vérifiez votre panier weshop avant de commander. Paiement à la livraison partout en Tunisie.",
      },
      { property: "og:title", content: "Mon panier — weshop" },
      { property: "og:description", content: "Votre panier weshop, paiement à la livraison." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
      { name: "robots", content: "noindex" },
    ],
  }),
  component: CartPage,
});

function CartPage() {
  const { tr, locale } = useI18n();
  const cart = useCart();
  const fetchLines = useServerFn(getCartLines);
  const ids = cart.items.map((i) => i.variantId);
  const lines = useQuery({
    queryKey: ["public", "cart-lines", ids.slice().sort().join(",")],
    queryFn: () => fetchLines({ data: { variantIds: ids } }),
    enabled: cart.ready && ids.length > 0,
    staleTime: 15_000,
  });
  const settings = useQuery(storeSettingsQuery());
  const info = new Map<string, CartLineInfo>((lines.data ?? []).map((l) => [l.variant_id, l]));

  // keep each line's quantity within what's in stock
  useEffect(() => {
    if (!lines.data) return;
    for (const item of cart.items) {
      const l = info.get(item.variantId);
      if (l && l.available > 0 && item.qty > l.available) cart.setQty(item.variantId, l.available);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lines.data]);

  const priced = cart.items.map((item) => {
    const l = info.get(item.variantId);
    const unit = l ? (l.promo_price ?? l.price) : item.unitPrice;
    return {
      item,
      line: l,
      unit,
      missing: lines.isSuccess && !l,
      soldOut: !!l && l.available <= 0,
    };
  });
  const sellable = priced.filter((p) => !p.missing && !p.soldOut);
  const totals = computeCartTotals(
    sellable.map((p) => ({ unitPrice: p.unit, qty: p.item.qty })),
    settings.data
      ? {
          deliveryFee: Number(settings.data.delivery_fee),
          freeThreshold:
            settings.data.free_delivery_threshold == null
              ? null
              : Number(settings.data.free_delivery_threshold),
        }
      : null,
  );

  if (!cart.ready) {
    return (
      <StoreLayout>
        <div className="mx-auto max-w-5xl px-4 py-10">
          <Skeleton className="h-64 rounded-2xl" />
        </div>
      </StoreLayout>
    );
  }

  if (cart.items.length === 0) {
    return (
      <StoreLayout>
        <div className="mx-auto flex max-w-md flex-col items-center gap-3 px-4 py-24 text-center">
          <span className="grid h-14 w-14 place-items-center rounded-full bg-primary-soft text-primary">
            <ShoppingBag className="h-6 w-6" />
          </span>
          <h1 className="text-2xl font-semibold">{tr("Votre panier est vide", "سلتك فارغة")}</h1>
          <p className="text-muted-foreground">
            {tr(
              "Parcourez la boutique et ajoutez vos coups de cœur.",
              "تصفح المتجر وأضف ما يعجبك.",
            )}
          </p>
          <Button asChild>
            <Link to="/shop">{tr("Découvrir la boutique", "اكتشف المتجر")}</Link>
          </Button>
        </div>
      </StoreLayout>
    );
  }

  return (
    <StoreLayout>
      <div className="mx-auto max-w-6xl px-4 py-10">
        <h1 className="text-3xl font-bold">{tr("Mon panier", "سلتي")}</h1>
        <div className="mt-6 grid gap-8 lg:grid-cols-[minmax(0,1fr)_340px]">
          <ul className="divide-y rounded-2xl border bg-card shadow-card">
            {priced.map(({ item, line, unit, missing, soldOut }) => {
              const name =
                (locale === "ar" && (line?.name_ar ?? item.name_ar)) ||
                line?.name_fr ||
                item.name_fr;
              const label =
                locale === "ar"
                  ? (line?.label_ar ?? item.label_ar)
                  : (line?.label_fr ?? item.label_fr);
              const max = Math.min(line?.available ?? MAX_LINE_QTY, MAX_LINE_QTY);
              const priceChanged = line && Math.abs(unit - item.unitPrice) > 0.0005;
              return (
                <li key={item.variantId} className="flex gap-4 p-4">
                  <Link
                    to="/product/$slug"
                    params={{ slug: line?.slug ?? item.slug }}
                    className="h-24 w-24 shrink-0 overflow-hidden rounded-xl bg-primary-soft"
                  >
                    {(line?.image ?? item.image) && (
                      <img
                        src={line?.image ?? item.image ?? ""}
                        alt={name}
                        width={96}
                        height={96}
                        loading="lazy"
                        className="h-full w-full object-cover"
                      />
                    )}
                  </Link>
                  <div className="min-w-0 flex-1 space-y-1">
                    <Link
                      to="/product/$slug"
                      params={{ slug: line?.slug ?? item.slug }}
                      className="line-clamp-2 font-medium hover:text-primary"
                    >
                      {name}
                    </Link>
                    {label && <p className="text-sm text-muted-foreground">{label}</p>}
                    {missing && (
                      <p className="flex items-center gap-1 text-sm text-destructive">
                        <AlertTriangle className="h-4 w-4" />{" "}
                        {tr("Ce produit n'est plus disponible.", "هذا المنتج لم يعد متوفراً.")}
                      </p>
                    )}
                    {soldOut && (
                      <p className="flex items-center gap-1 text-sm text-destructive">
                        <AlertTriangle className="h-4 w-4" />{" "}
                        {tr("Épuisé pour le moment.", "نفد المخزون حالياً.")}
                      </p>
                    )}
                    {priceChanged && !missing && (
                      <p className="text-xs text-highlight">
                        {tr("Le prix a été mis à jour.", "تم تحديث السعر.")}
                      </p>
                    )}
                    <div className="flex flex-wrap items-center gap-3 pt-1">
                      <div className="flex items-center rounded-lg border">
                        <Button
                          variant="ghost"
                          size="icon"
                          className="h-8 w-8"
                          disabled={item.qty <= 1 || missing || soldOut}
                          onClick={() => cart.setQty(item.variantId, item.qty - 1)}
                          aria-label={tr("Diminuer", "إنقاص")}
                        >
                          <Minus />
                        </Button>
                        <span className="w-8 text-center text-sm font-medium tabular-nums">
                          {item.qty}
                        </span>
                        <Button
                          variant="ghost"
                          size="icon"
                          className="h-8 w-8"
                          disabled={item.qty >= max || missing || soldOut}
                          onClick={() => cart.setQty(item.variantId, item.qty + 1)}
                          aria-label={tr("Augmenter", "زيادة")}
                        >
                          <Plus />
                        </Button>
                      </div>
                      <Button
                        variant="ghost"
                        size="sm"
                        className="text-muted-foreground"
                        onClick={() => cart.remove(item.variantId)}
                      >
                        <Trash2 /> {tr("Retirer", "إزالة")}
                      </Button>
                    </div>
                  </div>
                  <p className="shrink-0 text-end font-display font-semibold">
                    {formatTND(unit * item.qty, locale)}
                  </p>
                </li>
              );
            })}
          </ul>

          <aside className="space-y-4 lg:sticky lg:top-24 lg:self-start">
            <div className="space-y-3 rounded-2xl border bg-card p-5 shadow-card">
              <p className="font-semibold">{tr("Récapitulatif", "الملخص")}</p>
              <Row k={tr("Sous-total", "المجموع الفرعي")} v={formatTND(totals.subtotal, locale)} />
              <Row
                k={tr("Livraison", "التوصيل")}
                v={
                  totals.delivery === 0
                    ? tr("Offerte", "مجاني")
                    : formatTND(totals.delivery, locale)
                }
              />
              {totals.remainingForFree != null && totals.remainingForFree > 0 && (
                <p className="rounded-lg bg-primary-soft px-3 py-2 text-xs text-primary">
                  <Truck className="me-1 inline h-3.5 w-3.5" />
                  {tr(
                    `Plus que ${formatTND(totals.remainingForFree, "fr")} pour la livraison offerte.`,
                    `أضف ${formatTND(totals.remainingForFree, "ar")} للحصول على توصيل مجاني.`,
                  )}
                </p>
              )}
              <div className="flex items-center justify-between border-t pt-3">
                <span className="font-semibold">
                  {tr("Total à payer à la livraison", "المبلغ عند الاستلام")}
                </span>
                <span className="font-display text-xl font-bold">
                  {formatTND(totals.total, locale)}
                </span>
              </div>
              <Button size="lg" className="w-full" disabled>
                {lines.isFetching && <Loader2 className="animate-spin" />}
                {tr("Commander", "اطلب الآن")}
              </Button>
              <p className="text-center text-xs text-muted-foreground">
                {tr(
                  "La validation de commande arrive très bientôt.",
                  "إتمام الطلب سيتوفر قريباً جداً.",
                )}
              </p>
            </div>
            <p className="flex items-center gap-2 rounded-2xl border bg-muted/40 p-4 text-sm">
              <Banknote className="h-4 w-4 shrink-0 text-primary" />{" "}
              {tr(
                "Vous payez en espèces au livreur, à la réception.",
                "تدفع نقداً لعامل التوصيل عند الاستلام.",
              )}
            </p>
          </aside>
        </div>
      </div>
    </StoreLayout>
  );
}

function Row({ k, v }: { k: string; v: string }) {
  return (
    <div className="flex items-center justify-between text-sm">
      <span className="text-muted-foreground">{k}</span>
      <span className="font-medium">{v}</span>
    </div>
  );
}

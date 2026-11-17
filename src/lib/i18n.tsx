import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";

export type Locale = "fr" | "ar";

const fr = {
  "brand.tagline": "Tout ce qu'il vous faut, payé à la livraison",
  "nav.home": "Accueil",
  "nav.categories": "Catégories",
  "nav.shop": "Boutique",
  "nav.track": "Suivre ma commande",
  "nav.account": "Mon compte",
  "nav.signin": "Se connecter",
  "nav.signout": "Se déconnecter",
  "nav.admin": "Administration",
  "nav.search": "Rechercher un produit…",
  "common.save": "Enregistrer",
  "common.cancel": "Annuler",
  "common.delete": "Supprimer",
  "common.edit": "Modifier",
  "common.add": "Ajouter",
  "common.loading": "Chargement…",
  "common.retry": "Réessayer",
  "common.error": "Une erreur est survenue",
  "common.saved": "Enregistré",
  "common.active": "Actif",
  "common.inactive": "Inactif",
  "common.optional": "facultatif",
  "home.hero.title": "Achetez en ligne, payez à la porte.",
  "home.hero.subtitle":
    "Mode, maison, électronique et plus. Livraison partout en Tunisie, paiement en espèces à la réception.",
  "home.hero.cta": "Découvrir les catégories",
  "home.perk.cod": "Paiement à la livraison",
  "home.perk.cod.desc": "Main à main, sans carte bancaire",
  "home.perk.delivery": "Livraison nationale",
  "home.perk.delivery.desc": "Dans les 24 gouvernorats",
  "home.perk.returns": "Retours simples",
  "home.perk.returns.desc": "Depuis votre espace client",
  "home.categories.title": "Parcourir par catégorie",
  "home.categories.empty": "Le catalogue est en préparation. Revenez très bientôt !",
  "categories.title": "Toutes les catégories",
  "categories.subtitle": "Explorez notre catalogue par univers.",
  "auth.title.signin": "Bon retour parmi nous",
  "auth.title.signup": "Créer un compte",
  "auth.subtitle": "Suivez vos commandes, gérez vos adresses et vos retours.",
  "auth.email": "Adresse e-mail",
  "auth.password": "Mot de passe",
  "auth.fullName": "Nom complet",
  "auth.submit.signin": "Se connecter",
  "auth.submit.signup": "Créer mon compte",
  "auth.switch.toSignup": "Pas encore de compte ? Inscrivez-vous",
  "auth.switch.toSignin": "Déjà inscrit ? Connectez-vous",
  "auth.forgot": "Mot de passe oublié ?",
  "auth.or": "ou",
  "auth.google": "Continuer avec Google",
  "auth.checkEmail": "Vérifiez votre boîte mail pour confirmer votre compte.",
  "auth.resetSent": "Un lien de réinitialisation vous a été envoyé.",
  "auth.newPassword": "Nouveau mot de passe",
  "auth.updatePassword": "Mettre à jour le mot de passe",
  "auth.passwordUpdated": "Mot de passe mis à jour",
  "auth.guestHint": "Vous pouvez aussi commander sans compte.",
  "account.title": "Mon compte",
  "account.profile": "Informations personnelles",
  "account.phone": "Téléphone",
  "account.language": "Langue préférée",
  "account.addresses": "Mes adresses de livraison",
  "account.addresses.empty": "Aucune adresse enregistrée.",
  "account.address.add": "Ajouter une adresse",
  "account.address.label": "Libellé (ex. Maison)",
  "account.address.city": "Ville / Gouvernorat",
  "account.address.line": "Adresse",
  "account.address.instructions": "Instructions de livraison",
  "account.address.default": "Par défaut",
  "setup.title": "Configuration de l'administrateur",
  "setup.desc":
    "Aucun administrateur n'existe encore. Le premier compte qui valide devient administrateur de la boutique.",
  "setup.claim": "Devenir administrateur",
  "setup.taken": "Un administrateur existe déjà. Demandez-lui de vous donner accès.",
  "setup.done": "Vous êtes maintenant administrateur.",
  "footer.rights": "Tous droits réservés.",
  "footer.cod": "Paiement uniquement à la livraison — Main à main.",
};

type Dict = typeof fr;
export type TKey = keyof Dict;

const ar: Dict = {
  "brand.tagline": "كل ما تحتاجه، والدفع عند الاستلام",
  "nav.home": "الرئيسية",
  "nav.categories": "الأقسام",
  "nav.shop": "المتجر",
  "nav.track": "تتبع طلبي",
  "nav.account": "حسابي",
  "nav.signin": "تسجيل الدخول",
  "nav.signout": "تسجيل الخروج",
  "nav.admin": "الإدارة",
  "nav.search": "ابحث عن منتج…",
  "common.save": "حفظ",
  "common.cancel": "إلغاء",
  "common.delete": "حذف",
  "common.edit": "تعديل",
  "common.add": "إضافة",
  "common.loading": "جارٍ التحميل…",
  "common.retry": "إعادة المحاولة",
  "common.error": "حدث خطأ ما",
  "common.saved": "تم الحفظ",
  "common.active": "نشط",
  "common.inactive": "غير نشط",
  "common.optional": "اختياري",
  "home.hero.title": "اشترِ عبر الإنترنت وادفع عند الباب.",
  "home.hero.subtitle":
    "ملابس، منزل، إلكترونيات والمزيد. توصيل لكامل تونس والدفع نقداً عند الاستلام.",
  "home.hero.cta": "اكتشف الأقسام",
  "home.perk.cod": "الدفع عند الاستلام",
  "home.perk.cod.desc": "يداً بيد، بدون بطاقة بنكية",
  "home.perk.delivery": "توصيل وطني",
  "home.perk.delivery.desc": "في الولايات الـ24",
  "home.perk.returns": "إرجاع سهل",
  "home.perk.returns.desc": "من فضاء الحريف",
  "home.categories.title": "تصفح حسب القسم",
  "home.categories.empty": "الكتالوج قيد التحضير. عودوا قريباً!",
  "categories.title": "كل الأقسام",
  "categories.subtitle": "استكشف الكتالوج حسب القسم.",
  "auth.title.signin": "مرحباً بعودتك",
  "auth.title.signup": "إنشاء حساب",
  "auth.subtitle": "تابع طلباتك وعناوينك وعمليات الإرجاع.",
  "auth.email": "البريد الإلكتروني",
  "auth.password": "كلمة المرور",
  "auth.fullName": "الاسم الكامل",
  "auth.submit.signin": "دخول",
  "auth.submit.signup": "إنشاء حسابي",
  "auth.switch.toSignup": "ليس لديك حساب؟ سجّل الآن",
  "auth.switch.toSignin": "لديك حساب؟ سجّل الدخول",
  "auth.forgot": "نسيت كلمة المرور؟",
  "auth.or": "أو",
  "auth.google": "المتابعة باستخدام Google",
  "auth.checkEmail": "تحقق من بريدك الإلكتروني لتأكيد حسابك.",
  "auth.resetSent": "تم إرسال رابط إعادة التعيين.",
  "auth.newPassword": "كلمة المرور الجديدة",
  "auth.updatePassword": "تحديث كلمة المرور",
  "auth.passwordUpdated": "تم تحديث كلمة المرور",
  "auth.guestHint": "يمكنك أيضاً الطلب بدون حساب.",
  "account.title": "حسابي",
  "account.profile": "المعلومات الشخصية",
  "account.phone": "الهاتف",
  "account.language": "اللغة المفضلة",
  "account.addresses": "عناوين التوصيل",
  "account.addresses.empty": "لا توجد عناوين محفوظة.",
  "account.address.add": "إضافة عنوان",
  "account.address.label": "التسمية (مثلاً: المنزل)",
  "account.address.city": "المدينة / الولاية",
  "account.address.line": "العنوان",
  "account.address.instructions": "تعليمات التوصيل",
  "account.address.default": "افتراضي",
  "setup.title": "إعداد المسؤول",
  "setup.desc": "لا يوجد مسؤول بعد. أول حساب يؤكد يصبح مسؤول المتجر.",
  "setup.claim": "أن أصبح مسؤولاً",
  "setup.taken": "يوجد مسؤول بالفعل. اطلب منه منحك الصلاحية.",
  "setup.done": "أصبحت الآن مسؤولاً.",
  "footer.rights": "جميع الحقوق محفوظة.",
  "footer.cod": "الدفع عند الاستلام فقط — يداً بيد.",
};

const dictionaries: Record<Locale, Dict> = { fr, ar };
const STORAGE_KEY = "weshop.locale";

type I18nValue = {
  locale: Locale;
  dir: "ltr" | "rtl";
  setLocale: (l: Locale) => void;
  t: (key: TKey) => string;
  /** Inline bilingual string: tr("Français", "العربية") */
  tr: (fr: string, ar: string) => string;
};

const I18nContext = createContext<I18nValue | null>(null);

export function I18nProvider({ children }: { children: ReactNode }) {
  const [locale, setLocaleState] = useState<Locale>("fr");

  useEffect(() => {
    const stored = window.localStorage.getItem(STORAGE_KEY);
    if (stored === "ar" || stored === "fr") setLocaleState(stored);
  }, []);

  useEffect(() => {
    document.documentElement.lang = locale;
    document.documentElement.dir = locale === "ar" ? "rtl" : "ltr";
  }, [locale]);

  const setLocale = useCallback((l: Locale) => {
    setLocaleState(l);
    window.localStorage.setItem(STORAGE_KEY, l);
  }, []);

  const value = useMemo<I18nValue>(
    () => ({
      locale,
      dir: locale === "ar" ? "rtl" : "ltr",
      setLocale,
      t: (key) => dictionaries[locale][key] ?? dictionaries.fr[key] ?? key,
      tr: (frText, arText) => (locale === "ar" ? arText : frText),
    }),
    [locale, setLocale],
  );

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n() {
  const ctx = useContext(I18nContext);
  if (!ctx) throw new Error("useI18n must be used inside I18nProvider");
  return ctx;
}

/** Pick the localized value of a bilingual record field (falls back to French). */
export function pickLocale<T extends Record<string, unknown>>(
  row: T,
  field: string,
  locale: Locale,
): string {
  const ar = row[`${field}_ar`];
  const fr = row[`${field}_fr`];
  if (locale === "ar" && typeof ar === "string" && ar.trim()) return ar;
  return typeof fr === "string" ? fr : "";
}

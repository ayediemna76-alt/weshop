-- =========================================================
-- weshop database bootstrap
-- =========================================================
-- GENERATED FILE — do not edit by hand. Source of truth: supabase/migrations/.
-- Regenerate with: npm run db:bundle
--
-- Apply once to an empty Supabase project:
--   Supabase Dashboard -> SQL Editor -> paste this file -> Run
-- or with the CLI: npm run db:push
--
-- Files included (in order):
--   0001_core_schema.sql
--   0002_transactional_functions.sql
--   0003_description_templates.sql
--   0004_storage_policies.sql
--   0005_catalog_rpcs.sql
--   0006_seed_demo_catalog.sql
-- =========================================================

-- ===== 0001_core_schema.sql =====
-- =========================================================
-- weshop core schema
-- =========================================================

-- ---------- ENUMS ----------
create type public.app_role as enum ('admin','staff');
create type public.attribute_type as enum ('text','number','boolean','dropdown','multi_select','color','date','measurement');
create type public.product_status as enum ('draft','published','archived');
create type public.order_status as enum ('pending','confirmed','preparing','shipped','out_for_delivery','delivered','cancelled','returned');
create type public.payment_status as enum ('unpaid','paid','refunded');
create type public.stock_state as enum ('reserved','consumed','released');
create type public.movement_type as enum ('initial','restock','removal','reservation','reservation_release','shipment','delivery_return','return_restock','return_damaged','damage','damage_writeoff','damage_repaired','incoming','incoming_received');
create type public.return_status as enum ('requested','approved','rejected','received','processed');
create type public.return_condition as enum ('resalable','damaged','unsellable');
create type public.review_status as enum ('published','hidden');
create type public.promotion_type as enum ('percent','fixed');
create type public.finance_entry_type as enum ('revenue','cogs','discount','delivery_income','cash_collected','refund','return_revenue_reversal','return_cogs_reversal','return_loss','damage_loss');

create sequence public.order_ref_seq start 1001;
create sequence public.return_ref_seq start 101;

-- ---------- helpers ----------
create or replace function public.set_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin new.updated_at = now(); return new; end $$;

-- ---------- PROFILES ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text check (full_name is null or length(full_name) <= 120),
  phone text check (phone is null or length(phone) <= 20),
  email text,
  preferred_locale text not null default 'fr' check (preferred_locale in ('fr','ar')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
grant select, insert, update on public.profiles to authenticated;
grant all on public.profiles to service_role;
alter table public.profiles enable row level security;
create trigger trg_profiles_updated before update on public.profiles for each row execute function public.set_updated_at();

-- ---------- ROLES ----------
create table public.user_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade not null,
  role public.app_role not null,
  created_at timestamptz not null default now(),
  unique (user_id, role)
);
grant select, insert, delete on public.user_roles to authenticated;
grant all on public.user_roles to service_role;
alter table public.user_roles enable row level security;

create or replace function public.has_role(_user_id uuid, _role public.app_role)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = _user_id and role = _role)
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = auth.uid() and role = 'admin')
$$;

create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = auth.uid() and role in ('admin','staff'))
$$;

create policy "Users read own roles; admins read all" on public.user_roles
  for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy "Admins grant roles" on public.user_roles
  for insert to authenticated with check (public.is_admin());
create policy "Admins revoke roles" on public.user_roles
  for delete to authenticated using (public.is_admin() and user_id <> auth.uid());

create policy "Read own profile; staff read all" on public.profiles
  for select to authenticated using (id = auth.uid() or public.is_staff());
create policy "Insert own profile" on public.profiles
  for insert to authenticated with check (id = auth.uid());
create policy "Update own profile" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- profile on signup
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, email)
  values (new.id,
          left(coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'), 120),
          new.email)
  on conflict (id) do nothing;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- AUDIT LOGS ----------
create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid,
  action text not null,
  entity text not null,
  entity_id text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index idx_audit_logs_entity on public.audit_logs(entity, entity_id);
create index idx_audit_logs_created on public.audit_logs(created_at desc);
grant select on public.audit_logs to authenticated;
grant all on public.audit_logs to service_role;
alter table public.audit_logs enable row level security;
create policy "Admins read audit logs" on public.audit_logs for select to authenticated using (public.is_admin());

create or replace function public.audit_row()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.audit_logs(actor_id, action, entity, entity_id, details)
  values (auth.uid(), lower(tg_op), tg_table_name,
          coalesce(to_jsonb(new)->>'id', to_jsonb(old)->>'id'),
          case when tg_op = 'DELETE' then jsonb_build_object('old', to_jsonb(old))
               when tg_op = 'UPDATE' then jsonb_build_object('new', to_jsonb(new))
               else jsonb_build_object('new', to_jsonb(new)) end);
  return coalesce(new, old);
end $$;

create trigger trg_audit_user_roles after insert or delete on public.user_roles
  for each row execute function public.audit_row();

-- first admin setup
create or replace function public.admin_exists()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where role = 'admin')
$$;

create or replace function public.claim_first_admin()
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  perform pg_advisory_xact_lock(7710001);
  if exists (select 1 from public.user_roles where role = 'admin') then
    return false;
  end if;
  insert into public.user_roles(user_id, role) values (auth.uid(), 'admin');
  return true;
end $$;
revoke execute on function public.claim_first_admin() from public, anon;
grant execute on function public.claim_first_admin() to authenticated;

-- ---------- STORE SETTINGS (singleton) ----------
create table public.store_settings (
  id boolean primary key default true check (id),
  store_name text not null default 'weshop',
  currency text not null default 'TND',
  delivery_fee numeric(12,3) not null default 7 check (delivery_fee >= 0),
  free_delivery_threshold numeric(12,3) check (free_delivery_threshold is null or free_delivery_threshold >= 0),
  support_phone text,
  support_email text,
  default_low_stock_threshold int not null default 5 check (default_low_stock_threshold >= 0),
  return_window_days int not null default 14 check (return_window_days between 0 and 365),
  delivery_cities text[] not null default array[]::text[],
  announcement_fr text,
  announcement_ar text,
  updated_at timestamptz not null default now()
);
grant select on public.store_settings to anon, authenticated;
grant update on public.store_settings to authenticated;
grant all on public.store_settings to service_role;
alter table public.store_settings enable row level security;
create policy "Anyone reads store settings" on public.store_settings for select to anon, authenticated using (true);
create policy "Admins update store settings" on public.store_settings for update to authenticated using (public.is_admin()) with check (public.is_admin());
create trigger trg_settings_updated before update on public.store_settings for each row execute function public.set_updated_at();
create trigger trg_audit_settings after update on public.store_settings for each row execute function public.audit_row();

insert into public.store_settings (id, delivery_fee, free_delivery_threshold, delivery_cities, announcement_fr, announcement_ar)
values (true, 7, 150,
  array['Tunis','Ariana','Ben Arous','Manouba','Nabeul','Zaghouan','Bizerte','Béja','Jendouba','Le Kef','Siliana','Sousse','Monastir','Mahdia','Sfax','Kairouan','Kasserine','Sidi Bouzid','Gabès','Médenine','Tataouine','Gafsa','Tozeur','Kébili'],
  'Paiement à la livraison partout en Tunisie',
  'الدفع عند الاستلام في كامل تراب الجمهورية');

-- ---------- CATEGORIES ----------
create table public.categories (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid references public.categories(id) on delete restrict,
  name_fr text not null check (length(trim(name_fr)) between 1 and 120),
  name_ar text check (name_ar is null or length(name_ar) <= 120),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  description_fr text check (description_fr is null or length(description_fr) <= 2000),
  description_ar text check (description_ar is null or length(description_ar) <= 2000),
  image_url text,
  display_order int not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index idx_categories_parent on public.categories(parent_id);
grant select on public.categories to anon;
grant select, insert, update, delete on public.categories to authenticated;
grant all on public.categories to service_role;
alter table public.categories enable row level security;
create policy "Public reads active categories" on public.categories for select to anon, authenticated using (is_active or public.is_staff());
create policy "Admins insert categories" on public.categories for insert to authenticated with check (public.is_admin());
create policy "Admins update categories" on public.categories for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "Admins delete categories" on public.categories for delete to authenticated using (public.is_admin());
create trigger trg_categories_updated before update on public.categories for each row execute function public.set_updated_at();
create trigger trg_audit_categories after insert or update or delete on public.categories for each row execute function public.audit_row();

create or replace function public.prevent_category_cycle()
returns trigger language plpgsql set search_path = public as $$
declare v_parent uuid := new.parent_id; v_depth int := 0;
begin
  while v_parent is not null loop
    if v_parent = new.id then raise exception 'category_cycle'; end if;
    select parent_id into v_parent from public.categories where id = v_parent;
    v_depth := v_depth + 1;
    if v_depth > 20 then raise exception 'category_too_deep'; end if;
  end loop;
  return new;
end $$;
create trigger trg_categories_cycle before insert or update of parent_id on public.categories
  for each row execute function public.prevent_category_cycle();

-- ---------- CATEGORY ATTRIBUTES ----------
create table public.category_attributes (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.categories(id) on delete cascade,
  code text not null check (code ~ '^[a-z0-9]+(_[a-z0-9]+)*$'),
  name_fr text not null check (length(trim(name_fr)) between 1 and 80),
  name_ar text check (name_ar is null or length(name_ar) <= 80),
  type public.attribute_type not null default 'text',
  unit text check (unit is null or length(unit) <= 20),
  is_required boolean not null default false,
  is_filterable boolean not null default false,
  is_searchable boolean not null default false,
  is_variant boolean not null default false,
  display_order int not null default 0,
  created_at timestamptz not null default now(),
  unique (category_id, code),
  check (not is_variant or type in ('dropdown','color'))
);
create index idx_cat_attr_category on public.category_attributes(category_id);
grant select on public.category_attributes to anon;
grant select, insert, update, delete on public.category_attributes to authenticated;
grant all on public.category_attributes to service_role;
alter table public.category_attributes enable row level security;
create policy "Public reads attributes" on public.category_attributes for select to anon, authenticated using (true);
create policy "Admins insert attributes" on public.category_attributes for insert to authenticated with check (public.is_admin());
create policy "Admins update attributes" on public.category_attributes for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "Admins delete attributes" on public.category_attributes for delete to authenticated using (public.is_admin());
create trigger trg_audit_cat_attr after insert or update or delete on public.category_attributes for each row execute function public.audit_row();

create table public.category_attribute_options (
  id uuid primary key default gen_random_uuid(),
  attribute_id uuid not null references public.category_attributes(id) on delete cascade,
  value text not null check (length(trim(value)) between 1 and 80),
  label_fr text check (label_fr is null or length(label_fr) <= 80),
  label_ar text check (label_ar is null or length(label_ar) <= 80),
  color_hex text check (color_hex is null or color_hex ~ '^#[0-9a-fA-F]{6}$'),
  display_order int not null default 0,
  created_at timestamptz not null default now(),
  unique (attribute_id, value)
);
create index idx_attr_opts_attr on public.category_attribute_options(attribute_id);
grant select on public.category_attribute_options to anon;
grant select, insert, update, delete on public.category_attribute_options to authenticated;
grant all on public.category_attribute_options to service_role;
alter table public.category_attribute_options enable row level security;
create policy "Public reads options" on public.category_attribute_options for select to anon, authenticated using (true);
create policy "Admins insert options" on public.category_attribute_options for insert to authenticated with check (public.is_admin());
create policy "Admins update options" on public.category_attribute_options for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "Admins delete options" on public.category_attribute_options for delete to authenticated using (public.is_admin());

-- attributes inherited from ancestor categories (root first)
create or replace function public.get_category_attributes(_category_id uuid)
returns table (
  id uuid, category_id uuid, code text, name_fr text, name_ar text, type public.attribute_type,
  unit text, is_required boolean, is_filterable boolean, is_searchable boolean, is_variant boolean,
  display_order int, depth int, inherited boolean
) language sql stable set search_path = public as $$
  with recursive chain as (
    select c.id, c.parent_id, 0 as depth from public.categories c where c.id = _category_id
    union all
    select p.id, p.parent_id, chain.depth + 1 from public.categories p join chain on p.id = chain.parent_id
    where chain.depth < 20
  )
  select a.id, a.category_id, a.code, a.name_fr, a.name_ar, a.type, a.unit, a.is_required,
         a.is_filterable, a.is_searchable, a.is_variant, a.display_order, chain.depth, chain.depth > 0
  from chain join public.category_attributes a on a.category_id = chain.id
  order by chain.depth desc, a.display_order, a.name_fr
$$;

-- ---------- PRODUCTS ----------
create table public.products (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.categories(id) on delete restrict,
  name_fr text not null check (length(trim(name_fr)) between 1 and 200),
  name_ar text check (name_ar is null or length(name_ar) <= 200),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  sku text not null unique check (length(trim(sku)) between 1 and 64),
  description_fr text check (description_fr is null or length(description_fr) <= 10000),
  description_ar text check (description_ar is null or length(description_ar) <= 10000),
  brand text check (brand is null or length(brand) <= 80),
  model text check (model is null or length(model) <= 80),
  price numeric(12,3) not null check (price >= 0),
  promo_price numeric(12,3) check (promo_price is null or (promo_price >= 0 and promo_price < price)),
  warranty text check (warranty is null or length(warranty) <= 200),
  status public.product_status not null default 'draft',
  has_variants boolean not null default false,
  is_featured boolean not null default false,
  rating_avg numeric(3,2) not null default 0,
  rating_count int not null default 0,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index idx_products_category on public.products(category_id);
create index idx_products_status on public.products(status);
create index idx_products_created on public.products(created_at desc);
grant select on public.products to anon;
grant select, insert, update, delete on public.products to authenticated;
grant all on public.products to service_role;
alter table public.products enable row level security;
create policy "Public reads published products" on public.products for select to anon, authenticated using (status = 'published' or public.is_staff());
create policy "Admins insert products" on public.products for insert to authenticated with check (public.is_admin());
create policy "Admins update products" on public.products for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "Admins delete products" on public.products for delete to authenticated using (public.is_admin());
create trigger trg_products_updated before update on public.products for each row execute function public.set_updated_at();
create trigger trg_audit_products after insert or update or delete on public.products for each row execute function public.audit_row();

create or replace function public.set_published_at()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.status = 'published' and (tg_op = 'INSERT' or old.status <> 'published') and new.published_at is null then
    new.published_at = now();
  end if;
  return new;
end $$;
create trigger trg_products_published before insert or update of status on public.products for each row execute function public.set_published_at();

-- admin-only product cost info
create table public.product_private (
  product_id uuid primary key references public.products(id) on delete cascade,
  purchase_price numeric(12,3) not null default 0 check (purchase_price >= 0),
  internal_notes text,
  updated_at timestamptz not null default now()
);
grant select, insert, update, delete on public.product_private to authenticated;
grant all on public.product_private to service_role;
alter table public.product_private enable row level security;
create policy "Admins manage product costs" on public.product_private for all to authenticated using (public.is_admin()) with check (public.is_admin());

create table public.product_attribute_values (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  attribute_id uuid not null references public.category_attributes(id) on delete cascade,
  option_id uuid references public.category_attribute_options(id) on delete cascade,
  value_text text check (value_text is null or length(value_text) <= 1000),
  value_number numeric,
  value_boolean boolean,
  value_date date
);
create unique index uq_product_attr_value on public.product_attribute_values(product_id, attribute_id, coalesce(option_id, '00000000-0000-0000-0000-000000000000'::uuid));
create index idx_pav_attr_option on public.product_attribute_values(attribute_id, option_id);
grant select on public.product_attribute_values to anon;
grant select, insert, update, delete on public.product_attribute_values to authenticated;
grant all on public.product_attribute_values to service_role;
alter table public.product_attribute_values enable row level security;
create policy "Public reads values of published products" on public.product_attribute_values for select to anon, authenticated
  using (public.is_staff() or exists (select 1 from public.products p where p.id = product_id and p.status = 'published'));
create policy "Admins manage attribute values" on public.product_attribute_values for all to authenticated using (public.is_admin()) with check (public.is_admin());

create table public.product_images (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  storage_path text,
  url text not null,
  alt text check (alt is null or length(alt) <= 200),
  position int not null default 0,
  created_at timestamptz not null default now()
);
create index idx_product_images_product on public.product_images(product_id, position);
grant select on public.product_images to anon;
grant select, insert, update, delete on public.product_images to authenticated;
grant all on public.product_images to service_role;
alter table public.product_images enable row level security;
create policy "Public reads images of published products" on public.product_images for select to anon, authenticated
  using (public.is_staff() or exists (select 1 from public.products p where p.id = product_id and p.status = 'published'));
create policy "Admins manage images" on public.product_images for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ---------- VARIANTS ----------
create table public.product_variants (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  sku text not null unique check (length(trim(sku)) between 1 and 64),
  combination_key text not null default ('v:' || gen_random_uuid()::text),
  price numeric(12,3) not null check (price >= 0),
  promo_price numeric(12,3) check (promo_price is null or (promo_price >= 0 and promo_price < price)),
  barcode text check (barcode is null or length(barcode) <= 64),
  is_active boolean not null default true,
  is_default boolean not null default false,
  position int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint uq_variant_combination unique (product_id, combination_key) deferrable initially deferred
);
create index idx_variants_product on public.product_variants(product_id);
grant select on public.product_variants to anon;
grant select, insert, update, delete on public.product_variants to authenticated;
grant all on public.product_variants to service_role;
alter table public.product_variants enable row level security;
create policy "Public reads variants of published products" on public.product_variants for select to anon, authenticated
  using (public.is_staff() or exists (select 1 from public.products p where p.id = product_id and p.status = 'published'));
create policy "Admins insert variants" on public.product_variants for insert to authenticated with check (public.is_admin());
create policy "Admins update variants" on public.product_variants for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "Admins delete variants" on public.product_variants for delete to authenticated using (public.is_admin());
create trigger trg_variants_updated before update on public.product_variants for each row execute function public.set_updated_at();
create trigger trg_audit_variants after insert or update or delete on public.product_variants for each row execute function public.audit_row();

create table public.variant_costs (
  variant_id uuid primary key references public.product_variants(id) on delete cascade,
  cost numeric(12,3) not null default 0 check (cost >= 0),
  updated_at timestamptz not null default now()
);
grant select, insert, update on public.variant_costs to authenticated;
grant all on public.variant_costs to service_role;
alter table public.variant_costs enable row level security;
create policy "Admins manage variant costs" on public.variant_costs for all to authenticated using (public.is_admin()) with check (public.is_admin());

create table public.variant_attribute_values (
  variant_id uuid not null references public.product_variants(id) on delete cascade,
  attribute_id uuid not null references public.category_attributes(id) on delete cascade,
  option_id uuid not null references public.category_attribute_options(id) on delete cascade,
  primary key (variant_id, attribute_id)
);
create index idx_vav_option on public.variant_attribute_values(option_id);
grant select on public.variant_attribute_values to anon;
grant select, insert, update, delete on public.variant_attribute_values to authenticated;
grant all on public.variant_attribute_values to service_role;
alter table public.variant_attribute_values enable row level security;
create policy "Public reads variant values" on public.variant_attribute_values for select to anon, authenticated
  using (public.is_staff() or exists (select 1 from public.product_variants v join public.products p on p.id = v.product_id where v.id = variant_id and p.status = 'published'));
create policy "Admins manage variant values" on public.variant_attribute_values for all to authenticated using (public.is_admin()) with check (public.is_admin());

create or replace function public.refresh_variant_combination()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_id uuid := coalesce(new.variant_id, old.variant_id);
begin
  update public.product_variants
     set combination_key = coalesce(
       (select string_agg(attribute_id::text || ':' || option_id::text, '|' order by attribute_id)
          from public.variant_attribute_values where variant_id = v_id),
       'v:' || v_id::text)
   where id = v_id;
  return null;
end $$;
create trigger trg_vav_combination after insert or update or delete on public.variant_attribute_values
  for each row execute function public.refresh_variant_combination();

-- ---------- INVENTORY ----------
create table public.inventory (
  variant_id uuid primary key references public.product_variants(id) on delete cascade,
  available int not null default 0 check (available >= 0),
  reserved int not null default 0 check (reserved >= 0),
  damaged int not null default 0 check (damaged >= 0),
  incoming int not null default 0 check (incoming >= 0),
  low_stock_threshold int not null default 5 check (low_stock_threshold >= 0),
  updated_at timestamptz not null default now()
);
grant select on public.inventory to authenticated;
grant all on public.inventory to service_role;
alter table public.inventory enable row level security;
create policy "Staff read inventory" on public.inventory for select to authenticated using (public.is_staff());

create table public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  variant_id uuid references public.product_variants(id) on delete set null,
  sku text,
  from_bucket text check (from_bucket in ('available','reserved','damaged','incoming')),
  to_bucket text check (to_bucket in ('available','reserved','damaged','incoming')),
  quantity int not null check (quantity > 0),
  movement_type public.movement_type not null,
  reason text check (reason is null or length(reason) <= 500),
  order_id uuid,
  return_id uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  check (from_bucket is not null or to_bucket is not null)
);
create index idx_movements_variant on public.inventory_movements(variant_id, created_at desc);
create index idx_movements_created on public.inventory_movements(created_at desc);
grant select on public.inventory_movements to authenticated;
grant all on public.inventory_movements to service_role;
alter table public.inventory_movements enable row level security;
create policy "Staff read movements" on public.inventory_movements for select to authenticated using (public.is_staff());

create or replace function public.handle_new_variant()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.inventory(variant_id, low_stock_threshold)
  values (new.id, coalesce((select default_low_stock_threshold from public.store_settings where id), 5))
  on conflict do nothing;
  insert into public.variant_costs(variant_id, cost)
  values (new.id, coalesce((select purchase_price from public.product_private where product_id = new.product_id), 0))
  on conflict do nothing;
  return new;
end $$;
create trigger trg_variant_created after insert on public.product_variants for each row execute function public.handle_new_variant();

-- ---------- ADDRESSES ----------
create table public.addresses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  label text check (label is null or length(label) <= 60),
  full_name text not null check (length(trim(full_name)) between 2 and 120),
  phone text not null check (length(phone) between 8 and 20),
  city text not null check (length(trim(city)) between 2 and 80),
  address_line text not null check (length(trim(address_line)) between 5 and 500),
  instructions text check (instructions is null or length(instructions) <= 500),
  is_default boolean not null default false,
  created_at timestamptz not null default now()
);
create index idx_addresses_user on public.addresses(user_id);
grant select, insert, update, delete on public.addresses to authenticated;
grant all on public.addresses to service_role;
alter table public.addresses enable row level security;
create policy "Users manage own addresses" on public.addresses for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "Staff read addresses" on public.addresses for select to authenticated using (public.is_staff());

-- ---------- PROMOTIONS ----------
create table public.promotions (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-Z0-9_-]{3,32}$'),
  description text check (description is null or length(description) <= 300),
  type public.promotion_type not null default 'percent',
  value numeric(12,3) not null check (value > 0),
  min_order_amount numeric(12,3) not null default 0 check (min_order_amount >= 0),
  max_uses int check (max_uses is null or max_uses > 0),
  used_count int not null default 0 check (used_count >= 0),
  starts_at timestamptz,
  ends_at timestamptz,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  check (type <> 'percent' or value <= 100)
);
grant select, insert, update, delete on public.promotions to authenticated;
grant all on public.promotions to service_role;
alter table public.promotions enable row level security;
create policy "Admins manage promotions" on public.promotions for all to authenticated using (public.is_admin()) with check (public.is_admin());
create trigger trg_audit_promotions after insert or update or delete on public.promotions for each row execute function public.audit_row();

-- ---------- ORDERS ----------
create table public.orders (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique,
  user_id uuid,
  customer_name text not null,
  phone text not null,
  email text,
  city text not null,
  address text not null,
  instructions text,
  status public.order_status not null default 'pending',
  payment_status public.payment_status not null default 'unpaid',
  payment_method text not null default 'cod' check (payment_method = 'cod'),
  subtotal numeric(12,3) not null default 0,
  discount_total numeric(12,3) not null default 0,
  delivery_fee numeric(12,3) not null default 0,
  total numeric(12,3) not null default 0,
  promotion_id uuid references public.promotions(id) on delete set null,
  promo_code text,
  stock_state public.stock_state not null default 'reserved',
  confirmed_at timestamptz,
  shipped_at timestamptz,
  delivered_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index idx_orders_user on public.orders(user_id, created_at desc);
create index idx_orders_status on public.orders(status);
create index idx_orders_created on public.orders(created_at desc);
create index idx_orders_phone on public.orders(phone);
grant select on public.orders to authenticated;
grant all on public.orders to service_role;
alter table public.orders enable row level security;
create policy "Customers read own orders; staff read all" on public.orders for select to authenticated using (user_id = auth.uid() or public.is_staff());
create trigger trg_orders_updated before update on public.orders for each row execute function public.set_updated_at();

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  variant_id uuid not null references public.product_variants(id) on delete restrict,
  product_name text not null,
  variant_label text,
  sku text not null,
  image_url text,
  unit_price numeric(12,3) not null check (unit_price >= 0),
  unit_cost numeric(12,3) not null default 0 check (unit_cost >= 0),
  quantity int not null check (quantity > 0),
  line_total numeric(12,3) not null
);
create index idx_order_items_order on public.order_items(order_id);
create index idx_order_items_variant on public.order_items(variant_id);
create index idx_order_items_product on public.order_items(product_id);
grant select on public.order_items to authenticated;
grant all on public.order_items to service_role;
alter table public.order_items enable row level security;
create policy "Read items of own orders; staff all" on public.order_items for select to authenticated
  using (public.is_staff() or exists (select 1 from public.orders o where o.id = order_id and o.user_id = auth.uid()));

create table public.order_status_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  from_status public.order_status,
  to_status public.order_status not null,
  note text,
  changed_by uuid,
  created_at timestamptz not null default now()
);
create index idx_osh_order on public.order_status_history(order_id, created_at);
grant select on public.order_status_history to authenticated;
grant all on public.order_status_history to service_role;
alter table public.order_status_history enable row level security;
create policy "Read history of own orders; staff all" on public.order_status_history for select to authenticated
  using (public.is_staff() or exists (select 1 from public.orders o where o.id = order_id and o.user_id = auth.uid()));

create table public.order_notes (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  note text not null check (length(trim(note)) between 1 and 2000),
  author_id uuid not null default auth.uid(),
  created_at timestamptz not null default now()
);
create index idx_order_notes_order on public.order_notes(order_id);
grant select, insert on public.order_notes to authenticated;
grant all on public.order_notes to service_role;
alter table public.order_notes enable row level security;
create policy "Staff read order notes" on public.order_notes for select to authenticated using (public.is_staff());
create policy "Staff add order notes" on public.order_notes for insert to authenticated with check (public.is_staff() and author_id = auth.uid());

create table public.cash_collections (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders(id) on delete restrict,
  amount_expected numeric(12,3) not null,
  amount_collected numeric(12,3) not null check (amount_collected >= 0),
  collected_at timestamptz not null,
  collected_by_name text not null,
  recorded_by uuid,
  note text,
  created_at timestamptz not null default now()
);
grant select on public.cash_collections to authenticated;
grant all on public.cash_collections to service_role;
alter table public.cash_collections enable row level security;
create policy "Staff read cash collections" on public.cash_collections for select to authenticated using (public.is_staff());

-- ---------- RETURNS ----------
create table public.returns (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique,
  order_id uuid not null references public.orders(id) on delete restrict,
  user_id uuid not null,
  status public.return_status not null default 'requested',
  reason text not null check (length(trim(reason)) between 2 and 200),
  description text check (description is null or length(description) <= 2000),
  photos text[] not null default array[]::text[],
  admin_note text,
  refund_amount numeric(12,3) not null default 0,
  processed_at timestamptz,
  processed_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index idx_returns_order on public.returns(order_id);
create index idx_returns_user on public.returns(user_id);
grant select on public.returns to authenticated;
grant all on public.returns to service_role;
alter table public.returns enable row level security;
create policy "Customers read own returns; staff all" on public.returns for select to authenticated using (user_id = auth.uid() or public.is_staff());
create trigger trg_returns_updated before update on public.returns for each row execute function public.set_updated_at();

create table public.return_items (
  id uuid primary key default gen_random_uuid(),
  return_id uuid not null references public.returns(id) on delete cascade,
  order_item_id uuid not null references public.order_items(id) on delete restrict,
  variant_id uuid not null,
  quantity int not null check (quantity > 0),
  condition public.return_condition,
  processed_at timestamptz,
  loss_amount numeric(12,3) not null default 0
);
create index idx_return_items_return on public.return_items(return_id);
create index idx_return_items_order_item on public.return_items(order_item_id);
grant select on public.return_items to authenticated;
grant all on public.return_items to service_role;
alter table public.return_items enable row level security;
create policy "Read items of own returns; staff all" on public.return_items for select to authenticated
  using (public.is_staff() or exists (select 1 from public.returns r where r.id = return_id and r.user_id = auth.uid()));

create table public.return_status_history (
  id uuid primary key default gen_random_uuid(),
  return_id uuid not null references public.returns(id) on delete cascade,
  from_status public.return_status,
  to_status public.return_status not null,
  note text,
  changed_by uuid,
  created_at timestamptz not null default now()
);
create index idx_rsh_return on public.return_status_history(return_id, created_at);
grant select on public.return_status_history to authenticated;
grant all on public.return_status_history to service_role;
alter table public.return_status_history enable row level security;
create policy "Read history of own returns; staff all" on public.return_status_history for select to authenticated
  using (public.is_staff() or exists (select 1 from public.returns r where r.id = return_id and r.user_id = auth.uid()));

-- ---------- REVIEWS ----------
create table public.reviews (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  user_id uuid not null default auth.uid(),
  author_name text check (author_name is null or length(author_name) <= 80),
  rating int not null check (rating between 1 and 5),
  comment text check (comment is null or length(comment) <= 2000),
  is_verified boolean not null default false,
  status public.review_status not null default 'published',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (product_id, user_id)
);
create index idx_reviews_product on public.reviews(product_id, status);
grant select on public.reviews to anon;
grant select, insert, update, delete on public.reviews to authenticated;
grant all on public.reviews to service_role;
alter table public.reviews enable row level security;

create or replace function public.has_purchased(_product_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.order_items oi join public.orders o on o.id = oi.order_id
    where oi.product_id = _product_id and o.user_id = auth.uid() and o.status in ('delivered','returned')
  )
$$;

create policy "Public reads published reviews" on public.reviews for select to anon, authenticated
  using (status = 'published' or user_id = auth.uid() or public.is_staff());
create policy "Purchasers write reviews" on public.reviews for insert to authenticated
  with check (user_id = auth.uid() and public.has_purchased(product_id));
create policy "Authors edit own reviews; staff moderate" on public.reviews for update to authenticated
  using (user_id = auth.uid() or public.is_staff()) with check (user_id = auth.uid() or public.is_staff());
create policy "Authors or admins delete reviews" on public.reviews for delete to authenticated
  using (user_id = auth.uid() or public.is_admin());

create or replace function public.guard_review()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.is_verified := public.has_purchased(new.product_id);
    new.status := 'published';
    if new.author_name is null then
      select left(split_part(coalesce(full_name, ''), ' ', 1), 80) into new.author_name from public.profiles where id = new.user_id;
    end if;
  elsif not public.is_staff() then
    new.status := old.status;
    new.is_verified := old.is_verified;
    new.user_id := old.user_id;
    new.product_id := old.product_id;
  end if;
  return new;
end $$;
create trigger trg_reviews_guard before insert or update on public.reviews for each row execute function public.guard_review();
create trigger trg_reviews_updated before update on public.reviews for each row execute function public.set_updated_at();

create or replace function public.refresh_product_rating()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_pid uuid := coalesce(new.product_id, old.product_id);
begin
  update public.products p set
    rating_avg = coalesce((select round(avg(rating)::numeric, 2) from public.reviews where product_id = v_pid and status = 'published'), 0),
    rating_count = (select count(*) from public.reviews where product_id = v_pid and status = 'published')
  where p.id = v_pid;
  return null;
end $$;
create trigger trg_reviews_rating after insert or update or delete on public.reviews for each row execute function public.refresh_product_rating();

-- ---------- NOTIFICATIONS ----------
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  title text not null,
  body text,
  link text,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index idx_notifications_user on public.notifications(user_id, created_at desc);
grant select, update, delete on public.notifications to authenticated;
grant all on public.notifications to service_role;
alter table public.notifications enable row level security;
create policy "Users read own notifications" on public.notifications for select to authenticated using (user_id = auth.uid());
create policy "Users mark own notifications" on public.notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "Users delete own notifications" on public.notifications for delete to authenticated using (user_id = auth.uid());

-- ---------- FINANCE LEDGER ----------
create table public.finance_entries (
  id uuid primary key default gen_random_uuid(),
  entry_type public.finance_entry_type not null,
  amount numeric(12,3) not null check (amount >= 0),
  order_id uuid references public.orders(id) on delete set null,
  return_id uuid references public.returns(id) on delete set null,
  variant_id uuid,
  dedupe_key text not null unique,
  note text,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index idx_finance_type_date on public.finance_entries(entry_type, created_at);
grant select on public.finance_entries to authenticated;
grant all on public.finance_entries to service_role;
alter table public.finance_entries enable row level security;
create policy "Admins read finance" on public.finance_entries for select to authenticated using (public.is_admin());

-- ---------- REALTIME ----------
-- New Supabase projects ship with the supabase_realtime publication, but guard it
-- so the migration is safe on projects where it was dropped.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'orders'
    ) then
      alter publication supabase_realtime add table public.orders;
    end if;
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'order_status_history'
    ) then
      alter publication supabase_realtime add table public.order_status_history;
    end if;
  end if;
end $$;

-- ===== 0002_transactional_functions.sql =====
-- =========================================================
-- weshop transactional business functions
-- =========================================================

-- normalize Tunisian phone to 8 digits (returns null if invalid)
create or replace function public.normalize_phone(_phone text)
returns text language plpgsql immutable set search_path = public as $$
declare v text := regexp_replace(coalesce(_phone, ''), '[^0-9]', '', 'g');
begin
  if v like '00216%' then v := substr(v, 6); end if;
  if v like '216%' and length(v) = 11 then v := substr(v, 4); end if;
  if v ~ '^[2-9][0-9]{7}$' then return v; end if;
  return null;
end $$;

-- ---------- internal: move stock between buckets with movement log ----------
create or replace function public._move_stock(
  _variant_id uuid, _from text, _to text, _qty int, _type public.movement_type,
  _reason text, _order_id uuid, _return_id uuid, _actor uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_inv public.inventory; v_sku text;
begin
  if _qty is null or _qty <= 0 then raise exception 'invalid_quantity'; end if;
  select * into v_inv from public.inventory where variant_id = _variant_id for update;
  if not found then raise exception 'inventory_not_found'; end if;
  if _from = 'available' and v_inv.available < _qty then raise exception 'insufficient_stock'; end if;
  if _from = 'reserved'  and v_inv.reserved  < _qty then raise exception 'insufficient_reserved'; end if;
  if _from = 'damaged'   and v_inv.damaged   < _qty then raise exception 'insufficient_damaged'; end if;
  if _from = 'incoming'  and v_inv.incoming  < _qty then raise exception 'insufficient_incoming'; end if;

  update public.inventory set
    available = available - (case when _from = 'available' then _qty else 0 end) + (case when _to = 'available' then _qty else 0 end),
    reserved  = reserved  - (case when _from = 'reserved'  then _qty else 0 end) + (case when _to = 'reserved'  then _qty else 0 end),
    damaged   = damaged   - (case when _from = 'damaged'   then _qty else 0 end) + (case when _to = 'damaged'   then _qty else 0 end),
    incoming  = incoming  - (case when _from = 'incoming'  then _qty else 0 end) + (case when _to = 'incoming'  then _qty else 0 end),
    updated_at = now()
  where variant_id = _variant_id;

  select sku into v_sku from public.product_variants where id = _variant_id;
  insert into public.inventory_movements(variant_id, sku, from_bucket, to_bucket, quantity, movement_type, reason, order_id, return_id, created_by)
  values (_variant_id, v_sku, _from, _to, _qty, _type, left(_reason, 500), _order_id, _return_id, _actor);
end $$;
revoke execute on function public._move_stock(uuid, text, text, int, public.movement_type, text, uuid, uuid, uuid) from public, anon, authenticated;

-- ---------- availability for storefront ----------
create or replace function public.get_variant_availability(_product_ids uuid[])
returns table (variant_id uuid, product_id uuid, available int)
language sql stable security definer set search_path = public as $$
  select v.id, v.product_id, i.available
  from public.product_variants v
  join public.products p on p.id = v.product_id
  join public.inventory i on i.variant_id = v.id
  where v.product_id = any(_product_ids) and p.status = 'published' and v.is_active
$$;
grant execute on function public.get_variant_availability(uuid[]) to anon, authenticated;

-- ---------- CREATE ORDER (COD) ----------
create or replace function public.create_order(
  _customer_name text, _phone text, _city text, _address text,
  _instructions text, _email text, _items jsonb,
  _promo_code text default null, _save_address boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_phone text := public.normalize_phone(_phone);
  v_order_id uuid;
  v_ref text;
  r record;
  v_var record;
  v_unit numeric(12,3);
  v_subtotal numeric(12,3) := 0;
  v_discount numeric(12,3) := 0;
  v_fee numeric(12,3) := 0;
  v_settings public.store_settings;
  v_promo public.promotions;
  v_lines int := 0;
begin
  if coalesce(length(trim(_customer_name)), 0) < 2 or length(_customer_name) > 120 then raise exception 'invalid_name'; end if;
  if v_phone is null then raise exception 'invalid_phone'; end if;
  if coalesce(length(trim(_city)), 0) < 2 or length(_city) > 80 then raise exception 'invalid_city'; end if;
  if coalesce(length(trim(_address)), 0) < 5 or length(_address) > 500 then raise exception 'invalid_address'; end if;
  if length(coalesce(_instructions, '')) > 500 then raise exception 'invalid_instructions'; end if;
  if _email is not null and length(trim(_email)) > 0 and _email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'invalid_email'; end if;
  if _items is null or jsonb_typeof(_items) <> 'array' or jsonb_array_length(_items) = 0 or jsonb_array_length(_items) > 50 then
    raise exception 'invalid_items';
  end if;

  select * into v_settings from public.store_settings where id;

  v_ref := 'WS' || to_char(now(), 'YYMM') || '-' || lpad(nextval('public.order_ref_seq')::text, 6, '0');

  insert into public.orders(reference, user_id, customer_name, phone, email, city, address, instructions, status, stock_state)
  values (v_ref, v_uid, trim(_customer_name), v_phone, nullif(trim(coalesce(_email, '')), ''), trim(_city), trim(_address),
          nullif(trim(coalesce(_instructions, '')), ''), 'pending', 'reserved')
  returning id into v_order_id;

  -- aggregate duplicate lines; lock in variant id order to avoid deadlocks
  for r in
    select (e->>'variant_id')::uuid as variant_id, sum((e->>'quantity')::int) as qty
    from jsonb_array_elements(_items) e
    group by 1 order by 1
  loop
    if r.variant_id is null or r.qty is null or r.qty < 1 or r.qty > 100 then raise exception 'invalid_quantity'; end if;

    select v.id, v.sku, v.price, v.promo_price, v.is_active, p.id as product_id, p.name_fr, p.status,
           coalesce(c.cost, 0) as cost,
           (select string_agg(coalesce(o.label_fr, o.value), ' / ' order by a.display_order, a.name_fr)
              from public.variant_attribute_values vav
              join public.category_attribute_options o on o.id = vav.option_id
              join public.category_attributes a on a.id = vav.attribute_id
             where vav.variant_id = v.id) as label,
           (select pi.url from public.product_images pi where pi.product_id = p.id order by pi.position limit 1) as image
      into v_var
      from public.product_variants v
      join public.products p on p.id = v.product_id
      left join public.variant_costs c on c.variant_id = v.id
     where v.id = r.variant_id;

    if not found or not v_var.is_active or v_var.status <> 'published' then
      raise exception 'variant_unavailable';
    end if;

    perform 1 from public.inventory where variant_id = r.variant_id and available >= r.qty for update;
    if not found then raise exception 'insufficient_stock:%', v_var.sku; end if;

    perform public._move_stock(r.variant_id, 'available', 'reserved', r.qty::int, 'reservation', 'Commande ' || v_ref, v_order_id, null, v_uid);

    v_unit := coalesce(v_var.promo_price, v_var.price);
    insert into public.order_items(order_id, product_id, variant_id, product_name, variant_label, sku, image_url, unit_price, unit_cost, quantity, line_total)
    values (v_order_id, v_var.product_id, r.variant_id, v_var.name_fr, v_var.label, v_var.sku, v_var.image, v_unit, v_var.cost, r.qty, v_unit * r.qty);

    v_subtotal := v_subtotal + v_unit * r.qty;
    v_lines := v_lines + 1;
  end loop;

  if v_lines = 0 then raise exception 'invalid_items'; end if;

  if _promo_code is not null and length(trim(_promo_code)) > 0 then
    select * into v_promo from public.promotions
     where code = upper(trim(_promo_code)) and is_active
       and (starts_at is null or starts_at <= now())
       and (ends_at is null or ends_at >= now())
       and (max_uses is null or used_count < max_uses)
     for update;
    if not found then raise exception 'invalid_promo'; end if;
    if v_subtotal < v_promo.min_order_amount then raise exception 'promo_min_not_met'; end if;
    v_discount := case when v_promo.type = 'percent' then round(v_subtotal * v_promo.value / 100, 3)
                       else least(v_promo.value, v_subtotal) end;
    update public.promotions set used_count = used_count + 1 where id = v_promo.id;
  end if;

  v_fee := case when v_settings.free_delivery_threshold is not null and (v_subtotal - v_discount) >= v_settings.free_delivery_threshold
                then 0 else coalesce(v_settings.delivery_fee, 0) end;

  update public.orders set
    subtotal = v_subtotal, discount_total = v_discount, delivery_fee = v_fee,
    total = v_subtotal - v_discount + v_fee,
    promotion_id = v_promo.id, promo_code = v_promo.code
  where id = v_order_id;

  insert into public.order_status_history(order_id, from_status, to_status, note, changed_by)
  values (v_order_id, null, 'pending', 'Commande passée', v_uid);

  if v_uid is not null and _save_address then
    if not exists (select 1 from public.addresses where user_id = v_uid and address_line = trim(_address) and city = trim(_city)) then
      insert into public.addresses(user_id, full_name, phone, city, address_line, instructions, is_default)
      values (v_uid, trim(_customer_name), v_phone, trim(_city), trim(_address), nullif(trim(coalesce(_instructions, '')), ''),
              not exists (select 1 from public.addresses where user_id = v_uid));
    end if;
  end if;

  return jsonb_build_object('order_id', v_order_id, 'reference', v_ref, 'total', v_subtotal - v_discount + v_fee);
end $$;
grant execute on function public.create_order(text, text, text, text, text, text, jsonb, text, boolean) to anon, authenticated;

-- ---------- promo preview (no side effects) ----------
create or replace function public.check_promo(_code text, _subtotal numeric)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v public.promotions; v_discount numeric(12,3);
begin
  select * into v from public.promotions
   where code = upper(trim(_code)) and is_active
     and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at >= now())
     and (max_uses is null or used_count < max_uses);
  if not found then return jsonb_build_object('valid', false, 'error', 'invalid_promo'); end if;
  if _subtotal < v.min_order_amount then return jsonb_build_object('valid', false, 'error', 'promo_min_not_met', 'min', v.min_order_amount); end if;
  v_discount := case when v.type = 'percent' then round(_subtotal * v.value / 100, 3) else least(v.value, _subtotal) end;
  return jsonb_build_object('valid', true, 'code', v.code, 'discount', v_discount);
end $$;
grant execute on function public.check_promo(text, numeric) to anon, authenticated;

-- ---------- internal: apply order status ----------
create or replace function public._apply_order_status(_order_id uuid, _status public.order_status, _note text, _actor uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_order public.orders;
  v_allowed boolean;
  r record;
  v_cogs numeric(12,3);
begin
  select * into v_order from public.orders where id = _order_id for update;
  if not found then raise exception 'order_not_found'; end if;
  if v_order.status = _status then raise exception 'same_status'; end if;

  v_allowed := case v_order.status
    when 'pending' then _status in ('confirmed','cancelled')
    when 'confirmed' then _status in ('preparing','cancelled')
    when 'preparing' then _status in ('shipped','cancelled')
    when 'shipped' then _status in ('out_for_delivery','delivered','cancelled')
    when 'out_for_delivery' then _status in ('delivered','cancelled')
    when 'delivered' then _status in ('returned')
    else false end;
  if not v_allowed then raise exception 'invalid_transition'; end if;

  -- stock leaves the warehouse
  if _status in ('shipped','delivered') and v_order.stock_state = 'reserved' then
    for r in select variant_id, sum(quantity)::int q from public.order_items where order_id = _order_id group by variant_id order by variant_id loop
      perform public._move_stock(r.variant_id, 'reserved', null, r.q, 'shipment', 'Expédition ' || v_order.reference, _order_id, null, _actor);
    end loop;
    update public.orders set stock_state = 'consumed' where id = _order_id;
    v_order.stock_state := 'consumed';
  end if;

  -- cancellation: release exactly once
  if _status = 'cancelled' then
    if v_order.stock_state = 'reserved' then
      for r in select variant_id, sum(quantity)::int q from public.order_items where order_id = _order_id group by variant_id order by variant_id loop
        perform public._move_stock(r.variant_id, 'reserved', 'available', r.q, 'reservation_release', 'Annulation ' || v_order.reference, _order_id, null, _actor);
      end loop;
    elsif v_order.stock_state = 'consumed' then
      for r in select variant_id, sum(quantity)::int q from public.order_items where order_id = _order_id group by variant_id order by variant_id loop
        perform public._move_stock(r.variant_id, null, 'available', r.q, 'delivery_return', 'Retour livreur ' || v_order.reference, _order_id, null, _actor);
      end loop;
    end if;
    update public.orders set stock_state = 'released' where id = _order_id;
  end if;

  -- delivered: book the sale once
  if _status = 'delivered' then
    select coalesce(sum(unit_cost * quantity), 0) into v_cogs from public.order_items where order_id = _order_id;
    insert into public.finance_entries(entry_type, amount, order_id, dedupe_key, created_by)
    values ('revenue', v_order.subtotal, _order_id, 'revenue:' || _order_id, _actor),
           ('cogs', v_cogs, _order_id, 'cogs:' || _order_id, _actor),
           ('discount', v_order.discount_total, _order_id, 'discount:' || _order_id, _actor),
           ('delivery_income', v_order.delivery_fee, _order_id, 'delivery:' || _order_id, _actor)
    on conflict (dedupe_key) do nothing;
  end if;

  update public.orders set
    status = _status,
    confirmed_at = case when _status = 'confirmed' then now() else confirmed_at end,
    shipped_at   = case when _status = 'shipped' then now() else shipped_at end,
    delivered_at = case when _status = 'delivered' then now() else delivered_at end,
    cancelled_at = case when _status = 'cancelled' then now() else cancelled_at end
  where id = _order_id;

  insert into public.order_status_history(order_id, from_status, to_status, note, changed_by)
  values (_order_id, v_order.status, _status, nullif(left(trim(coalesce(_note, '')), 500), ''), _actor);

  if v_order.user_id is not null then
    insert into public.notifications(user_id, title, body, link)
    values (v_order.user_id, 'Commande ' || v_order.reference, 'Statut : ' || _status::text, '/my-orders');
  end if;
end $$;
revoke execute on function public._apply_order_status(uuid, public.order_status, text, uuid) from public, anon, authenticated;

create or replace function public.update_order_status(_order_id uuid, _status public.order_status, _note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'forbidden'; end if;
  perform public._apply_order_status(_order_id, _status, _note, auth.uid());
end $$;
revoke execute on function public.update_order_status(uuid, public.order_status, text) from public, anon;
grant execute on function public.update_order_status(uuid, public.order_status, text) to authenticated;

create or replace function public.cancel_my_order(_order_id uuid, _reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v public.orders;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select * into v from public.orders where id = _order_id;
  if not found or v.user_id is distinct from auth.uid() then raise exception 'order_not_found'; end if;
  if v.status <> 'pending' then raise exception 'cannot_cancel'; end if;
  perform public._apply_order_status(_order_id, 'cancelled', coalesce('Annulée par le client. ' || _reason, 'Annulée par le client'), auth.uid());
end $$;
revoke execute on function public.cancel_my_order(uuid, text) from public, anon;
grant execute on function public.cancel_my_order(uuid, text) to authenticated;

-- ---------- CASH COLLECTION ----------
create or replace function public.collect_cod_payment(_order_id uuid, _amount numeric, _collected_by text, _collected_at timestamptz default now(), _note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v public.orders;
begin
  if not public.is_staff() then raise exception 'forbidden'; end if;
  if _amount is null or _amount < 0 then raise exception 'invalid_amount'; end if;
  if coalesce(length(trim(_collected_by)), 0) < 2 then raise exception 'collector_required'; end if;
  select * into v from public.orders where id = _order_id for update;
  if not found then raise exception 'order_not_found'; end if;
  if v.status <> 'delivered' then raise exception 'order_not_delivered'; end if;
  if v.payment_status <> 'unpaid' then raise exception 'already_collected'; end if;

  insert into public.cash_collections(order_id, amount_expected, amount_collected, collected_at, collected_by_name, recorded_by, note)
  values (_order_id, v.total, _amount, coalesce(_collected_at, now()), trim(_collected_by), auth.uid(), nullif(trim(coalesce(_note, '')), ''));

  update public.orders set payment_status = 'paid' where id = _order_id;

  insert into public.finance_entries(entry_type, amount, order_id, dedupe_key, created_by, note)
  values ('cash_collected', _amount, _order_id, 'cash:' || _order_id, auth.uid(), 'Encaissé par ' || trim(_collected_by))
  on conflict (dedupe_key) do nothing;

  insert into public.order_status_history(order_id, from_status, to_status, note, changed_by)
  values (_order_id, v.status, v.status, 'Paiement encaissé : ' || _amount::text || ' TND (' || trim(_collected_by) || ')', auth.uid());
end $$;
revoke execute on function public.collect_cod_payment(uuid, numeric, text, timestamptz, text) from public, anon;
grant execute on function public.collect_cod_payment(uuid, numeric, text, timestamptz, text) to authenticated;

-- ---------- INVENTORY ADJUSTMENTS ----------
create or replace function public.adjust_inventory(_variant_id uuid, _action text, _quantity int, _reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_cost numeric(12,3); v_mid uuid;
begin
  if not public.is_staff() then raise exception 'forbidden'; end if;
  if coalesce(length(trim(_reason)), 0) < 2 then raise exception 'reason_required'; end if;
  if _quantity is null or _quantity <= 0 or _quantity > 100000 then raise exception 'invalid_quantity'; end if;

  case _action
    when 'restock'          then perform public._move_stock(_variant_id, null, 'available', _quantity, 'restock', _reason, null, null, auth.uid());
    when 'initial'          then perform public._move_stock(_variant_id, null, 'available', _quantity, 'initial', _reason, null, null, auth.uid());
    when 'remove'           then perform public._move_stock(_variant_id, 'available', null, _quantity, 'removal', _reason, null, null, auth.uid());
    when 'damage'           then perform public._move_stock(_variant_id, 'available', 'damaged', _quantity, 'damage', _reason, null, null, auth.uid());
    when 'repair_damaged'   then perform public._move_stock(_variant_id, 'damaged', 'available', _quantity, 'damage_repaired', _reason, null, null, auth.uid());
    when 'writeoff_damaged' then perform public._move_stock(_variant_id, 'damaged', null, _quantity, 'damage_writeoff', _reason, null, null, auth.uid());
    when 'incoming'         then perform public._move_stock(_variant_id, null, 'incoming', _quantity, 'incoming', _reason, null, null, auth.uid());
    when 'receive_incoming' then perform public._move_stock(_variant_id, 'incoming', 'available', _quantity, 'incoming_received', _reason, null, null, auth.uid());
    else raise exception 'invalid_action';
  end case;

  if _action = 'damage' then
    select cost into v_cost from public.variant_costs where variant_id = _variant_id;
    select id into v_mid from public.inventory_movements where variant_id = _variant_id order by created_at desc limit 1;
    insert into public.finance_entries(entry_type, amount, variant_id, dedupe_key, created_by, note)
    values ('damage_loss', coalesce(v_cost, 0) * _quantity, _variant_id, 'damage:' || v_mid, auth.uid(), left(_reason, 300))
    on conflict (dedupe_key) do nothing;
  end if;
end $$;
revoke execute on function public.adjust_inventory(uuid, text, int, text) from public, anon;
grant execute on function public.adjust_inventory(uuid, text, int, text) to authenticated;

create or replace function public.set_low_stock_threshold(_variant_id uuid, _threshold int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'forbidden'; end if;
  if _threshold is null or _threshold < 0 or _threshold > 100000 then raise exception 'invalid_threshold'; end if;
  update public.inventory set low_stock_threshold = _threshold, updated_at = now() where variant_id = _variant_id;
end $$;
revoke execute on function public.set_low_stock_threshold(uuid, int) from public, anon;
grant execute on function public.set_low_stock_threshold(uuid, int) to authenticated;

-- ---------- RETURNS ----------
create or replace function public.request_return(_order_id uuid, _items jsonb, _reason text, _description text default null, _photos text[] default array[]::text[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_order public.orders;
  v_window int;
  v_return_id uuid;
  v_ref text;
  r record;
  v_oi public.order_items;
  v_already int;
  v_count int := 0;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if coalesce(length(trim(_reason)), 0) < 2 or length(_reason) > 200 then raise exception 'invalid_reason'; end if;
  if length(coalesce(_description, '')) > 2000 then raise exception 'invalid_description'; end if;
  if coalesce(array_length(_photos, 1), 0) > 6 then raise exception 'too_many_photos'; end if;
  if _items is null or jsonb_typeof(_items) <> 'array' or jsonb_array_length(_items) = 0 then raise exception 'invalid_items'; end if;

  select * into v_order from public.orders where id = _order_id for update;
  if not found or v_order.user_id is distinct from auth.uid() then raise exception 'order_not_found'; end if;
  if v_order.status <> 'delivered' then raise exception 'order_not_delivered'; end if;
  select return_window_days into v_window from public.store_settings where id;
  if v_order.delivered_at < now() - make_interval(days => v_window) then raise exception 'return_window_expired'; end if;

  v_ref := 'RT' || to_char(now(), 'YYMM') || '-' || lpad(nextval('public.return_ref_seq')::text, 5, '0');
  insert into public.returns(reference, order_id, user_id, reason, description, photos)
  values (v_ref, _order_id, auth.uid(), trim(_reason), nullif(trim(coalesce(_description, '')), ''), coalesce(_photos, array[]::text[]))
  returning id into v_return_id;

  for r in select (e->>'order_item_id')::uuid as oid, (e->>'quantity')::int as qty from jsonb_array_elements(_items) e loop
    if r.qty is null or r.qty <= 0 then continue; end if;
    select * into v_oi from public.order_items where id = r.oid and order_id = _order_id;
    if not found then raise exception 'invalid_item'; end if;
    select coalesce(sum(ri.quantity), 0) into v_already
      from public.return_items ri join public.returns rt on rt.id = ri.return_id
     where ri.order_item_id = r.oid and rt.status <> 'rejected';
    if v_already + r.qty > v_oi.quantity then raise exception 'quantity_exceeds_order'; end if;
    insert into public.return_items(return_id, order_item_id, variant_id, quantity) values (v_return_id, r.oid, v_oi.variant_id, r.qty);
    v_count := v_count + 1;
  end loop;
  if v_count = 0 then raise exception 'invalid_items'; end if;

  insert into public.return_status_history(return_id, from_status, to_status, note, changed_by)
  values (v_return_id, null, 'requested', 'Demande de retour', auth.uid());

  return jsonb_build_object('return_id', v_return_id, 'reference', v_ref);
end $$;
revoke execute on function public.request_return(uuid, jsonb, text, text, text[]) from public, anon;
grant execute on function public.request_return(uuid, jsonb, text, text, text[]) to authenticated;

create or replace function public.update_return_status(_return_id uuid, _status public.return_status, _note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v public.returns; v_ok boolean;
begin
  if not public.is_staff() then raise exception 'forbidden'; end if;
  select * into v from public.returns where id = _return_id for update;
  if not found then raise exception 'return_not_found'; end if;
  v_ok := case v.status
    when 'requested' then _status in ('approved','rejected')
    when 'approved' then _status in ('received','rejected')
    else false end;
  if not v_ok then raise exception 'invalid_transition'; end if;
  update public.returns set status = _status, admin_note = coalesce(nullif(trim(coalesce(_note, '')), ''), admin_note) where id = _return_id;
  insert into public.return_status_history(return_id, from_status, to_status, note, changed_by)
  values (_return_id, v.status, _status, nullif(left(trim(coalesce(_note, '')), 500), ''), auth.uid());
  insert into public.notifications(user_id, title, body, link)
  values (v.user_id, 'Retour ' || v.reference, 'Statut : ' || _status::text, '/my-returns');
end $$;
revoke execute on function public.update_return_status(uuid, public.return_status, text) from public, anon;
grant execute on function public.update_return_status(uuid, public.return_status, text) to authenticated;

-- _items: [{ "return_item_id": uuid, "condition": "resalable"|"damaged"|"unsellable" }]
create or replace function public.process_return(_return_id uuid, _items jsonb, _note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_ret public.returns;
  v_order public.orders;
  r record;
  v_ri public.return_items;
  v_oi public.order_items;
  v_cond public.return_condition;
  v_refund numeric(12,3) := 0;
  v_loss numeric(12,3) := 0;
  v_ordered int; v_returned int;
begin
  if not public.is_staff() then raise exception 'forbidden'; end if;
  select * into v_ret from public.returns where id = _return_id for update;
  if not found then raise exception 'return_not_found'; end if;
  if v_ret.status not in ('approved','received') then raise exception 'return_not_ready'; end if;
  select * into v_order from public.orders where id = v_ret.order_id for update;

  for r in select (e->>'return_item_id')::uuid as rid, (e->>'condition') as cond from jsonb_array_elements(_items) e loop
    select * into v_ri from public.return_items where id = r.rid and return_id = _return_id for update;
    if not found then raise exception 'invalid_item'; end if;
    if v_ri.processed_at is not null then raise exception 'already_processed'; end if;
    v_cond := r.cond::public.return_condition;
    select * into v_oi from public.order_items where id = v_ri.order_item_id;

    if v_cond = 'resalable' then
      perform public._move_stock(v_ri.variant_id, null, 'available', v_ri.quantity, 'return_restock', 'Retour ' || v_ret.reference, v_ret.order_id, _return_id, auth.uid());
      update public.return_items set condition = v_cond, processed_at = now(), loss_amount = 0 where id = v_ri.id;
    else
      perform public._move_stock(v_ri.variant_id, null, 'damaged', v_ri.quantity, 'return_damaged', 'Retour ' || v_ret.reference || ' (' || v_cond::text || ')', v_ret.order_id, _return_id, auth.uid());
      update public.return_items set condition = v_cond, processed_at = now(), loss_amount = v_oi.unit_cost * v_ri.quantity where id = v_ri.id;
      insert into public.finance_entries(entry_type, amount, order_id, return_id, variant_id, dedupe_key, created_by)
      values ('return_loss', v_oi.unit_cost * v_ri.quantity, v_ret.order_id, _return_id, v_ri.variant_id, 'return_loss:' || v_ri.id, auth.uid())
      on conflict (dedupe_key) do nothing;
      v_loss := v_loss + v_oi.unit_cost * v_ri.quantity;
    end if;

    insert into public.finance_entries(entry_type, amount, order_id, return_id, variant_id, dedupe_key, created_by)
    values ('return_revenue_reversal', v_oi.unit_price * v_ri.quantity, v_ret.order_id, _return_id, v_ri.variant_id, 'return_rev:' || v_ri.id, auth.uid()),
           ('return_cogs_reversal', v_oi.unit_cost * v_ri.quantity, v_ret.order_id, _return_id, v_ri.variant_id, 'return_cogs:' || v_ri.id, auth.uid())
    on conflict (dedupe_key) do nothing;

    v_refund := v_refund + v_oi.unit_price * v_ri.quantity;
  end loop;

  if exists (select 1 from public.return_items where return_id = _return_id and processed_at is null) then
    raise exception 'all_items_required';
  end if;

  update public.returns set status = 'processed', refund_amount = v_refund, processed_at = now(), processed_by = auth.uid(),
         admin_note = coalesce(nullif(trim(coalesce(_note, '')), ''), admin_note)
   where id = _return_id;
  insert into public.return_status_history(return_id, from_status, to_status, note, changed_by)
  values (_return_id, v_ret.status, 'processed', nullif(left(trim(coalesce(_note, '')), 500), ''), auth.uid());

  if v_order.payment_status = 'paid' and v_refund > 0 then
    insert into public.finance_entries(entry_type, amount, order_id, return_id, dedupe_key, created_by)
    values ('refund', v_refund, v_order.id, _return_id, 'refund:' || _return_id, auth.uid())
    on conflict (dedupe_key) do nothing;
  end if;

  -- whole order returned?
  select coalesce(sum(quantity), 0) into v_ordered from public.order_items where order_id = v_order.id;
  select coalesce(sum(ri.quantity), 0) into v_returned from public.return_items ri join public.returns rt on rt.id = ri.return_id
   where rt.order_id = v_order.id and rt.status = 'processed';
  if v_returned >= v_ordered and v_order.status = 'delivered' then
    perform public._apply_order_status(v_order.id, 'returned', 'Retour complet ' || v_ret.reference, auth.uid());
    if v_order.payment_status = 'paid' then
      update public.orders set payment_status = 'refunded' where id = v_order.id;
    end if;
  end if;

  insert into public.notifications(user_id, title, body, link)
  values (v_ret.user_id, 'Retour ' || v_ret.reference, 'Votre retour a été traité', '/my-returns');

  return jsonb_build_object('refund', v_refund, 'loss', v_loss);
end $$;
revoke execute on function public.process_return(uuid, jsonb, text) from public, anon;
grant execute on function public.process_return(uuid, jsonb, text) to authenticated;

-- ---------- GUEST TRACKING ----------
create or replace function public.track_order(_reference text, _phone text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v public.orders; v_phone text := public.normalize_phone(_phone);
begin
  if v_phone is null or coalesce(length(trim(_reference)), 0) < 4 then return null; end if;
  select * into v from public.orders where reference = upper(trim(_reference)) and phone = v_phone;
  if not found then return null; end if;
  return jsonb_build_object(
    'id', v.id, 'reference', v.reference, 'status', v.status, 'payment_status', v.payment_status,
    'created_at', v.created_at, 'customer_name', v.customer_name, 'city', v.city, 'address', v.address,
    'subtotal', v.subtotal, 'discount_total', v.discount_total, 'delivery_fee', v.delivery_fee, 'total', v.total,
    'items', coalesce((select jsonb_agg(jsonb_build_object('product_name', product_name, 'variant_label', variant_label,
                'quantity', quantity, 'unit_price', unit_price, 'line_total', line_total, 'image_url', image_url))
              from public.order_items where order_id = v.id), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(jsonb_build_object('to_status', to_status, 'created_at', created_at) order by created_at)
              from public.order_status_history where order_id = v.id and from_status is distinct from to_status), '[]'::jsonb)
  );
end $$;
grant execute on function public.track_order(text, text) to anon, authenticated;

-- ---------- ADMIN: role management ----------
create or replace function public.set_user_role(_user_id uuid, _role public.app_role, _grant boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if _grant then
    insert into public.user_roles(user_id, role) values (_user_id, _role) on conflict do nothing;
  else
    if _user_id = auth.uid() and _role = 'admin' then raise exception 'cannot_remove_self'; end if;
    delete from public.user_roles where user_id = _user_id and role = _role;
  end if;
end $$;
revoke execute on function public.set_user_role(uuid, public.app_role, boolean) from public, anon;
grant execute on function public.set_user_role(uuid, public.app_role, boolean) to authenticated;

-- internal helpers shouldn't be callable directly by clients
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.handle_new_variant() from public, anon, authenticated;
revoke execute on function public.refresh_variant_combination() from public, anon, authenticated;
revoke execute on function public.refresh_product_rating() from public, anon, authenticated;
revoke execute on function public.audit_row() from public, anon, authenticated;
revoke execute on function public.guard_review() from public, anon, authenticated;

-- ===== 0003_description_templates.sql =====
CREATE TABLE public.description_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 2 AND 80),
  summary text CHECK (summary IS NULL OR char_length(summary) <= 200),
  instructions text NOT NULL CHECK (char_length(btrim(instructions)) BETWEEN 10 AND 3000),
  target_length text NOT NULL DEFAULT 'medium' CHECK (target_length IN ('short','medium','long')),
  is_active boolean NOT NULL DEFAULT true,
  display_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.description_templates TO authenticated;
GRANT ALL ON public.description_templates TO service_role;

ALTER TABLE public.description_templates ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins read description templates" ON public.description_templates
  FOR SELECT TO authenticated USING (public.is_admin());
CREATE POLICY "Admins insert description templates" ON public.description_templates
  FOR INSERT TO authenticated WITH CHECK (public.is_admin());
CREATE POLICY "Admins update description templates" ON public.description_templates
  FOR UPDATE TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
CREATE POLICY "Admins delete description templates" ON public.description_templates
  FOR DELETE TO authenticated USING (public.is_admin());

CREATE TRIGGER description_templates_updated_at BEFORE UPDATE ON public.description_templates
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER description_templates_audit AFTER INSERT OR UPDATE OR DELETE ON public.description_templates
  FOR EACH ROW EXECUTE FUNCTION public.audit_row();


-- Seed rows for description_templates live in 0006_seed_demo_catalog.sql.

-- ===== 0004_storage_policies.sql =====
-- =========================================================
-- Storage: private buckets + object policies
-- =========================================================
-- Both buckets are private. The app uploads files and stores long-lived signed
-- URLs on catalog rows (see src/lib/storage.ts), so anonymous shoppers can still
-- render images without a public bucket.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('catalog', 'catalog', false, 5242880, array['image/jpeg', 'image/png', 'image/webp', 'image/avif']),
  ('return-photos', 'return-photos', false, 5242880, array['image/jpeg', 'image/png', 'image/webp', 'image/avif'])
on conflict (id) do nothing;

-- Catalog images: anyone can read (signed links), only admins write
create policy "Catalog images readable" on storage.objects for select to anon, authenticated
  using (bucket_id = 'catalog');
create policy "Admins upload catalog images" on storage.objects for insert to authenticated
  with check (bucket_id = 'catalog' and public.is_admin());
create policy "Admins update catalog images" on storage.objects for update to authenticated
  using (bucket_id = 'catalog' and public.is_admin());
create policy "Admins delete catalog images" on storage.objects for delete to authenticated
  using (bucket_id = 'catalog' and public.is_admin());

-- Return photos: customers write into their own folder; owner + staff read
create policy "Customers upload own return photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'return-photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "Owner or staff read return photos" on storage.objects for select to authenticated
  using (bucket_id = 'return-photos' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_staff()));
create policy "Owner deletes own return photos" on storage.objects for delete to authenticated
  using (bucket_id = 'return-photos' and (storage.foldername(name))[1] = auth.uid()::text);

-- ===== 0005_catalog_rpcs.sql =====
-- =========================================================
-- weshop catalog / marketplace-independent RPCs
-- Reconstructed on the fresh Supabase project.
-- Apply after 0004_storage_policies.sql. Depends on:
--   0001_core_schema.sql (tables, enums, RLS, triggers, helpers)
--   0002_transactional_functions.sql (public._move_stock)
--
--   save_product    : admin-only catalog writer (product + specs + variants + images)
--   delete_product  : admin-only delete; archives instead when order history exists
--   search_products : anonymous storefront listing (facets, sort, count)
--   get_best_sellers: anonymous storefront ranking by units sold
-- =========================================================

-- ---------- ADMIN: upsert one product with its attributes, variants and images ----------
create or replace function public.save_product(
  _product jsonb,
  _attributes jsonb,
  _variants jsonb,
  _images jsonb
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_category_id uuid;
  v_name_fr text;
  v_name_ar text;
  v_slug text;
  v_sku text;
  v_description_fr text;
  v_description_ar text;
  v_brand text;
  v_model text;
  v_warranty text;
  v_status public.product_status;
  v_status_txt text;
  v_is_featured boolean;
  v_has_variants boolean;
  v_purchase numeric(12,3);
  v_attrs jsonb;
  v_vars jsonb;
  v_imgs jsonb;
  v_n int;
  v_i int;
  v_j int;
  v_e jsonb;
  v_o jsonb;
  v_opt_list jsonb;
  v_attr_id uuid;
  v_opt_id uuid;
  v_vid uuid;
  v_is_new boolean;
  v_sku_v text;
  v_price numeric(12,3);
  v_promo numeric(12,3);
  v_cost numeric(12,3);
  v_barcode text;
  v_is_active boolean;
  v_stock int;
  v_txt text;
  v_min_price numeric(12,3);
  v_min_eff numeric(12,3);
  v_eff numeric(12,3);
  v_active_count int := 0;
  v_skus_seen text[] := '{}';
  v_combo_keys text[] := '{}';
  v_combo text;
  v_missing text;
  v_kept_ids uuid[] := '{}';
begin
  if not public.is_admin() then
    raise exception 'forbidden';
  end if;
  if _product is null or jsonb_typeof(_product) <> 'object' then
    raise exception 'invalid_payload: product';
  end if;

  v_attrs := case when _attributes is null or jsonb_typeof(_attributes) <> 'array' then '[]'::jsonb else _attributes end;
  v_vars  := case when _variants   is null or jsonb_typeof(_variants)   <> 'array' then '[]'::jsonb else _variants   end;
  v_imgs  := case when _images     is null or jsonb_typeof(_images)     <> 'array' then '[]'::jsonb else _images     end;

  -- ---------- product scalars ----------
  v_name_fr := btrim(coalesce(_product->>'name_fr', ''));
  if v_name_fr = '' or length(v_name_fr) > 200 then
    raise exception 'invalid_payload: name_fr';
  end if;

  v_name_ar := nullif(btrim(coalesce(_product->>'name_ar', '')), '');
  if v_name_ar is not null and length(v_name_ar) > 200 then
    raise exception 'invalid_payload: name_ar';
  end if;

  v_slug := btrim(coalesce(_product->>'slug', ''));
  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then
    raise exception 'invalid_payload: slug';
  end if;

  v_sku := btrim(coalesce(_product->>'sku', ''));
  if v_sku = '' or length(v_sku) > 64 then
    raise exception 'invalid_payload: sku';
  end if;

  v_description_fr := nullif(btrim(coalesce(_product->>'description_fr', '')), '');
  if v_description_fr is not null and length(v_description_fr) > 10000 then
    raise exception 'invalid_payload: description_fr';
  end if;

  v_description_ar := nullif(btrim(coalesce(_product->>'description_ar', '')), '');
  if v_description_ar is not null and length(v_description_ar) > 10000 then
    raise exception 'invalid_payload: description_ar';
  end if;

  v_brand := nullif(btrim(coalesce(_product->>'brand', '')), '');
  if v_brand is not null and length(v_brand) > 80 then
    raise exception 'invalid_payload: brand';
  end if;

  v_model := nullif(btrim(coalesce(_product->>'model', '')), '');
  if v_model is not null and length(v_model) > 80 then
    raise exception 'invalid_payload: model';
  end if;

  v_warranty := nullif(btrim(coalesce(_product->>'warranty', '')), '');
  if v_warranty is not null and length(v_warranty) > 200 then
    raise exception 'invalid_payload: warranty';
  end if;

  v_status_txt := coalesce(nullif(btrim(coalesce(_product->>'status', '')), ''), 'draft');
  if v_status_txt not in ('draft', 'published', 'archived') then
    raise exception 'invalid_payload: status';
  end if;
  v_status := v_status_txt::public.product_status;

  v_is_featured := coalesce((_product->>'is_featured')::boolean, false);
  v_has_variants := coalesce((_product->>'has_variants')::boolean, false);

  v_txt := nullif(btrim(coalesce(_product->>'purchase_price', '')), '');
  if v_txt is null then
    v_purchase := 0;
  elsif v_txt !~ '^[0-9]+(\.[0-9]+)?$' then
    raise exception 'invalid_payload: purchase_price';
  else
    v_purchase := v_txt::numeric(12,3);
  end if;

  -- ---------- category + target product ----------
  if nullif(btrim(coalesce(_product->>'category_id', '')), '') is null then
    raise exception 'category_required';
  end if;
  v_category_id := (_product->>'category_id')::uuid;
  if not exists (select 1 from public.categories c where c.id = v_category_id) then
    raise exception 'invalid_payload: category';
  end if;

  v_txt := nullif(btrim(coalesce(_product->>'id', '')), '');
  if v_txt is not null then
    v_id := v_txt::uuid;
    if not exists (select 1 from public.products p where p.id = v_id) then
      raise exception 'invalid_payload: product not found';
    end if;
  end if;

  -- case-insensitive uniqueness, excluding the row being edited
  if exists (
    select 1 from public.products p
    where lower(p.sku) = lower(v_sku) and p.id is distinct from v_id
  ) then
    raise exception 'duplicate_sku: %', v_sku;
  end if;
  if exists (
    select 1 from public.products p
    where lower(p.slug) = lower(v_slug) and p.id is distinct from v_id
  ) then
    raise exception 'duplicate_slug: %', v_slug;
  end if;

  -- ---------- images ----------
  if jsonb_array_length(v_imgs) > 20 then
    raise exception 'too_many_images';
  end if;
  for v_i in 0 .. jsonb_array_length(v_imgs) - 1 loop
    v_e := v_imgs -> v_i;
    if jsonb_typeof(v_e) <> 'object' then
      raise exception 'invalid_payload: image';
    end if;
    if nullif(btrim(coalesce(v_e->>'url', '')), '') is null then
      raise exception 'invalid_payload: image url';
    end if;
    if nullif(btrim(coalesce(v_e->>'storage_path', '')), '') is not null and length(v_e->>'storage_path') > 1000 then
      raise exception 'invalid_payload: image storage_path';
    end if;
    if length(coalesce(v_e->>'alt', '')) > 200 then
      raise exception 'invalid_payload: image alt';
    end if;
  end loop;

  -- ---------- attribute values (spec sheet) ----------
  if jsonb_array_length(v_attrs) > 500 then
    raise exception 'invalid_payload: attributes';
  end if;
  for v_i in 0 .. jsonb_array_length(v_attrs) - 1 loop
    v_e := v_attrs -> v_i;
    if jsonb_typeof(v_e) <> 'object' then
      raise exception 'invalid_payload: attribute';
    end if;
    if nullif(btrim(coalesce(v_e->>'attribute_id', '')), '') is null then
      raise exception 'invalid_attribute';
    end if;
    v_attr_id := (v_e->>'attribute_id')::uuid;
    if not exists (
      select 1 from public.get_category_attributes(v_category_id) ca where ca.id = v_attr_id
    ) then
      raise exception 'invalid_attribute';
    end if;
    if nullif(btrim(coalesce(v_e->>'option_id', '')), '') is not null then
      v_opt_id := (v_e->>'option_id')::uuid;
      if not exists (
        select 1 from public.category_attribute_options o
        where o.id = v_opt_id and o.attribute_id = v_attr_id
      ) then
        raise exception 'invalid_option';
      end if;
    end if;
    v_txt := nullif(btrim(coalesce(v_e->>'value_number', '')), '');
    if v_txt is not null and v_txt !~ '^-?[0-9]+(\.[0-9]+)?$' then
      raise exception 'invalid_payload: value_number';
    end if;
    v_txt := nullif(btrim(coalesce(v_e->>'value_boolean', '')), '');
    if v_txt is not null and lower(v_txt) not in ('true', 'false') then
      raise exception 'invalid_payload: value_boolean';
    end if;
    v_txt := nullif(btrim(coalesce(v_e->>'value_date', '')), '');
    if v_txt is not null and v_txt !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
      raise exception 'invalid_payload: value_date';
    end if;
  end loop;

  -- required, non-variant attributes of the category (inherited included)
  select string_agg(ca.name_fr, ', ')
    into v_missing
  from public.get_category_attributes(v_category_id) ca
  where ca.is_required
    and not ca.is_variant
    and not exists (
      select 1
      from jsonb_array_elements(v_attrs) e
      where (e->>'attribute_id')::uuid = ca.id
        and (
          nullif(btrim(coalesce(e->>'option_id', '')), '') is not null
          or nullif(btrim(coalesce(e->>'value_text', '')), '') is not null
          or nullif(btrim(coalesce(e->>'value_number', '')), '') is not null
          or nullif(btrim(coalesce(e->>'value_boolean', '')), '') is not null
          or nullif(btrim(coalesce(e->>'value_date', '')), '') is not null
        )
    );
  if v_missing is not null then
    raise exception 'missing_required: %', v_missing;
  end if;

  -- ---------- variants, first pass: validate + derive the product price ----------
  v_n := jsonb_array_length(v_vars);
  if v_n = 0 then
    raise exception 'variants_required';
  end if;
  if v_n > 200 then
    raise exception 'too_many_variants';
  end if;
  if not v_has_variants and v_n <> 1 then
    raise exception 'invalid_payload: exactly one variant is required when has_variants is false';
  end if;

  for v_i in 0 .. v_n - 1 loop
    v_e := v_vars -> v_i;
    if jsonb_typeof(v_e) <> 'object' then
      raise exception 'invalid_payload: variant';
    end if;

    if nullif(btrim(coalesce(v_e->>'id', '')), '') is not null then
      v_vid := (v_e->>'id')::uuid;
      if v_id is null or not exists (
        select 1 from public.product_variants pv where pv.id = v_vid and pv.product_id = v_id
      ) then
        raise exception 'invalid_payload: variant does not belong to this product';
      end if;
    end if;

    v_sku_v := btrim(coalesce(v_e->>'sku', ''));
    if v_sku_v = '' or length(v_sku_v) > 64 then
      raise exception 'invalid_payload: variant sku';
    end if;
    if lower(v_sku_v) = any (v_skus_seen) then
      raise exception 'duplicate_sku: %', v_sku_v;
    end if;
    if exists (
      select 1 from public.product_variants pv
      where lower(pv.sku) = lower(v_sku_v)
        and (v_id is null or pv.product_id is distinct from v_id)
    ) then
      raise exception 'duplicate_sku: %', v_sku_v;
    end if;
    v_skus_seen := array_append(v_skus_seen, lower(v_sku_v));

    v_txt := nullif(btrim(coalesce(v_e->>'price', '')), '');
    if v_txt is null or v_txt !~ '^[0-9]+(\.[0-9]+)?$' then
      raise exception 'invalid_payload: variant price';
    end if;
    v_price := v_txt::numeric(12,3);

    v_txt := nullif(btrim(coalesce(v_e->>'promo_price', '')), '');
    v_promo := null;
    if v_txt is not null then
      if v_txt !~ '^[0-9]+(\.[0-9]+)?$' then
        raise exception 'invalid_payload: variant promo_price';
      end if;
      v_promo := v_txt::numeric(12,3);
      if v_promo >= v_price then
        raise exception 'invalid_payload: promo_price must be lower than price';
      end if;
    end if;

    v_txt := nullif(btrim(coalesce(v_e->>'cost', '')), '');
    v_cost := 0;
    if v_txt is not null then
      if v_txt !~ '^[0-9]+(\.[0-9]+)?$' then
        raise exception 'invalid_payload: variant cost';
      end if;
      v_cost := v_txt::numeric(12,3);
    end if;

    v_barcode := nullif(btrim(coalesce(v_e->>'barcode', '')), '');
    if v_barcode is not null and length(v_barcode) > 64 then
      raise exception 'invalid_payload: variant barcode';
    end if;

    v_is_active := coalesce((v_e->>'is_active')::boolean, true);

    v_stock := 0;
    if nullif(btrim(coalesce(v_e->>'id', '')), '') is null then
      v_txt := nullif(btrim(coalesce(v_e->>'initial_stock', '')), '');
      if v_txt is not null then
        if v_txt !~ '^[0-9]+$' then
          raise exception 'invalid_quantity';
        end if;
        v_stock := v_txt::int;
        if v_stock > 100000 then
          raise exception 'invalid_quantity';
        end if;
      end if;
    end if;

    v_opt_list := coalesce(v_e->'options', '[]'::jsonb);
    if jsonb_typeof(v_opt_list) <> 'array' then
      raise exception 'invalid_payload: variant options';
    end if;
    if jsonb_array_length(v_opt_list) > 0 then
      if jsonb_array_length(v_opt_list) > 20 then
        raise exception 'invalid_payload: variant options';
      end if;
      for v_j in 0 .. jsonb_array_length(v_opt_list) - 1 loop
        v_o := v_opt_list -> v_j;
        if jsonb_typeof(v_o) <> 'object' then
          raise exception 'invalid_payload: variant option';
        end if;
        if nullif(btrim(coalesce(v_o->>'attribute_id', '')), '') is null
           or nullif(btrim(coalesce(v_o->>'option_id', '')), '') is null then
          raise exception 'invalid_payload: variant option';
        end if;
        v_attr_id := (v_o->>'attribute_id')::uuid;
        v_opt_id := (v_o->>'option_id')::uuid;
        if not exists (
          select 1 from public.get_category_attributes(v_category_id) ca where ca.id = v_attr_id
        ) then
          raise exception 'invalid_attribute';
        end if;
        if not exists (
          select 1 from public.category_attribute_options o
          where o.id = v_opt_id and o.attribute_id = v_attr_id
        ) then
          raise exception 'invalid_option';
        end if;
      end loop;

      -- canonical combination key (same idea as public.refresh_variant_combination)
      select string_agg((o->>'attribute_id') || ':' || (o->>'option_id'), '|' order by (o->>'attribute_id'))
        into v_combo
      from jsonb_array_elements(v_opt_list) o;
      if v_combo = any (v_combo_keys) then
        raise exception 'duplicate_combination';
      end if;
      v_combo_keys := array_append(v_combo_keys, v_combo);
    elsif v_has_variants then
      raise exception 'variant_options_required';
    end if;

    if v_is_active then
      v_active_count := v_active_count + 1;
      if v_min_price is null or v_price < v_min_price then
        v_min_price := v_price;
      end if;
      v_eff := coalesce(v_promo, v_price);
      if v_min_eff is null or v_eff < v_min_eff then
        v_min_eff := v_eff;
      end if;
    end if;
  end loop;

  if v_active_count = 0 then
    raise exception 'active_variant_required';
  end if;

  -- ---------- product row ----------
  if v_id is null then
    insert into public.products (
      category_id, name_fr, name_ar, slug, sku, description_fr, description_ar,
      brand, model, price, promo_price, warranty, status, has_variants, is_featured
    ) values (
      v_category_id, v_name_fr, v_name_ar, v_slug, v_sku, v_description_fr, v_description_ar,
      v_brand, v_model, v_min_price,
      case when v_min_eff is not null and v_min_eff < v_min_price then v_min_eff else null end,
      v_warranty, v_status, v_has_variants, v_is_featured
    )
    returning id into v_id;
  else
    update public.products set
      category_id = v_category_id,
      name_fr = v_name_fr,
      name_ar = v_name_ar,
      slug = v_slug,
      sku = v_sku,
      description_fr = v_description_fr,
      description_ar = v_description_ar,
      brand = v_brand,
      model = v_model,
      price = v_min_price,
      promo_price = case when v_min_eff is not null and v_min_eff < v_min_price then v_min_eff else null end,
      warranty = v_warranty,
      status = v_status,
      has_variants = v_has_variants,
      is_featured = v_is_featured
    where id = v_id;
  end if;

  -- published_at is left to public.set_published_at() (trigger on 0001) to avoid double stamping.

  -- admin-only purchase cost (trigger handle_new_variant copies it to new variant costs)
  insert into public.product_private (product_id, purchase_price, updated_at)
  values (v_id, v_purchase, now())
  on conflict (product_id) do update
    set purchase_price = excluded.purchase_price, updated_at = now();

  -- ---------- replace attributes and images wholesale ----------
  delete from public.product_attribute_values where product_id = v_id;
  if jsonb_array_length(v_attrs) > 0 then
    insert into public.product_attribute_values (
      product_id, attribute_id, option_id, value_text, value_number, value_boolean, value_date
    )
    select distinct on (
      (e->>'attribute_id')::uuid,
      coalesce(nullif(btrim(coalesce(e->>'option_id', '')), '')::uuid, '00000000-0000-0000-0000-000000000000'::uuid)
    )
      v_id,
      (e->>'attribute_id')::uuid,
      nullif(btrim(coalesce(e->>'option_id', '')), '')::uuid,
      nullif(btrim(coalesce(e->>'value_text', '')), ''),
      nullif(btrim(coalesce(e->>'value_number', '')), '')::numeric,
      case lower(btrim(coalesce(e->>'value_boolean', '')))
        when 'true' then true
        when 'false' then false
        else null
      end,
      nullif(btrim(coalesce(e->>'value_date', '')), '')::date
    from jsonb_array_elements(v_attrs) e
    where nullif(btrim(coalesce(e->>'option_id', '')), '') is not null
       or nullif(btrim(coalesce(e->>'value_text', '')), '') is not null
       or nullif(btrim(coalesce(e->>'value_number', '')), '') is not null
       or nullif(btrim(coalesce(e->>'value_boolean', '')), '') is not null
       or nullif(btrim(coalesce(e->>'value_date', '')), '') is not null;
  end if;

  delete from public.product_images where product_id = v_id;
  if jsonb_array_length(v_imgs) > 0 then
    insert into public.product_images (product_id, storage_path, url, alt, position)
    select
      v_id,
      nullif(btrim(coalesce(e->>'storage_path', '')), ''),
      btrim(coalesce(e->>'url', '')),
      nullif(btrim(coalesce(e->>'alt', '')), ''),
      (t.ord - 1)::int
    from jsonb_array_elements(v_imgs) with ordinality as t(e, ord);
  end if;

  -- ---------- variants, second pass: upsert rows, options, costs, initial stock ----------
  v_kept_ids := '{}';
  for v_i in 0 .. v_n - 1 loop
    v_e := v_vars -> v_i;
    v_is_new := nullif(btrim(coalesce(v_e->>'id', '')), '') is null;

    -- values were validated in the first pass
    v_price := (v_e->>'price')::numeric(12,3);
    v_promo := nullif(btrim(coalesce(v_e->>'promo_price', '')), '')::numeric(12,3);
    v_cost := coalesce(nullif(btrim(coalesce(v_e->>'cost', '')), '')::numeric(12,3), 0);
    v_barcode := nullif(btrim(coalesce(v_e->>'barcode', '')), '');
    v_is_active := coalesce((v_e->>'is_active')::boolean, true);
    v_stock := case
      when v_is_new then coalesce(nullif(btrim(coalesce(v_e->>'initial_stock', '')), '')::int, 0)
      else 0
    end;
    v_opt_list := coalesce(v_e->'options', '[]'::jsonb);

    if v_is_new then
      insert into public.product_variants (
        product_id, sku, price, promo_price, barcode, is_active, is_default, position
      ) values (
        v_id, btrim(v_e->>'sku'), v_price, v_promo, v_barcode, v_is_active,
        (not v_has_variants or v_i = 0), v_i
      )
      returning id into v_vid;
    else
      v_vid := (v_e->>'id')::uuid;
      update public.product_variants set
        sku = btrim(v_e->>'sku'),
        price = v_price,
        promo_price = v_promo,
        barcode = v_barcode,
        is_active = v_is_active,
        is_default = (not v_has_variants or v_i = 0),
        position = v_i
      where id = v_vid and product_id = v_id;
    end if;

    delete from public.variant_attribute_values where variant_id = v_vid;
    if jsonb_array_length(v_opt_list) > 0 then
      insert into public.variant_attribute_values (variant_id, attribute_id, option_id)
      select distinct on ((o->>'attribute_id')::uuid)
        v_vid, (o->>'attribute_id')::uuid, (o->>'option_id')::uuid
      from jsonb_array_elements(v_opt_list) o;
    end if;

    insert into public.variant_costs (variant_id, cost)
    values (v_vid, v_cost)
    on conflict (variant_id) do update
      set cost = excluded.cost, updated_at = now();

    if v_is_new and v_stock > 0 then
      perform public._move_stock(v_vid, null, 'available', v_stock, 'initial', 'Stock initial', null, null, auth.uid());
    end if;

    v_kept_ids := array_append(v_kept_ids, v_vid);
  end loop;

  -- Removed variants: order lines keep a FK on the variant, so keep ordered ones (inactive)
  -- and hard-delete the rest.
  delete from public.product_variants pv
  where pv.product_id = v_id
    and not (pv.id = any (v_kept_ids))
    and not exists (select 1 from public.order_items oi where oi.variant_id = pv.id);

  update public.product_variants pv
  set is_active = false, is_default = false
  where pv.product_id = v_id
    and not (pv.id = any (v_kept_ids));

  -- Surface combination conflicts raised by the deferred unique constraint now,
  -- instead of at commit time.
  set constraints public.uq_variant_combination immediate;

  return v_id;
exception
  when invalid_text_representation then
    raise exception 'invalid_payload: invalid value';
  when invalid_datetime_format then
    raise exception 'invalid_payload: invalid date';
  when numeric_value_out_of_range then
    raise exception 'invalid_payload: value out of range';
  when string_data_right_truncation then
    raise exception 'invalid_payload: value too long';
end $$;

revoke all on function public.save_product(jsonb, jsonb, jsonb, jsonb) from public, anon;
grant execute on function public.save_product(jsonb, jsonb, jsonb, jsonb) to authenticated;

-- ---------- PUBLIC: storefront search (category tree, facets, sort, total count) ----------
create or replace function public.search_products(
  _q text default null,
  _category_id uuid default null,
  _filters jsonb default '{}'::jsonb,
  _sort text default 'relevance',
  _limit int default 24,
  _offset int default 0,
  _min_price numeric default null,
  _max_price numeric default null
) returns table (product_id uuid, total bigint)
language sql stable security definer set search_path = public as $$
  with recursive category_tree as (
    select c.id
    from public.categories c
    where c.id = _category_id
    union all
    select c.id
    from public.categories c
    join category_tree t on c.parent_id = t.id
  ),
  base as (
    select
      p.id,
      p.category_id,
      p.name_fr,
      p.name_ar,
      p.sku,
      p.brand,
      p.is_featured,
      p.rating_avg,
      p.rating_count,
      p.created_at,
      coalesce(p.published_at, p.created_at) as listed_at,
      coalesce(vp.min_variant_price, coalesce(p.promo_price, p.price)) as effective_price,
      coalesce(sold.total, 0)::bigint as sold,
      lower(btrim(coalesce(_q, ''))) as q_key,
      case
        when coalesce(nullif(btrim(_sort), ''), 'relevance') in
             ('relevance', 'new', 'price_asc', 'price_desc', 'popular', 'rating')
          then coalesce(nullif(btrim(_sort), ''), 'relevance')
        else 'relevance'
      end as sort_key
    from public.products p
    left join lateral (
      select min(coalesce(v.promo_price, v.price)) as min_variant_price
      from public.product_variants v
      where v.product_id = p.id and v.is_active
    ) vp on true
    left join lateral (
      select sum(oi.quantity) as total
      from public.order_items oi
      join public.orders o on o.id = oi.order_id
      where oi.product_id = p.id
        and o.status not in ('cancelled', 'returned')
    ) sold on true
    where p.status = 'published'
  ),
  matched as (
    select b.*
    from base b
    where (_category_id is null or b.category_id in (select id from category_tree))
      and (
        b.q_key = ''
        or position(b.q_key in lower(b.name_fr)) > 0
        or position(b.q_key in lower(coalesce(b.name_ar, ''))) > 0
        or position(b.q_key in lower(b.sku)) > 0
        or position(b.q_key in lower(coalesce(b.brand, ''))) > 0
      )
      and (_min_price is null or b.effective_price >= _min_price)
      and (_max_price is null or b.effective_price <= _max_price)
      and not exists (
        select 1
        from jsonb_each(
          case
            when jsonb_typeof(coalesce(_filters, '{}'::jsonb)) = 'object'
              then coalesce(_filters, '{}'::jsonb)
            else '{}'::jsonb
          end
        ) f
        where jsonb_typeof(f.value) = 'array'
          and jsonb_array_length(f.value) > 0
          and not exists (
            -- product-level specs (text/number/boolean/dropdown values)
            select 1
            from public.product_attribute_values pav
            where pav.product_id = b.id
              and pav.attribute_id::text = f.key
              and pav.option_id::text in (select jsonb_array_elements_text(f.value))
            union all
            -- variant axes (size, colour...) carried by active variants
            select 1
            from public.variant_attribute_values vav
            join public.product_variants pv on pv.id = vav.variant_id
            where pv.product_id = b.id
              and pv.is_active
              and vav.attribute_id::text = f.key
              and vav.option_id::text in (select jsonb_array_elements_text(f.value))
          )
      )
  ),
  ranked as (
    select
      m.*,
      count(*) over () as total,
      case
        when m.q_key = '' then 0
        when lower(m.name_fr) = m.q_key
          or lower(coalesce(m.name_ar, '')) = m.q_key
          or lower(m.sku) = m.q_key then 0
        when starts_with(lower(m.name_fr), m.q_key)
          or starts_with(lower(coalesce(m.name_ar, '')), m.q_key) then 1
        when starts_with(lower(coalesce(m.brand, '')), m.q_key) then 2
        else 3
      end as match_rank
    from matched m
  )
  select r.id as product_id, r.total
  from ranked r
  order by
    case when r.sort_key = 'relevance' then r.match_rank end asc nulls last,
    case when r.sort_key = 'new' then r.listed_at end desc nulls last,
    case when r.sort_key = 'price_asc' then r.effective_price end asc nulls last,
    case when r.sort_key = 'price_desc' then r.effective_price end desc nulls last,
    case when r.sort_key = 'popular' then r.sold end desc nulls last,
    case when r.sort_key = 'rating' then r.rating_avg end desc nulls last,
    case when r.sort_key = 'rating' then r.rating_count end desc nulls last,
    r.is_featured desc,
    r.listed_at desc nulls last,
    r.created_at desc,
    r.id asc
  limit least(greatest(coalesce(_limit, 24), 0), 500)
  offset greatest(coalesce(_offset, 0), 0)
$$;

revoke all on function public.search_products(text, uuid, jsonb, text, int, int, numeric, numeric) from public, anon;
grant execute on function public.search_products(text, uuid, jsonb, text, int, int, numeric, numeric) to anon, authenticated;

-- ---------- PUBLIC: best sellers (units sold, published products only) ----------
create or replace function public.get_best_sellers(_limit int default 8)
returns table (product_id uuid, sold bigint)
language sql stable security definer set search_path = public as $$
  select oi.product_id, sum(oi.quantity)::bigint as sold
  from public.order_items oi
  join public.orders o on o.id = oi.order_id
  join public.products p on p.id = oi.product_id
  where p.status = 'published'
    and o.status not in ('cancelled', 'returned')
  group by oi.product_id
  order by sum(oi.quantity) desc, max(o.created_at) desc, oi.product_id
  limit least(greatest(coalesce(_limit, 8), 0), 100)
$$;

revoke all on function public.get_best_sellers(int) from public, anon;
grant execute on function public.get_best_sellers(int) to anon, authenticated;

-- ---------- ADMIN: delete a product, or archive it when order history exists ----------
-- Matches the generated RPC contract: returns 'deleted' on a hard delete and
-- 'archived' when order lines force us to keep the catalog row for history.
create or replace function public.delete_product(_product_id uuid)
returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'forbidden';
  end if;
  if _product_id is null then
    raise exception 'invalid_payload: product id';
  end if;
  if not exists (select 1 from public.products p where p.id = _product_id) then
    raise exception 'product_not_found';
  end if;

  -- order_items.variant_id is ON DELETE RESTRICT and product_id is ON DELETE SET NULL:
  -- deleting would fail or orphan history, so keep every row and archive the product instead.
  if exists (
    select 1
    from public.order_items oi
    where oi.product_id = _product_id
      or oi.variant_id in (select pv.id from public.product_variants pv where pv.product_id = _product_id)
  ) then
    update public.products
    set status = 'archived'
    where id = _product_id and status <> 'archived';
    return 'archived';
  end if;

  -- Safe to drop the movement log too: with no order line, these rows are not referenced
  -- by any order and the variant FK would only null them out.
  delete from public.inventory_movements im
  where im.variant_id in (select pv.id from public.product_variants pv where pv.product_id = _product_id);

  -- Cascades: product_private, product_attribute_values, product_images, product_variants,
  -- variant_costs, variant_attribute_values, inventory, reviews.
  delete from public.products p where p.id = _product_id;
  return 'deleted';
end $$;

revoke all on function public.delete_product(uuid) from public, anon;
grant execute on function public.delete_product(uuid) to authenticated;

-- ===== 0006_seed_demo_catalog.sql =====
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
INSERT INTO public.profiles (id, full_name, email)
SELECT u.id, left(coalesce(u.raw_user_meta_data->>'full_name', u.raw_user_meta_data->>'name'), 120), u.email FROM auth.users u
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.store_settings (id, delivery_fee, free_delivery_threshold, delivery_cities, announcement_fr, announcement_ar)
VALUES (true, 7, 150, ARRAY['Tunis','Ariana','Ben Arous','Manouba','Nabeul','Zaghouan','Bizerte','Béja','Jendouba','Le Kef','Siliana','Sousse','Monastir','Mahdia','Sfax','Kairouan','Kasserine','Sidi Bouzid','Gabès','Médenine','Tataouine','Gafsa','Tozeur','Kébili']::text[],
  'Livraison offerte dès 150 DT — paiement à la livraison', 'توصيل مجاني ابتداءً من 150 د.ت — الدفع عند الاستلام')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.description_templates (id, name, summary, instructions, target_length, display_order) VALUES
(md5('tpl-fiche')::uuid, 'Fiche complète', 'Accroche, paragraphe de présentation, points forts et conseils d''utilisation.', 'Commence par une phrase d''accroche qui donne envie. Enchaîne avec un paragraphe qui présente le produit et son usage. Ajoute une liste de 4 à 6 points forts concrets tirés des caractéristiques. Termine par une courte phrase rassurante (livraison partout en Tunisie, paiement à la livraison). Ton chaleureux et professionnel.', 'long', 1),
(md5('tpl-courte')::uuid, 'Courte & percutante', 'Deux ou trois phrases efficaces, idéales pour mobile.', 'Rédige 2 à 3 phrases maximum, directes et dynamiques. Mets en avant le bénéfice principal et une ou deux caractéristiques clés. Pas de liste à puces.', 'short', 2),
(md5('tpl-seo')::uuid, 'Optimisée SEO', 'Texte structuré qui reprend naturellement les mots-clés du produit.', 'Reprends naturellement le nom du produit, la marque, la catégorie et les caractéristiques importantes comme mots-clés, sans bourrage. Utilise un paragraphe d''introduction, puis une liste de points forts, puis un court paragraphe de conclusion. Phrases claires et lisibles.', 'medium', 3),
(md5('tpl-tech')::uuid, 'Technique à puces', 'Une phrase d''introduction puis les caractéristiques en liste.', 'Écris une seule phrase d''introduction, puis présente les caractéristiques techniques sous forme de liste à puces claire (nom de la caractéristique : valeur avec unité). Ton neutre et précis, sans superlatifs.', 'medium', 4)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.categories (id, parent_id, name_fr, name_ar, slug, description_fr, description_ar, image_url, display_order, is_active) VALUES
(md5('cat-mode')::uuid, NULL, 'Mode', 'موضة', 'mode', 'Vêtements du quotidien, confortables et faciles à porter.', 'ملابس يومية مريحة وسهلة الارتداء.', '/demo/robe-ete-fleurie.jpg', 1, true),
(md5('cat-electronique')::uuid, NULL, 'Électronique', 'إلكترونيات', 'electronique', 'Audio, montres et accessoires pour votre téléphone.', 'سماعات، ساعات وإكسسوارات لهاتفك.', '/demo/ecouteurs-sans-fil.jpg', 2, true),
(md5('cat-maison-cuisine')::uuid, NULL, 'Maison & cuisine', 'المنزل والمطبخ', 'maison-cuisine', 'Artisanat tunisien et rangement malin pour la maison.', 'حرف تونسية وحلول تخزين ذكية للمنزل.', '/demo/theiere-ceramique.jpg', 3, true),
(md5('cat-beaute')::uuid, NULL, 'Beauté & bien-être', 'الجمال والعناية', 'beaute', 'Soins naturels inspirés des traditions méditerranéennes.', 'منتجات عناية طبيعية مستوحاة من التقاليد المتوسطية.', '/demo/huile-argan.jpg', 4, true)
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.categories (id, parent_id, name_fr, name_ar, slug, image_url, display_order, is_active) VALUES
(md5('cat-t-shirts-sweats')::uuid, md5('cat-mode')::uuid, 'T-shirts & sweats', 'تي شيرت وسويت شيرت', 't-shirts-sweats', '/demo/tshirt-coton-bio.jpg', 1, true),
(md5('cat-chemises')::uuid, md5('cat-mode')::uuid, 'Chemises', 'قمصان', 'chemises', '/demo/chemise-lin.jpg', 2, true),
(md5('cat-robes')::uuid, md5('cat-mode')::uuid, 'Robes', 'فساتين', 'robes', '/demo/robe-ete-fleurie.jpg', 3, true),
(md5('cat-audio')::uuid, md5('cat-electronique')::uuid, 'Audio', 'صوتيات', 'audio', '/demo/enceinte-bluetooth.jpg', 1, true),
(md5('cat-montres-accessoires')::uuid, md5('cat-electronique')::uuid, 'Montres & accessoires', 'ساعات وإكسسوارات', 'montres-accessoires', '/demo/montre-connectee.jpg', 2, true),
(md5('cat-cuisine')::uuid, md5('cat-maison-cuisine')::uuid, 'Cuisine', 'مطبخ', 'cuisine', '/demo/theiere-ceramique.jpg', 1, true),
(md5('cat-rangement')::uuid, md5('cat-maison-cuisine')::uuid, 'Rangement', 'تخزين', 'rangement', '/demo/bocaux-verre.jpg', 2, true),
(md5('cat-soins')::uuid, md5('cat-beaute')::uuid, 'Soins du corps', 'العناية بالجسم', 'soins', '/demo/savon-naturel.jpg', 1, true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.category_attributes (id, category_id, code, name_fr, name_ar, type, unit, is_required, is_filterable, is_searchable, is_variant, display_order) VALUES
(md5('att-mode.taille')::uuid, md5('cat-mode')::uuid, 'taille', 'Taille', 'المقاس', 'dropdown', NULL, false, true, false, true, 1),
(md5('att-mode.couleur')::uuid, md5('cat-mode')::uuid, 'couleur', 'Couleur', 'اللون', 'color', NULL, false, true, true, true, 2),
(md5('att-mode.matiere')::uuid, md5('cat-mode')::uuid, 'matiere', 'Matière', 'الخامة', 'text', NULL, true, false, true, false, 3),
(md5('att-mode.entretien')::uuid, md5('cat-mode')::uuid, 'entretien', 'Entretien', 'العناية', 'text', NULL, false, false, false, false, 4),
(md5('att-elec.couleur')::uuid, md5('cat-electronique')::uuid, 'couleur', 'Couleur', 'اللون', 'color', NULL, false, true, true, true, 1),
(md5('att-elec.autonomie')::uuid, md5('cat-electronique')::uuid, 'autonomie', 'Autonomie', 'عمر البطارية', 'measurement', 'h', false, false, false, false, 2),
(md5('att-audio.connectivite')::uuid, md5('cat-audio')::uuid, 'connectivite', 'Connectivité', 'الاتصال', 'dropdown', NULL, false, true, true, false, 1),
(md5('att-audio.etanche')::uuid, md5('cat-audio')::uuid, 'etanche', 'Résistant à l''eau', 'مقاوم للماء', 'boolean', NULL, false, false, false, false, 2),
(md5('att-acc.puissance')::uuid, md5('cat-montres-accessoires')::uuid, 'puissance', 'Puissance', 'القوة', 'measurement', 'W', false, false, false, false, 1),
(md5('att-maison.matiere')::uuid, md5('cat-maison-cuisine')::uuid, 'matiere', 'Matière', 'الخامة', 'dropdown', NULL, false, true, true, false, 1),
(md5('att-maison.capacite')::uuid, md5('cat-maison-cuisine')::uuid, 'capacite', 'Capacité', 'السعة', 'measurement', 'L', false, false, false, false, 2),
(md5('att-maison.faitmain')::uuid, md5('cat-maison-cuisine')::uuid, 'fait_main', 'Fait main', 'صنع يدوي', 'boolean', NULL, false, false, false, false, 3),
(md5('att-beaute.contenance')::uuid, md5('cat-beaute')::uuid, 'contenance', 'Contenance', 'الحجم', 'dropdown', NULL, false, true, false, true, 1),
(md5('att-beaute.peau')::uuid, md5('cat-beaute')::uuid, 'type_peau', 'Type de peau', 'نوع البشرة', 'multi_select', NULL, false, true, true, false, 2),
(md5('att-beaute.bio')::uuid, md5('cat-beaute')::uuid, 'bio', 'Certifié bio', 'عضوي معتمد', 'boolean', NULL, false, false, false, false, 3)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.category_attribute_options (id, attribute_id, value, label_fr, label_ar, color_hex, display_order)
SELECT md5('opt-' || o.att || '-' || o.val)::uuid, md5('att-' || o.att)::uuid, o.val, o.fr, o.ar, o.hex, o.ord
FROM (VALUES
  ('mode.taille','S','S','S',NULL,1), ('mode.taille','M','M','M',NULL,2), ('mode.taille','L','L','L',NULL,3), ('mode.taille','XL','XL','XL',NULL,4),
  ('mode.couleur','blanc','Blanc','أبيض','#FFFFFF',1), ('mode.couleur','noir','Noir','أسود','#1F2937',2), ('mode.couleur','gris','Gris chiné','رمادي','#9CA3AF',3),
  ('mode.couleur','vert-sauge','Vert sauge','أخضر مريمي','#9CAF88',4), ('mode.couleur','beige','Beige','بيج','#D6C7A1',5), ('mode.couleur','bleu-ciel','Bleu ciel','أزرق سماوي','#9CC9E8',6),
  ('elec.couleur','blanc','Blanc','أبيض','#FFFFFF',1), ('elec.couleur','noir','Noir','أسود','#1F2937',2), ('elec.couleur','bleu-canard','Bleu canard','أزرق بترولي','#0F5257',3),
  ('audio.connectivite','bt53','Bluetooth 5.3','بلوتوث 5.3',NULL,1), ('audio.connectivite','bt50','Bluetooth 5.0','بلوتوث 5.0',NULL,2),
  ('maison.matiere','ceramique','Céramique','خزف',NULL,1), ('maison.matiere','verre','Verre','زجاج',NULL,2), ('maison.matiere','bambou','Bambou','خيزران',NULL,3),
  ('beaute.contenance','50ml','50 ml','50 مل',NULL,1), ('beaute.contenance','100ml','100 ml','100 مل',NULL,2),
  ('beaute.peau','tous','Tous types','كل الأنواع',NULL,1), ('beaute.peau','seche','Peau sèche','بشرة جافة',NULL,2), ('beaute.peau','sensible','Peau sensible','بشرة حساسة',NULL,3)
) AS o(att, val, fr, ar, hex, ord)
ON CONFLICT (id) DO NOTHING;

DO $seed$
DECLARE
  d jsonb := $json$[
{"slug":"tshirt-coton-bio","sku":"WS-TS-001","cat":"t-shirts-sweats","fr":"T-shirt col rond coton bio","ar":"تي شيرت بياقة دائرية من القطن العضوي","brand":"Medina Wear","model":"MW-100","price":39.9,"cost":18,"featured":true,"days":2,"img":"tshirt-coton-bio",
 "dfr":"Le basique qu'on porte tous les jours. Coupe régulière, col rond côtelé et coton bio doux au toucher.\n\n• 100 % coton bio, 180 g/m²\n• Ne rétrécit pas au lavage\n• Coutures renforcées aux épaules",
 "dar":"القطعة الأساسية التي تلبسها كل يوم. قصة عادية، ياقة دائرية وقطن عضوي ناعم.\n\n• قطن عضوي 100٪، 180 غ/م²\n• لا ينكمش عند الغسيل\n• خياطة مقواة عند الكتفين",
 "attrs":[{"a":"mode.matiere","text":"100 % coton bio"},{"a":"mode.entretien","text":"Lavage en machine à 30 °C"}],
 "axes":[["mode.taille",["S","M","L","XL"]],["mode.couleur",["blanc","noir"]]]},
{"slug":"sweat-capuche-molleton","sku":"WS-SW-002","cat":"t-shirts-sweats","fr":"Sweat à capuche molleton","ar":"سويت شيرت بقبعة مبطن","brand":"Medina Wear","model":"MW-220","price":79,"promo":65,"cost":35,"featured":false,"days":6,"img":"sweat-capuche",
 "dfr":"Chaud sans être lourd, ce sweat à capuche molletonné accompagne vos soirées fraîches.\n\n• Intérieur molletonné doux\n• Capuche doublée avec cordon\n• Bords côtelés aux poignets et à la taille",
 "dar":"دافئ دون أن يكون ثقيلاً، يرافقك في الأمسيات الباردة.\n\n• بطانة داخلية ناعمة\n• قبعة مبطنة بحبل\n• حواف مضلعة عند المعصمين والخصر",
 "attrs":[{"a":"mode.matiere","text":"80 % coton, 20 % polyester"},{"a":"mode.entretien","text":"Lavage à 30 °C, sur l'envers"}],
 "axes":[["mode.taille",["M","L","XL"]],["mode.couleur",["gris","vert-sauge"]]]},
{"slug":"chemise-lin","sku":"WS-CH-003","cat":"chemises","fr":"Chemise en lin","ar":"قميص من الكتان","brand":"Sidi Bou","model":"SB-LIN","price":89,"cost":40,"featured":false,"days":10,"img":"chemise-lin",
 "dfr":"Légère et respirante, la chemise en lin idéale pour l'été tunisien.\n\n• 100 % lin lavé\n• Poche poitrine\n• Boutons nacrés",
 "dar":"خفيف ويسمح بمرور الهواء، القميص المثالي لصيف تونس.\n\n• كتان مغسول 100٪\n• جيب على الصدر\n• أزرار صدفية",
 "attrs":[{"a":"mode.matiere","text":"100 % lin"}],
 "axes":[["mode.taille",["S","M","L","XL"]],["mode.couleur",["beige","bleu-ciel"]]]},
{"slug":"robe-ete-fleurie","sku":"WS-RB-004","cat":"robes","fr":"Robe d'été fleurie","ar":"فستان صيفي مزهر","brand":"Jasmin","model":"JS-24","price":99,"promo":79,"cost":38,"featured":true,"days":1,"img":"robe-ete-fleurie",
 "dfr":"Une robe midi fluide aux motifs floraux terracotta et vert canard, avec manches ballon.\n\n• Viscose légère\n• Taille ajustée, jupe à volants\n• Longueur mi-mollet",
 "dar":"فستان متوسط الطول بنقوش زهور بلون التيراكوتا والأخضر، بأكمام منفوخة.\n\n• فسكوز خفيف\n• خصر محدد وتنورة بكشكش\n• طول إلى منتصف الساق",
 "attrs":[{"a":"mode.matiere","text":"100 % viscose"},{"a":"mode.entretien","text":"Lavage délicat à 30 °C"}],
 "axes":[["mode.taille",["S","M","L"]]]},
{"slug":"ecouteurs-sans-fil","sku":"WS-EC-005","cat":"audio","fr":"Écouteurs sans fil","ar":"سماعات أذن لاسلكية","brand":"SonicTN","model":"Buds Pro","warranty":"1 an","price":129,"promo":99,"cost":55,"featured":true,"days":3,"img":"ecouteurs-sans-fil",
 "dfr":"Un son clair et jusqu'à 24 heures d'écoute avec le boîtier de charge.\n\n• Bluetooth 5.3, connexion instantanée\n• Embouts en silicone en 3 tailles\n• Résistants aux éclaboussures",
 "dar":"صوت نقي وحتى 24 ساعة استماع مع علبة الشحن.\n\n• بلوتوث 5.3 واتصال فوري\n• سدادات سيليكون بثلاثة مقاسات\n• مقاومة للرذاذ",
 "attrs":[{"a":"elec.autonomie","num":24},{"a":"audio.connectivite","option":"bt53"},{"a":"audio.etanche","bool":true}],
 "axes":[["elec.couleur",["blanc","noir"]]]},
{"slug":"enceinte-bluetooth-portable","sku":"WS-EN-006","cat":"audio","fr":"Enceinte Bluetooth portable","ar":"مكبر صوت بلوتوث محمول","brand":"SonicTN","model":"Go Mini","warranty":"1 an","price":149,"cost":70,"featured":false,"days":12,"img":"enceinte-bluetooth",
 "dfr":"Compacte, avec sa dragonne, elle vous suit à la plage comme en terrasse.\n\n• 12 heures d'autonomie\n• Tissu résistant à l'eau\n• Commandes sur le dessus",
 "dar":"صغيرة الحجم مع حزام للحمل، ترافقك إلى الشاطئ أو الشرفة.\n\n• 12 ساعة تشغيل\n• قماش مقاوم للماء\n• أزرار تحكم في الأعلى",
 "attrs":[{"a":"elec.autonomie","num":12},{"a":"audio.connectivite","option":"bt50"},{"a":"audio.etanche","bool":true}],"axes":[]},
{"slug":"montre-connectee","sku":"WS-MT-007","cat":"montres-accessoires","fr":"Montre connectée","ar":"ساعة ذكية","brand":"SonicTN","model":"Fit 2","warranty":"1 an","price":199,"promo":169,"cost":95,"featured":true,"days":4,"img":"montre-connectee",
 "dfr":"Suivez vos pas, votre sommeil et vos notifications d'un coup d'œil.\n\n• Écran tactile lumineux\n• Bracelet silicone confortable\n• Jusqu'à 7 jours d'autonomie",
 "dar":"تابع خطواتك ونومك وإشعاراتك بنظرة واحدة.\n\n• شاشة لمس مضيئة\n• سوار سيليكون مريح\n• حتى 7 أيام من البطارية",
 "attrs":[{"a":"elec.autonomie","num":168}],"axes":[]},
{"slug":"chargeur-rapide-usb-c-20w","sku":"WS-CR-008","cat":"montres-accessoires","fr":"Chargeur rapide USB-C 20 W","ar":"شاحن سريع USB-C بقوة 20 واط","brand":"SonicTN","model":"PD20","warranty":"6 mois","price":35,"cost":14,"featured":false,"days":15,"img":"chargeur-rapide",
 "dfr":"Rechargez votre téléphone rapidement grâce à la charge 20 W. Câble USB-C inclus.\n\n• Charge rapide 20 W\n• Câble USB-C vers USB-C de 1 m\n• Format compact",
 "dar":"اشحن هاتفك بسرعة بفضل الشحن بقوة 20 واط. الكابل مرفق.\n\n• شحن سريع 20 واط\n• كابل USB-C إلى USB-C بطول 1 م\n• حجم صغير",
 "attrs":[{"a":"acc.puissance","num":20}],"axes":[]},
{"slug":"theiere-ceramique-peinte-main","sku":"WS-TH-009","cat":"cuisine","fr":"Théière en céramique peinte main","ar":"إبريق شاي خزفي مرسوم يدوياً","brand":"Nabeul Artisanat","price":59,"cost":25,"featured":true,"days":5,"img":"theiere-ceramique",
 "dfr":"Façonnée et peinte à la main à Nabeul, cette théière apporte une touche artisanale à votre table.\n\n• Céramique émaillée\n• Contenance 1 litre\n• Motifs uniques : chaque pièce est différente",
 "dar":"مصنوع ومرسوم يدوياً في نابل، يضيف لمسة حرفية إلى طاولتك.\n\n• خزف مطلي\n• سعة لتر واحد\n• نقوش فريدة، كل قطعة مختلفة",
 "attrs":[{"a":"maison.matiere","option":"ceramique"},{"a":"maison.capacite","num":1},{"a":"maison.faitmain","bool":true}],"axes":[]},
{"slug":"lot-3-bocaux-verre-bambou","sku":"WS-BC-010","cat":"rangement","fr":"Lot de 3 bocaux en verre et bambou","ar":"طقم 3 برطمانات من الزجاج والخيزران","brand":"Dar Home","price":45,"promo":39,"cost":18,"featured":false,"days":8,"img":"bocaux-verre",
 "dfr":"Rangez épices, café ou céréales avec style. Trois tailles, couvercles en bambou.\n\n• Verre borosilicate\n• Couvercles bambou avec joint\n• Capacité totale 1,5 litre",
 "dar":"رتّب التوابل أو القهوة أو الحبوب بأناقة. ثلاثة أحجام بأغطية من الخيزران.\n\n• زجاج بوروسيليكات\n• أغطية خيزران بحلقة عازلة\n• سعة إجمالية 1.5 لتر",
 "attrs":[{"a":"maison.matiere","option":"verre"},{"a":"maison.capacite","num":1.5},{"a":"maison.faitmain","bool":false}],"axes":[]},
{"slug":"huile-argan-bio","sku":"WS-HA-011","cat":"soins","fr":"Huile d'argan bio","ar":"زيت الأرغان العضوي","brand":"Zitouna","price":39,"cost":15,"featured":true,"days":7,"img":"huile-argan",
 "dfr":"Pressée à froid, l'huile d'argan nourrit la peau, les cheveux et les ongles.\n\n• 100 % pure, pressée à froid\n• Flacon en verre ambré avec pipette\n• Convient à tous les types de peau",
 "dar":"معصور على البارد، يغذي البشرة والشعر والأظافر.\n\n• نقي 100٪ ومعصور على البارد\n• قارورة زجاج كهرماني مع قطارة\n• مناسب لكل أنواع البشرة",
 "attrs":[{"a":"beaute.peau","options":["tous","seche"]},{"a":"beaute.bio","bool":true}],
 "axes":[["beaute.contenance",["50ml","100ml"]]],"vprice":{"50ml":[39,null,15],"100ml":[65,59,26]}},
{"slug":"savons-naturels-lot-3","sku":"WS-SV-012","cat":"soins","fr":"Savons naturels (lot de 3)","ar":"صابون طبيعي (3 قطع)","brand":"Zitouna","price":24,"cost":9,"featured":false,"days":9,"img":"savon-naturel",
 "dfr":"Trois savons saponifiés à froid : lait d'amande, olive & sauge, lavande.\n\n• Ingrédients d'origine naturelle\n• Sans parfum de synthèse\n• Environ 100 g par savon",
 "dar":"ثلاث قطع صابون مصنوعة على البارد: حليب اللوز، الزيتون والمريمية، الخزامى.\n\n• مكونات طبيعية\n• بدون عطور صناعية\n• حوالي 100 غ للقطعة",
 "attrs":[{"a":"beaute.peau","options":["tous","sensible"]},{"a":"beaute.bio","bool":false}],"axes":[]}
]$json$::jsonb;
  stocks int[] := ARRAY[14, 22, 9, 3, 18, 0, 12, 25, 7, 16, 11, 5];
  p jsonb; pa jsonb; t text; a1 text; a2 text; v1 text; v2 text; vk text; vp jsonb;
  pid uuid; vid uuid; pos int; si int := 0; vprice numeric; vpromo numeric; vcost numeric; st int;
BEGIN
  FOR p IN SELECT * FROM jsonb_array_elements(d) LOOP
    pid := md5('prod-' || (p->>'slug'))::uuid;
    CONTINUE WHEN EXISTS (SELECT 1 FROM public.products WHERE id = pid OR slug = p->>'slug' OR sku = p->>'sku');
    INSERT INTO public.products (id, category_id, name_fr, name_ar, slug, sku, description_fr, description_ar, brand, model, price, promo_price,
                                 warranty, status, has_variants, is_featured, published_at)
    VALUES (pid, md5('cat-' || (p->>'cat'))::uuid, p->>'fr', p->>'ar', p->>'slug', p->>'sku', p->>'dfr', p->>'dar', p->>'brand', p->>'model',
            (p->>'price')::numeric, (p->>'promo')::numeric, p->>'warranty', 'published',
            jsonb_array_length(p->'axes') > 0, (p->>'featured')::boolean, now() - make_interval(days => (p->>'days')::int));
    INSERT INTO public.product_private (product_id, purchase_price) VALUES (pid, (p->>'cost')::numeric) ON CONFLICT (product_id) DO NOTHING;
    INSERT INTO public.product_images (product_id, url, alt, position) VALUES (pid, '/demo/' || (p->>'img') || '.jpg', p->>'fr', 0);

    FOR pa IN SELECT * FROM jsonb_array_elements(p->'attrs') LOOP
      IF pa ? 'options' THEN
        FOR t IN SELECT * FROM jsonb_array_elements_text(pa->'options') LOOP
          INSERT INTO public.product_attribute_values (product_id, attribute_id, option_id)
          VALUES (pid, md5('att-' || (pa->>'a'))::uuid, md5('opt-' || (pa->>'a') || '-' || t)::uuid);
        END LOOP;
      ELSE
        INSERT INTO public.product_attribute_values (product_id, attribute_id, option_id, value_text, value_number, value_boolean)
        VALUES (pid, md5('att-' || (pa->>'a'))::uuid,
                CASE WHEN pa ? 'option' THEN md5('opt-' || (pa->>'a') || '-' || (pa->>'option'))::uuid END,
                pa->>'text', (pa->>'num')::numeric, (pa->>'bool')::boolean);
      END IF;
    END LOOP;

    a1 := p->'axes'->0->>0;
    a2 := p->'axes'->1->>0;
    pos := 0;
    FOR v1 IN SELECT x FROM jsonb_array_elements_text(coalesce(p->'axes'->0->1, '[""]'::jsonb)) x LOOP
      FOR v2 IN SELECT x FROM jsonb_array_elements_text(coalesce(p->'axes'->1->1, '[""]'::jsonb)) x LOOP
        pos := pos + 1;
        si := si + 1;
        vk := (p->>'slug') || '|' || v1 || '|' || v2;
        vid := md5('var-' || vk)::uuid;
        vp := p->'vprice'->v1;
        vprice := coalesce((vp->>0)::numeric, (p->>'price')::numeric);
        vpromo := CASE WHEN vp IS NOT NULL THEN (vp->>1)::numeric ELSE (p->>'promo')::numeric END;
        vcost := coalesce((vp->>2)::numeric, (p->>'cost')::numeric);
        INSERT INTO public.product_variants (id, product_id, sku, price, promo_price, is_active, is_default, position)
        VALUES (vid, pid,
                (p->>'sku') || CASE WHEN v1 <> '' THEN '-' || upper(replace(v1, '-', '')) ELSE '' END || CASE WHEN v2 <> '' THEN '-' || upper(replace(v2, '-', '')) ELSE '' END,
                vprice, vpromo, true, a1 IS NULL, pos);
        IF a1 IS NOT NULL THEN
          INSERT INTO public.variant_attribute_values (variant_id, attribute_id, option_id) VALUES (vid, md5('att-' || a1)::uuid, md5('opt-' || a1 || '-' || v1)::uuid);
        END IF;
        IF a2 IS NOT NULL THEN
          INSERT INTO public.variant_attribute_values (variant_id, attribute_id, option_id) VALUES (vid, md5('att-' || a2)::uuid, md5('opt-' || a2 || '-' || v2)::uuid);
        END IF;
        UPDATE public.variant_costs SET cost = vcost WHERE variant_id = vid;
        st := stocks[((si - 1) % array_length(stocks, 1)) + 1];
        IF st > 0 THEN
          PERFORM public._move_stock(vid, NULL, 'available', st, 'initial', 'Stock initial (catalogue de démonstration)', NULL, NULL, NULL);
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;
END $seed$;

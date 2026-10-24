import { Badge, PageHeader } from "@/components/ui";
import { getProducts } from "@/lib/admin/queries";
import { money, productName } from "@/lib/format";

const formatName = (format: string) => ({ pdf: "PDF", html_zip: "HTML/ZIP", mp4: "MP4" })[format] ?? format;

export default async function ProductsPage() {
  const products = await getProducts();
  return <><PageHeader eyebrow="Tek seferlik ürünler" title="Dijital ürünler" description="Ürün kataloğu, mağaza kimlikleri, satış anahtarı ve doğrulanmış hak sahipliği istatistikleri." /><div className="notice">Google Play fiyatı bu projede katalog API’sinden okunmuyor. Gösterilen tutar sunucu kataloğudur; mağaza fiyatı Play Console’dan yönetilir.</div><section className="section card-grid">{products.map((product) => <article className="card product-card" key={product.product_id}><div><Badge tone={product.catalog_active && product.storefront_enabled ? "good" : "warn"}>{product.catalog_active && product.storefront_enabled ? "Satış açık" : "Satış kapalı"}</Badge><h2>{productName(product.product_code)}</h2><p className="code">{product.product_code}</p></div><div className="price">{money(product.price_minor, product.currency)}</div><dl className="facts"><dt>Teslim biçimi</dt><dd>{formatName(product.delivery_format)}</dd><dt>Google Play ID</dt><dd className="code">{product.google_product_id || "Eşleme yok"}</dd><dt>Ödenen sipariş</dt><dd>{product.paid_orders}</dd><dt>Aktif hak</dt><dd>{product.active_entitlements}</dd><dt>İade/geri alma</dt><dd>{product.refunded_or_revoked_orders}</dd></dl></article>)}</section></>;
}

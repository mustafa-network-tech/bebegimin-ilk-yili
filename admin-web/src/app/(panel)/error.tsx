"use client";

export default function ErrorPage({ reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return <div className="empty"><strong>Veriler yüklenemedi</strong><p>Oturum, yetki veya bağlantı durumunu kontrol edin.</p><button className="button primary" type="button" onClick={reset}>Tekrar dene</button></div>;
}

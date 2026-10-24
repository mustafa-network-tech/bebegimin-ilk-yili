import type { Metadata } from "next";
import localFont from "next/font/local";

import "./globals.css";

const nunito = localFont({
  src: [
    { path: "../fonts/Nunito-Regular.ttf", weight: "400" },
    { path: "../fonts/Nunito-SemiBold.ttf", weight: "600" },
    { path: "../fonts/Nunito-Bold.ttf", weight: "700" },
    { path: "../fonts/Nunito-ExtraBold.ttf", weight: "800" },
  ],
  variable: "--font-nunito",
});

const lora = localFont({
  src: [
    { path: "../fonts/Lora-Regular.ttf", weight: "400" },
    { path: "../fonts/Lora-SemiBold.ttf", weight: "600" },
  ],
  variable: "--font-lora",
});

export const metadata: Metadata = {
  title: "Platform Yönetimi | Bebeğimin İlk Yılı",
  description: "Bebeğimin İlk Yılı güvenli platform yönetim paneli",
  robots: { index: false, follow: false },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="tr" className={`${nunito.variable} ${lora.variable}`}><body>{children}</body></html>;
}

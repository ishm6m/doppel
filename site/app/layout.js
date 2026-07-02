import "./globals.css";

const SITE = "https://getdoppel.vercel.app";

export const metadata = {
  metadataBase: new URL(SITE),
  title: "Doppel — Find duplicate & near-duplicate files on Mac, 100% offline",
  description:
    "Doppel is a free, open-source macOS app that finds duplicate and near-duplicate documents by their content — not just name and size. 100% offline; nothing ever leaves your Mac.",
  keywords: [
    "duplicate file finder mac",
    "near-duplicate documents",
    "offline duplicate finder",
    "macOS duplicate cleaner",
    "open source",
    "PDF duplicate finder",
  ],
  authors: [{ name: "Doppel" }],
  alternates: { canonical: "/" },
  robots: { index: true, follow: true, "max-image-preview": "large" },
  icons: { icon: "/assets/logo-light.png" },
  openGraph: {
    type: "website",
    url: SITE,
    siteName: "Doppel",
    locale: "en_US",
    title: "Doppel — duplicates, understood",
    description:
      "A 100% offline Mac app that finds duplicate and near-duplicate documents by their content. Open source. Nothing leaves your Mac.",
    images: [
      {
        url: "/assets/og-placeholder.png",
        width: 1200,
        height: 630,
        alt: "Doppel — offline duplicate finder for macOS",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "Doppel — duplicates, understood",
    description:
      "A 100% offline Mac app that finds duplicate and near-duplicate documents by their content. Open source. Nothing leaves your Mac.",
    images: ["/assets/og-placeholder.png"],
  },
};

export const viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#ffffff" },
    { media: "(prefers-color-scheme: dark)", color: "#000000" },
  ],
};

const jsonLd = {
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  name: "Doppel",
  applicationCategory: "UtilitiesApplication",
  operatingSystem: "macOS 14.0 or later",
  description:
    "A 100% offline macOS app that finds duplicate and near-duplicate documents by their content, not just name and size. Open source; nothing leaves your Mac.",
  url: SITE + "/",
  downloadUrl: "https://github.com/ishm6m/doppel/releases/latest",
  license: "https://github.com/ishm6m/doppel/blob/master/LICENSE",
  isAccessibleForFree: true,
  offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>
        {children}
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
        />
      </body>
    </html>
  );
}

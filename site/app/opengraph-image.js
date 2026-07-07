import { ImageResponse } from "next/og";

export const alt = "Doppel — offline duplicate finder for macOS";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

// Branded OG/Twitter card, generated at build time. No static asset to go missing.
export default function OpengraphImage() {
  return new ImageResponse(
    (
      <div
        style={{
          height: "100%",
          width: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "center",
          padding: "80px",
          background: "#000",
          color: "#f5f5f7",
          fontFamily: "sans-serif",
        }}
      >
        <div style={{ fontSize: 34, fontWeight: 600, color: "#0071e3" }}>Doppel</div>
        <div
          style={{
            display: "flex",
            flexDirection: "column",
            fontSize: 88,
            fontWeight: 700,
            lineHeight: 1.05,
            marginTop: 20,
          }}
        >
          <span>Duplicates,</span>
          <span>understood.</span>
        </div>
        <div style={{ fontSize: 34, color: "#a1a1a6", marginTop: 32, maxWidth: 900 }}>
          Find duplicate &amp; near-duplicate documents by their content — on your Mac, 100% offline.
        </div>
      </div>
    ),
    size,
  );
}

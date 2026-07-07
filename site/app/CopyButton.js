"use client";

export default function CopyButton({ text }) {
  function copy(e) {
    const btn = e.currentTarget;
    navigator.clipboard.writeText(text).then(() => {
      btn.textContent = "Copied";
      setTimeout(() => (btn.textContent = "Copy"), 1500);
    });
  }
  return <button onClick={copy}>Copy</button>;
}

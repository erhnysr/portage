import type { Metadata } from "next";
import { Fraunces, Public_Sans, Space_Mono } from "next/font/google";
import "./globals.css";
import Providers from "@/components/ui/Providers";
import Navbar from "@/components/layout/Navbar";
import Footer from "@/components/layout/Footer";
import ChainGuard from "@/components/ui/ChainGuard";

// Display / headlines
const fraunces = Fraunces({
  variable: "--font-fraunces",
  subsets: ["latin"],
  display: "swap",
});

// Body
const publicSans = Public_Sans({
  variable: "--font-public-sans",
  subsets: ["latin"],
  display: "swap",
});

// Data / labels / verdict IDs
const spaceMono = Space_Mono({
  variable: "--font-space-mono",
  subsets: ["latin"],
  weight: ["400", "700"],
  display: "swap",
});

export const metadata: Metadata = {
  title: "Coliseum — Public Judging Markets on Arc Testnet",
  description:
    "Submit, vote, and win in on-chain judging arenas. USDC-staked competitions on Arc Testnet.",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html
      lang="en"
      className={`${fraunces.variable} ${publicSans.variable} ${spaceMono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col bg-bg text-text">
        <Providers>
          <Navbar />
          <ChainGuard>
            <main className="flex-1">{children}</main>
          </ChainGuard>
          <Footer />
        </Providers>
      </body>
    </html>
  );
}

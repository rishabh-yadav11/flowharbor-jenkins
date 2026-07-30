import type { Metadata } from "next"
import { Inter } from "next/font/google"
import "./globals.css"

const inter = Inter({ subsets: ["latin"] })

export const metadata: Metadata = {
  title: "FlowHarbor - Todo App",
  description: "Todo list app powered by FlowHarbor CI/CD",
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        <script src="/runtime-config.js" defer />
      </head>
      <body className={inter.className}>{children}</body>
    </html>
  )
}

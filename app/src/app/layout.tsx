import type { Metadata } from "next"
import { Inter } from "next/font/google"
import "./globals.css"

const inter = Inter({ subsets: ["latin"] })

export const metadata: Metadata = {
  title: "FlowHarbor -  Todo App",
  description: "Todo list app powered by FlowHarbor CI/CD",
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        {/* WARNING (issue #20): keep runtime-config as external src. Never inline
            its contents without serializeRuntimeConfig() escaping (<, >, U+2028/29),
            or a hostile VERSION/GIT_BRANCH could break out of </script>. */}
        <script src="/runtime-config.js" defer />
      </head>
      <body className={inter.className}>{children}</body>
    </html>
  )
}

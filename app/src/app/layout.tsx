import type { Metadata } from "next"
import { Inter } from "next/font/google"
import "./globals.css"

const inter = Inter({ subsets: ["latin"] })

export const metadata: Metadata = {
  title: "FlowHarbor — release pipeline demo",
  description:
    "A todo app shipped by a tag-driven Jenkins → ECR → ECS Fargate pipeline on AWS",
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    // The app renders on a near-black canvas, so the dark token set is the
    // correct one. Without `dark` on <html>, globals.css :root (light) drives
    // every shadcn primitive: an almost-white --border and --input disappear
    // against the dark card, and --primary paints a near-black button.
    <html lang="en" className="dark">
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

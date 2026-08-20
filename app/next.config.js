/** @type {import('next').NextConfig} */
const securityHeaders = [
  // Strict Transport Security — force HTTPS for 1 year (ignored over plain HTTP).
  { key: "Strict-Transport-Security", value: "max-age=31536000; includeSubDomains" },
  // Block MIME-type sniffing.
  { key: "X-Content-Type-Options", value: "nosniff" },
  // Deny framing entirely.
  { key: "X-Frame-Options", value: "DENY" },
  // Control referrer leakage.
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  // Restrict browser features.
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=(), browsing-topics=()" },
  // Disable DNS prefetching (privacy).
  { key: "X-DNS-Prefetch-Control", value: "off" },
  // Content Security Policy. Next.js App Router injects an inline bootstrap
  // script for hydration, hence 'unsafe-inline' for script-src — this still
  // blocks all remote/external script injection and eval().
  {
    key: "Content-Security-Policy",
    value: [
      "default-src 'self'",
      "script-src 'self' 'unsafe-inline'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data:",
      "font-src 'self' data:",
      "connect-src 'self'",
      "object-src 'none'",
      "base-uri 'self'",
      "form-action 'self'",
      "frame-ancestors 'none'",
    ].join("; "),
  },
]

const nextConfig = {
  output: "standalone",
  async headers() {
    return [
      {
        source: "/:path*",
        headers: securityHeaders,
      },
    ]
  },
}

module.exports = nextConfig
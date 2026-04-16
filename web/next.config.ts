import type { NextConfig } from 'next'

const config: NextConfig = {
  // Inline env vars accessible on the server only (not bundled to client)
  serverExternalPackages: ['@google-cloud/storage'],
}

export default config

/**
 * Generates a short-lived signed URL for a GCS object.
 * Used by the status route to give the web app a playable video URL.
 *
 * Requires GCP_SA_KEY (service account JSON) and GCP_PROJECT_ID in env.
 */

import { Storage } from '@google-cloud/storage'

let _storage: Storage | null = null

function getStorage(): Storage {
  if (_storage) return _storage
  _storage = new Storage({
    projectId: process.env.GCP_PROJECT_ID,
    credentials: JSON.parse(process.env.GCP_SA_KEY!),
  })
  return _storage
}

/** Convert gs://bucket/path → signed HTTPS URL valid for 1 hour. */
export async function signedUrl(gcsPath: string): Promise<string> {
  const withoutScheme = gcsPath.replace('gs://', '')
  const slashIndex = withoutScheme.indexOf('/')
  const bucketName = withoutScheme.slice(0, slashIndex)
  const objectPath = withoutScheme.slice(slashIndex + 1)

  const [url] = await getStorage()
    .bucket(bucketName)
    .file(objectPath)
    .getSignedUrl({
      action: 'read',
      expires: Date.now() + 60 * 60 * 1000, // 1 hour
    })

  return url
}

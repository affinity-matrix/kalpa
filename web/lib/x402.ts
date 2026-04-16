/**
 * X402 payment verification for the Kalpa inference API.
 *
 * The inference endpoint requires a payment before dispatching a generation job.
 * On first request (no payment header), the route returns HTTP 402 with
 * payment requirements. The client pays, then retries with the proof header.
 *
 * TODO: Wire in the correct x402 library for Aptos testnet.
 *
 * Options:
 *   - @x402/next    — official package, primarily EVM (coinbase/x402)
 *   - @adipundir/aptos-x402 — community Aptos implementation
 *   - Custom        — implement against Shelby's X402 facilitator directly
 *
 * The placeholder below accepts any X-Payment header as valid so the rest
 * of the pipeline can be tested before payment is wired in.
 * Set X402_ENFORCE=true in env to enable real verification.
 */

export interface PaymentRequirements {
  scheme: string
  network: string
  payTo: string
  amount: string
  asset: string
  description: string
}

export interface VerificationResult {
  valid: boolean
  error?: string
}

export function buildPaymentRequirements(priceApt: number): PaymentRequirements {
  return {
    scheme: 'exact',
    network: process.env.X402_NETWORK ?? 'aptos:testnet',
    payTo: process.env.X402_PAYTO_ADDRESS ?? '',
    amount: String(priceApt),
    asset: 'APT',
    description: 'Kalpa video generation — one 5s 1080p clip',
  }
}

export async function verifyX402(
  request: Request,
  requirements: PaymentRequirements,
): Promise<VerificationResult> {
  // Enforcement disabled — accept all requests for local/dev testing
  if (process.env.X402_ENFORCE !== 'true') {
    return { valid: true }
  }

  const paymentHeader = request.headers.get('X-Payment')
  if (!paymentHeader) {
    return { valid: false, error: 'Missing X-Payment header' }
  }

  // TODO: Replace with real verification call.
  // Example using a facilitator endpoint:
  //
  // const res = await fetch(`${process.env.X402_FACILITATOR_URL}/verify`, {
  //   method: 'POST',
  //   headers: { 'Content-Type': 'application/json' },
  //   body: JSON.stringify({ payment: JSON.parse(paymentHeader), requirements }),
  // })
  // const { isValid, invalidReason } = await res.json()
  // return isValid ? { valid: true } : { valid: false, error: invalidReason }

  return { valid: true }
}

package com.webcapsule.reactnative.runtime

import com.google.crypto.tink.subtle.Ed25519Verify
import java.util.Base64

internal object SignatureVerifier {
  private val pemPattern = Regex("^-----BEGIN PUBLIC KEY-----\\n([A-Za-z0-9+/]{59}=\\n)-----END PUBLIC KEY-----\\n$")
  private val spkiPrefix = byteArrayOf(0x30,0x2a,0x30,0x05,0x06,0x03,0x2b,0x65,0x70,0x03,0x21,0x00)
  private val domain = "WEBCAPSULE-MANIFEST-V1\n".toByteArray(Charsets.UTF_8)

  fun verify(canonical: ByteArray, signature: ByteArray, pem: String) {
    val match = pemPattern.matchEntire(pem) ?: fail(WebCapsuleErrorCode.INVALID_PUBLIC_KEY, "Public key PEM is not canonical")
    val der = try { Base64.getDecoder().decode(match.groupValues[1].replace("\n", "")) } catch (error:Exception) { fail(WebCapsuleErrorCode.INVALID_PUBLIC_KEY,"Invalid public key Base64",error) }
    if (der.size != 44 || !der.copyOfRange(0,12).contentEquals(spkiPrefix)) fail(WebCapsuleErrorCode.INVALID_PUBLIC_KEY,"Public key SPKI is invalid")
    try { Ed25519Verify(der.copyOfRange(12,44)).verify(signature, domain + canonical) }
    catch (error:Exception) { fail(WebCapsuleErrorCode.SIGNATURE_MISMATCH,"Manifest signature mismatch",error) }
  }
}

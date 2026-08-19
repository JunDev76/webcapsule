package com.webcapsule.reactnative.runtime

import org.junit.Assert.assertEquals
import org.junit.Test

class PendingTrialGuardTest {
  @Test fun `same capsule is exclusive and release is idempotent`() {
    val guard = PendingTrialGuard()
    val token = guard.acquire("com.example.app")
    expect(WebCapsuleErrorCode.TRIAL_SESSION_IN_PROGRESS) { guard.acquire("com.example.app") }
    guard.acquire("com.example.other").release()
    token.release(); token.release()
    guard.acquire("com.example.app").release()
  }

  private fun expect(code: WebCapsuleErrorCode, action: () -> Unit) {
    try { action(); throw AssertionError("Expected $code") }
    catch (error: WebCapsuleException) { assertEquals(code, error.code) }
  }
}

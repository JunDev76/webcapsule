package com.webcapsule.reactnative.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HealthCoordinatorTest {
  @Test fun `ready parser requires exact strict contract`() {
    val valid = json()
    assertEquals("ready", ReadyMessageParser.parse(valid).type)
    listOf(
      valid.replace("\"version\":\"1.0.0\"", "\"extra\":true,\"version\":\"1.0.0\""),
      valid.replace("\"type\":\"ready\"", "\"type\":\"ready\",\"type\":\"ready\""),
      valid.replace("\"protocolVersion\":1", "\"protocolVersion\":\"1\""),
      valid.replace("\"type\":\"ready\"", "\"type\":\"webcapsule:ready\""),
    ).forEach { expect(WebCapsuleErrorCode.READY_MESSAGE_INVALID) { ReadyMessageParser.parse(it) } }
  }

  @Test fun `matching main-frame ready stabilizes then succeeds once`() {
    val scheduler = FakeScheduler(100)
    var commits = 0; var successes = 0; val failures = mutableListOf<WebCapsuleException>()
    val coordinator = coordinator(scheduler, { commits++ }, { successes++ }, failures::add)
    coordinator.entryLoaded()
    coordinator.ready(json(), HealthCoordinator.ORIGIN, true)
    scheduler.advance(2_999)
    assertEquals(0, commits)
    scheduler.advance(1)
    assertEquals(1, commits); assertEquals(1, successes); assertTrue(failures.isEmpty())
    scheduler.advance(20_000)
    assertEquals(1, successes)
  }

  @Test fun `deadline is measured from session creation`() {
    val scheduler = FakeScheduler(15_099)
    val failures = mutableListOf<WebCapsuleException>()
    coordinator(scheduler, {}, {}, failures::add)
    assertTrue(failures.isEmpty())
    scheduler.advance(1)
    assertEquals(WebCapsuleErrorCode.READY_TIMEOUT, failures.single().code)
  }

  @Test fun `invalid source duplicate and stabilization fatal fail exactly once`() {
    val scheduler = FakeScheduler(100); val failures = mutableListOf<WebCapsuleException>()
    val coordinator = coordinator(scheduler, {}, {}, failures::add)
    coordinator.entryLoaded(); coordinator.ready(json(), "https://evil.example", true)
    coordinator.ready(json(), HealthCoordinator.ORIGIN, true)
    assertEquals(1, failures.size)
    assertEquals(WebCapsuleErrorCode.READY_MESSAGE_INVALID, failures.single().code)

    val secondFailures = mutableListOf<WebCapsuleException>()
    val second = coordinator(scheduler, {}, {}, secondFailures::add)
    second.entryLoaded(); second.ready(json(), HealthCoordinator.ORIGIN, true); second.fatal("navigation")
    scheduler.advance(3_000)
    assertEquals(WebCapsuleErrorCode.STABILIZATION_FAILED, secondFailures.single().code)
  }

  @Test fun `close cancels pending callbacks`() {
    val scheduler = FakeScheduler(100); var succeeded = false; val failures = mutableListOf<WebCapsuleException>()
    val coordinator = coordinator(scheduler, {}, { succeeded = true }, failures::add)
    coordinator.entryLoaded(); coordinator.ready(json(), HealthCoordinator.ORIGIN, true); coordinator.close()
    scheduler.advance(20_000)
    assertFalse(succeeded); assertTrue(failures.isEmpty())
  }

  private fun coordinator(scheduler: FakeScheduler, commit: () -> Unit, success: () -> Unit, failure: (WebCapsuleException) -> Unit) =
    HealthCoordinator(session(), scheduler, commit, success, failure)

  private fun session() = SessionDescriptor("session-1", "com.example.app", "1.0.0", "index.html", "a".repeat(64), 1, 100, emptyMap(), "1.0.0", 1)
  private fun json() = "{\"type\":\"ready\",\"protocolVersion\":1,\"sessionId\":\"session-1\",\"capsuleId\":\"com.example.app\",\"version\":\"1.0.0\"}"
  private fun expect(code: WebCapsuleErrorCode, action: () -> Unit) { try { action(); throw AssertionError("Expected $code") } catch (error: WebCapsuleException) { assertEquals(code, error.code) } }

  private class FakeScheduler(var time: Long) : HealthScheduler {
    private data class Task(val at: Long, val action: () -> Unit, var cancelled: Boolean = false)
    private val tasks = mutableListOf<Task>()
    override fun now() = time
    override fun schedule(delayMillis: Long, action: () -> Unit): Any = Task(time + delayMillis, action).also(tasks::add)
    override fun cancel(token: Any) { (token as Task).cancelled = true }
    fun advance(millis: Long) {
      time += millis
      while (true) {
        val task = tasks.filter { !it.cancelled && it.at <= time }.minByOrNull { it.at } ?: break
        task.cancelled = true; task.action()
      }
    }
  }
}

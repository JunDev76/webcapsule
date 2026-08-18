package com.webcapsule.reactnative.runtime

import com.fasterxml.jackson.core.JsonFactory
import com.fasterxml.jackson.core.JsonParser
import com.fasterxml.jackson.core.JsonToken

import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import org.erdtman.jcs.JsonCanonicalizer

internal object StrictJson {
  private val factory = JsonFactory.builder().build()

  fun parse(bytes: ByteArray): Any? {
    val text = try {
      StandardCharsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(java.nio.ByteBuffer.wrap(bytes)).toString()
    } catch (error: Exception) {
      fail(WebCapsuleErrorCode.INVALID_JSON_VALUE, "JSON is not valid UTF-8", error)
    }
    try {
      factory.createParser(text).use { parser ->
        val value = read(parser, parser.nextToken() ?: fail(WebCapsuleErrorCode.INVALID_JSON_VALUE, "Empty JSON"))
        if (parser.nextToken() != null) fail(WebCapsuleErrorCode.INVALID_JSON_VALUE, "Trailing JSON data")
        return value
      }
    } catch (error: WebCapsuleException) {
      throw error
    } catch (error: Exception) {
      fail(WebCapsuleErrorCode.INVALID_JSON_VALUE, "Invalid JSON", error)
    }
  }

  fun canonicalize(bytes: ByteArray): ByteArray = try {
    JsonCanonicalizer(bytes).encodedUTF8
  } catch (error: Exception) {
    fail(WebCapsuleErrorCode.INVALID_JSON_VALUE, "Cannot canonicalize JSON", error)
  }

  private fun read(parser: JsonParser, token: JsonToken): Any? = when (token) {
    JsonToken.START_OBJECT -> linkedMapOf<String, Any?>().also { map ->
      while (parser.nextToken() != JsonToken.END_OBJECT) {
        if (parser.currentToken() != JsonToken.FIELD_NAME) fail(WebCapsuleErrorCode.INVALID_JSON_VALUE, "Invalid object")
        val name = parser.currentName
        if (map.containsKey(name)) fail(WebCapsuleErrorCode.DUPLICATE_JSON_KEY, "Duplicate JSON object key")
        map[name] = read(parser, parser.nextToken())
      }
    }
    JsonToken.START_ARRAY -> mutableListOf<Any?>().also { list ->
      while (parser.nextToken() != JsonToken.END_ARRAY) list += read(parser, parser.currentToken())
    }
    JsonToken.VALUE_STRING -> parser.text
    JsonToken.VALUE_NUMBER_INT -> try { parser.longValue } catch (error: Exception) {
      fail(WebCapsuleErrorCode.INVALID_JSON_VALUE, "Integer is outside supported range", error)
    }
    JsonToken.VALUE_NUMBER_FLOAT -> fail(WebCapsuleErrorCode.INVALID_JSON_VALUE, "Manifest numbers must be integers")
    JsonToken.VALUE_TRUE -> true
    JsonToken.VALUE_FALSE -> false
    JsonToken.VALUE_NULL -> null
    else -> fail(WebCapsuleErrorCode.INVALID_JSON_VALUE, "Unsupported JSON token")
  }
}

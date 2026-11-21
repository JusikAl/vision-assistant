package com.example.camera

import org.json.JSONArray
import org.json.JSONObject

/** Combine only finalized segments. Preserve every word, including guards and [unk]. */
internal object VoskFinals {
    fun best(raw: String): JSONObject {
        val value = JSONObject(raw)
        return value.optJSONArray("alternatives")?.optJSONObject(0) ?: value
    }

    fun text(raw: String): String = best(raw).optString("text").trim()

    fun merge(segments: List<String>): String {
        val best = segments.map { best(it) }
        val texts = best.map { it.optString("text").trim() }
        fun joined(parts: List<String>) = parts.filter { it.isNotEmpty() }.joinToString(" ")
        val words = JSONArray()
        best.forEach { value ->
            value.optJSONArray("result")?.let { result ->
                for (i in 0 until result.length()) words.put(result.getJSONObject(i))
            }
        }
        // Substitute each alternative into the complete utterance, without choosing
        // a convenient command or inventing a combined confidence score.
        val alternatives = linkedSetOf<String>()
        segments.forEachIndexed { index, raw ->
            JSONObject(raw).optJSONArray("alternatives")?.let { values ->
                for (i in 0 until values.length()) {
                    val parts = texts.toMutableList()
                    parts[index] = values.getJSONObject(i).getString("text").trim()
                    alternatives.add(joined(parts))
                }
            }
        }
        return JSONObject().put("text", joined(texts)).put("result", words)
            .put("alternatives", JSONArray(alternatives.map { JSONObject().put("text", it) })).toString()
    }
}
